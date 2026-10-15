# Architecture

PoC data platform on Kubernetes (3 VMs, kubeadm 1.33) built with the Stackable Data Platform 26.7.
Diagrams are Mermaid and render on GitHub.

1. [Overview](#1-overview): every component and how they connect
2. [Data flow](#2-data-flow-sales_pipeline): one pipeline run, from DAG to dashboard
3. [Authentication and authorization](#3-authentication-and-authorization)
4. [Secrets](#4-secrets)
5. [Deployment (GitOps)](#5-deployment-gitops)
6. [Network entry points](#6-network-entry-points)

---

## 1. Overview

```mermaid
flowchart TB
    user(["Users<br/>browser / Python / DBeaver"])

    subgraph edge["Entry · namespace traefik / metallb-system"]
        lb["MetalLB<br/>node IPs .62 .63 .64"]
        traefik["Traefik 3.7<br/>TLS: wildcard cert from internal CA"]
    end

    subgraph apps["Applications · data-platform"]
        superset["Superset 6.1<br/>dashboards, SQL Lab"]
        airflow["Airflow 3.2<br/>webserver + scheduler<br/>KubernetesExecutor"]
        cockpit["Stackable Cockpit<br/>(experimental)"]
    end

    subgraph query["Query and catalog · data-platform"]
        trino["Trino 481<br/>coordinator + worker"]
        opa["OPA 1.16<br/>+ user-info-fetcher"]
        hive["Hive Metastore 4.2<br/>Thrift :9083 + Iceberg REST :9001"]
    end

    subgraph storage["Storage"]
        s3[("SeaweedFS 4.47 · S3<br/>warehouse · loki · airflow-logs · backups")]
        pg[("PostgreSQL 17 · CNPG<br/>pg-platform: keycloak, hive,<br/>superset, airflow")]
        longhorn[("Longhorn 1.12<br/>block storage (PVCs)")]
    end

    subgraph security["Identity and secrets"]
        keycloak["Keycloak 26.7<br/>realm platform"]
        openbao["OpenBao 2.7<br/>KV secret/"]
        eso["External Secrets 2.11"]
        certm["cert-manager 1.21<br/>ClusterIssuer platform-ca"]
    end

    subgraph ops["Operations"]
        argocd["Argo CD 3.5<br/>App-of-Apps"]
        prom["Prometheus + Alertmanager"]
        grafana["Grafana 13"]
        loki["Loki 3.7"]
        vector["Vector 0.59<br/>DaemonSet"]
    end

    github[("GitHub<br/>K8s-Stackable repo")]

    user --> lb --> traefik
    traefik --> superset & airflow & cockpit & grafana & argocd & keycloak
    traefik -->|"Trino web UI"| trino

    superset -->|"SQL, impersonate user"| trino
    airflow -->|"SQL as user airflow"| trino
    cockpit -->|"SQL as user cockpit"| trino
    trino -->|"may user X do Y?"| opa
    opa -->|"groups of user X"| keycloak
    trino -->|"table metadata"| hive
    trino -->|"Parquet files (TLS via Traefik)"| s3
    hive --> pg
    hive --> s3

    superset & airflow & keycloak --> pg
    airflow -->|"task logs"| s3
    pg --- longhorn
    openbao --- longhorn

    superset & airflow & grafana & argocd & trino -.->|"OIDC login"| keycloak

    openbao --> eso -->|"Kubernetes Secrets"| apps & query
    certm -.->|"certificates"| traefik

    github -->|"manifests"| argocd
    github -->|"DAGs (git-sync)"| airflow
    argocd -->|"sync"| apps & query

    vector -->|"pod logs"| loki --> s3
    prom -->|"scrape"| trino & pg & longhorn
    grafana --> prom & loki
```

| Layer | Components | Installed by |
|---|---|---|
| Bootstrap (layer 0) | Longhorn, MetalLB, Traefik, cert-manager, CNPG operator, SeaweedFS, OpenBao, External Secrets, Argo CD | Helm (`platform/`) |
| Platform (layer 1) | PostgreSQL cluster, Stackable operators, Hive, Trino, OPA, Keycloak, Superset, Airflow, monitoring, Cockpit | Argo CD (`gitops/`) |

---

## 2. Data flow: `sales_pipeline`

One run of the end-to-end test DAG ([docs/test/e2e-test.md](test/e2e-test.md)).

```mermaid
sequenceDiagram
    autonumber
    participant Git as GitHub (dags/)
    participant AF as Airflow scheduler
    participant Pod as Task pod
    participant T as Trino
    participant O as OPA
    participant H as Hive Metastore
    participant S3 as SeaweedFS
    participant SS as Superset
    actor A as poc-analyst

    Git->>AF: git-sync pulls sales_pipeline.py
    AF->>Pod: start one pod per task (KubernetesExecutor)
    Pod->>T: CREATE OR REPLACE TABLE iceberg.sales.orders_daily AS SELECT ... FROM tpch.sf1.orders
    T->>O: may airflow read tpch / write iceberg?
    O-->>T: allow
    T->>S3: write Parquet + Iceberg metadata (warehouse/external/sales.db)
    T->>H: commit new snapshot location
    Pod->>T: quality check (row counts, totals)
    Pod->>S3: upload task log (airflow-logs)
    AF->>Pod: delete pod
    A->>SS: open dashboard "Sales PoC"
    SS->>T: SELECT ... (login superset, session user poc-analyst)
    T->>O: may poc-analyst read iceberg.sales?
    O-->>T: allow (group /analysts = read-only)
    T->>H: table location
    T->>S3: read Parquet
    T-->>SS: rows
    A->>SS: INSERT in SQL Lab
    SS->>T: INSERT ... as poc-analyst
    T->>O: may poc-analyst insert?
    O-->>T: deny
    T-->>A: Access Denied
```

---

## 3. Authentication and authorization

```mermaid
flowchart LR
    subgraph kc["Keycloak · realm platform"]
        groups["groups<br/>platform-admins<br/>data-engineers<br/>analysts"]
        clients["OIDC clients<br/>argocd, grafana, trino,<br/>superset, airflow, cockpit,<br/>opa-user-info"]
    end

    subgraph login["Who are you? (authentication)"]
        web["Web UIs<br/>Argo CD, Grafana, Superset,<br/>Airflow, Trino UI, Cockpit"]
        svc["Service users → Trino<br/>trino-admin, superset,<br/>airflow, cockpit<br/>(password in OpenBao)"]
    end

    subgraph authz["What may you do? (authorization)"]
        roles["App roles from the groups claim<br/>Grafana: Admin / Editor / Viewer<br/>Superset: Admin / Alpha / Gamma<br/>Airflow: Admin / Op / Viewer<br/>Argo CD: admin / readonly"]
        opa["OPA policy for Trino<br/>trino_policies.rego"]
    end

    web -->|"OIDC"| clients
    clients -->|"groups claim"| roles
    svc -->|"Basic auth (static AuthenticationClass)"| trino["Trino"]
    web -->|"Superset impersonates the logged-in user"| trino
    trino --> opa
    opa -->|"user-info-fetcher looks up groups"| groups
```

Data access is decided in one place: OPA, for every Trino query. Superset forwards the logged-in user to Trino (impersonation), so a dashboard shows only what that user's Keycloak group may read.

| Keycloak group | Trino (OPA) | Superset | Airflow | Grafana |
|---|---|---|---|---|
| `platform-admins` | everything | Admin | Admin | Admin |
| `data-engineers` | read/write `iceberg`, read others | Alpha + sql_lab | Op | Editor |
| `analysts` | read-only | Gamma + sql_lab + trino_access | Viewer | Viewer |
| no group | `system` catalog only | Public | Public | Viewer |

---

## 4. Secrets

```mermaid
flowchart LR
    admin(["Operator<br/>bao kv put"]) --> bao[("OpenBao<br/>secret/postgres/*<br/>secret/keycloak/clients<br/>secret/trino/users<br/>secret/seaweedfs/s3-admin<br/>secret/grafana, superset, airflow ...")]
    bao -->|"Kubernetes auth<br/>role external-secrets"| eso["External Secrets<br/>ClusterSecretStore openbao"]
    git[("Git: ExternalSecret<br/>(paths only, no values)")] --> eso
    eso -->|"creates and refreshes (1h)"| sec["Kubernetes Secrets"]
    sec --> pods["Pods<br/>env / files"]
```

- The Git repo is public. It holds only `ExternalSecret` objects that name OpenBao paths, never values.
- One OpenBao value can feed both sides of a connection. For example, `secret/trino/users` `airflow` becomes Trino's password file *and* Airflow's `trino_default` connection.
- Not in OpenBao: the OpenBao unseal keys (`init-keys.json` on the control-plane node) and keys generated by operators (`superset-secret-key`, `airflow-fernet-key`).

---

## 5. Deployment (GitOps)

```mermaid
flowchart LR
    dev(["Developer<br/>git push"]) --> gh[("GitHub main")]
    gh --> root["Argo CD app root<br/>gitops/root.yaml"]
    root --> w10["10 · PostgreSQL"] --> w20["20 · Stackable + Keycloak operators"] --> w25["25 · S3 TLS"] --> w30["30 · Hive"] --> w35["35 · OPA"] --> w40["40 · Trino"] --> w50["50 · Keycloak"] --> w55["55-56 · Superset, Airflow"] --> w60["60 · Cockpit"] --> w70["70-72 · Monitoring"]
    gh -->|"git-sync every 30 s"| dags["Airflow DAGs<br/>dags/"]
    helm(["Helm (manual)<br/>platform/"]) --> l0["Layer 0<br/>Longhorn, MetalLB, Traefik,<br/>cert-manager, CNPG, SeaweedFS,<br/>OpenBao, ESO, Argo CD"]
```

Each Application waits until the previous wave is Healthy (custom health check for `Application` in `argocd-cm`).

---

## 6. Network entry points

All URLs are `https://<name>.172.19.10.62.sslip.io`. TLS ends at Traefik with a wildcard certificate from the internal CA (`platform-ca`).

| Host | Service | Login |
|---|---|---|
| `argocd` | Argo CD | Keycloak |
| `keycloak` | Keycloak | realm `master` for admins, `platform` for users |
| `grafana` | Grafana | Keycloak |
| `superset` | Superset | Keycloak |
| `airflow` | Airflow | Keycloak |
| `trino` | Trino web UI | Keycloak |
| `cockpit` | Stackable Cockpit | Keycloak |
| `longhorn` | Longhorn UI | basic auth |
| `s3` | SeaweedFS S3 API | S3 keys |

Inside the cluster, clients reach Trino at `trino-coordinator.data-platform.svc.cluster.local:8443` (HTTPS, password) and S3 at `seaweedfs-s3.seaweedfs.svc:8333` (HTTP) or `s3-tls.seaweedfs.svc.cluster.local:443` (HTTPS, required by Stackable products).
