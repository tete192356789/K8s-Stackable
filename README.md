# K8s-Stackable

A proof of concept of a data platform on Kubernetes built with the [Stackable Data Platform](https://stackable.tech). This repo holds the Helm values, manifests, scripts and step-by-step install guides.

**Target stack:** SeaweedFS (S3) · CloudNativePG · Hive Metastore · Trino (+ Iceberg) · Airflow · Superset · Keycloak · Open Policy Agent · OpenBao + External Secrets · Prometheus / Grafana / Loki / Vector · Longhorn · Traefik

## PoC environment

| Item | Value |
|---|---|
| Kubernetes | kubeadm 1.33 on Rocky Linux 9.6, containerd 2.1, Calico |
| Nodes | 3 VMs (1 control-plane + 2 workers; the control-plane also runs workloads), 4 vCPU / 15 GB each |
| Disk | One disk per node (~270 GB root filesystem), no separate data disk |
| IPs | Only the node IPs are available, so MetalLB uses the node IPs as LoadBalancer IPs (no failover) |
| Domain | `*.<node-ip>.sslip.io` until real DNS is available |
| TLS | Internal CA issued by cert-manager |
| Internet | Slow. Images are pulled once on the control-plane and copied to the workers with `scripts/prepull-images.sh` |

> The PoC is sized for minimal resources (single replicas, no HA). For production, use Kubernetes 1.36 with 3 control-plane nodes behind a VIP, spare IPs for MetalLB, and dedicated data disks.

## Install order

| # | Service | Version | Guide | Status |
|---|---|---|---|---|
| 1 | Longhorn | 1.12.1 | [01-longhorn.md](docs/install/01-longhorn.md) | ✅ |
| 2 | MetalLB | 0.16.1 (chart) | [02-metallb.md](docs/install/02-metallb.md) | ✅ |
| 3 | Traefik | 3.7.13 | [03-traefik.md](docs/install/03-traefik.md) | ✅ |
| 4 | Prometheus Operator CRDs + cert-manager + internal CA | 32.0.1 / 1.21.2 | [04-crds-cert-manager.md](docs/install/04-crds-cert-manager.md) | ✅ |
| 5 | CloudNativePG operator | 1.30.1 | [05-cnpg-operator.md](docs/install/05-cnpg-operator.md) | ✅ |
| 6 | SeaweedFS | 4.47 | [06-seaweedfs.md](docs/install/06-seaweedfs.md) | ✅ |
| 7 | OpenBao + External Secrets | 2.7.0 / 2.11.0 | [07-openbao-eso.md](docs/install/07-openbao-eso.md) | ✅ |
| 8 | Argo CD (last Helm-installed component) | 3.5.3 | [08-argocd.md](docs/install/08-argocd.md) | ✅ |
| 9 | GitOps: CNPG cluster (PostgreSQL 17), Stackable operators, Hive Metastore 4.2.0 + Iceberg REST | 17.11 / 26.7.0 | [09-gitops-hive.md](docs/install/09-gitops-hive.md) | ✅ |
| 10 | Trino (+ Iceberg), no auth yet | 481 | [10-trino.md](docs/install/10-trino.md) | 🔄 |
| 11 | Keycloak | 26.7 | — | |
| 12 | Prometheus + Alertmanager + Grafana, Loki, Vector | — | — | |
| 13 | OPA, Superset, Airflow | 26.7.0 | — | |

Steps 1–8 are installed with Helm (the bootstrap layer). From step 9 on, Argo CD syncs everything from `gitops/` (App-of-Apps, ordered with sync waves).

The install guides under `docs/install/` are written in Thai.

## Design notes

- [Iceberg catalog: Hive Metastore 4 vs Spark / PyIceberg](docs/design/iceberg-catalog-hive4.md) (Thai). Hive Metastore 4.0.1+ breaks Iceberg `HiveCatalog` clients (Spark, PyIceberg). This note covers the options: Hive 4.0.0, two metastores, or an Iceberg REST catalog.

## Repo layout

```
platform/<service>/   Helm values and manifests for the bootstrap layer (installed with Helm)
gitops/               Argo CD App-of-Apps (root.yaml) and the manifests it syncs
scripts/              prepull-images.sh (pull images and copy them to the workers), clean-k8s.sh (wipe the previous cluster)
docs/install/         Step-by-step install guides
docs/design/          Design notes and decisions
```

On the control-plane node the files live under `/root/K8S-Stackable/<service>/`. Each guide says which files to copy there and which machine each command runs on.

## What is not in this repo

See `.gitignore`: the OpenBao unseal keys and root token (`init-keys.json`), the CA certificate, output captured from the previous cluster, and files generated during installation.
All secrets live in OpenBao and reach services through External Secrets. The repo only contains `ExternalSecret` resources that reference secret paths.
