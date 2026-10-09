# 12 — Monitoring: Prometheus + Alertmanager + Grafana, Loki, Vector (GitOps, PoC)

Metrics และ log ของทั้ง platform ดูได้ที่เดียวใน Grafana (login ผ่าน Keycloak)

| รายการ                   | ค่า                                                                                                                                                                             |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| kube-prometheus-stack          | chart**92.1.1** — Prometheus Operator v0.94.1, Prometheus v3.15.0, Alertmanager v0.34.1, Grafana 13.2.3, kube-state-metrics 2.20.0, node-exporter 1.12.1                    |
| Loki                           | **3.7.8** (chart 18.14.0 จาก `grafana-community.github.io/helm-charts` — chart ย้ายออกจาก `grafana/helm-charts` แล้ว) — Monolithic 1 pod              |
| Vector                         | **0.59.0** (chart 0.59.0) — Agent DaemonSet ทุก node                                                                                                                     |
| Namespace                      | `monitoring`                                                                                                                                                                     |
| Grafana                        | `https://grafana.172.19.10.62.sslip.io` — SSO client `grafana` (มีอยู่แล้วจาก realm import ขั้นที่ 11)                                                    |
| เก็บข้อมูล           | Prometheus 7 วัน (PVC Longhorn 15Gi), Loki 7 วัน (bucket`loki` ใน SeaweedFS + PVC 5Gi สำหรับ WAL)                                                                  |
| RAM (request / limit)          | รวมประมาณ**2.5 GB / 5 GB** — Prometheus 1Gi/2Gi, Loki 512Mi/1Gi, Grafana 256Mi/512Mi (+ sidecar), Vector 64Mi/256Mi × 3 node, ที่เหลือตัวละ 32–64Mi |
| ไฟล์ใน repo              | `gitops/apps/70-monitoring.yaml`, `gitops/monitoring/{secrets,scrape}.yaml`, `gitops/monitoring/values/{kube-prometheus-stack,loki,vector}.yaml`                             |
| ต้องติดตั้งก่อน | ขั้นที่ 4 (CRD ของ Prometheus Operator), 6 (bucket`loki`), 11 (Keycloak)                                                                                               |

```
                 ┌──────────── scrape ทุก 60s ─────────────┐
Prometheus ◀─────┤ kubelet/cAdvisor, apiserver, coredns, node-exporter, kube-state-metrics
   │             │ Stackable (Hive, Trino) · CNPG pg-platform · Longhorn         ← gitops/monitoring/scrape.yaml
   ▼             └─────────────────────────────────────────┘
Alertmanager (ยังไม่มีช่องทางแจ้งเตือน)

pod log ──▶ Vector (DaemonSet, /var/log/pods) ──HTTP──▶ Loki :3100 ──S3──▶ SeaweedFS bucket "loki"

ผู้ใช้ ──HTTPS──▶ Traefik ──▶ Grafana ──OIDC──▶ Keycloak (realm platform)
                                │ datasource: Prometheus (kps-prometheus:9090), Loki (loki:3100)
```

### ทำไมแบ่งเป็น 4 Application

| Application               | wave | เนื้อหา                                                                                                                                                                                            |
| ------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `monitoring`            | 70   | `gitops/monitoring/*.yaml` — ExternalSecret 3 ตัว, Certificate `grafana-ca-trust`, ServiceMonitor/PodMonitor ของ Stackable, CNPG, Longhorn (ต้องมี secret ก่อน Grafana / Loki start) |
| `kube-prometheus-stack` | 71   | chart จาก Helm repo + values จาก Git (Argo CD**multi-source**: `$values` = repo นี้)                                                                                                     |
| `loki`                  | 71   | เหมือนกัน                                                                                                                                                                                        |
| `vector`                | 72   | ส่ง log เข้า Loki — รอให้ Loki ขึ้นก่อน                                                                                                                                              |

values อยู่ใน `gitops/monitoring/values/` — Application `monitoring` sync โฟลเดอร์แบบไม่ recursive จึงไม่ apply ไฟล์ values เป็น manifest

---

## ค่าที่ตั้ง

| ค่า                                                                    | ตั้งเป็น                                                                                     | เหตุผล                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `crds.enabled`                                                          | `false`                                                                                            | ลง CRD แยกแล้วในขั้นที่ 4 (32.0.1 = operator v0.94.1 ตรงกับ chart 92.1.1) — ถ้าอัปเกรด chart ข้าม major ต้องอัปเกรด CRD ก่อน                                                         |
| `fullnameOverride`                                                      | `kps`                                                                                              | ชื่อ resource สั้นลง (`kps-prometheus`, `kps-alertmanager`) — Grafana / kube-state-metrics / node-exporter (subchart) ยังใช้ชื่อ `kube-prometheus-stack-*`                                                      |
| `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy` | ปิด (+ rule ที่เกี่ยวข้อง)                                                           | kubeadm ให้ 4 ตัวนี้เปิด metrics ที่`127.0.0.1` เท่านั้น → scrape ไม่ได้ และ alert `...Down` ดังตลอด                                                                                          |
| `prometheusOperator.admissionWebhooks` / `tls`                        | ปิดทั้งคู่                                                                                 | ไม่ต้องมี job สร้าง cert และไม่มี`caBundle` ให้ Argo CD diff — PrometheusRule ที่ผิดจะไม่ถูกปฏิเสธตอน apply (ดู error ใน log ของ operator แทน)                                |
| `*SelectorNilUsesHelmValues`                                            | `false`                                                                                            | Prometheus เลือก ServiceMonitor / PodMonitor / PrometheusRule**ทุกตัวใน cluster** ไม่ต้องติด label `release`                                                                                                |
| `scrapeInterval`                                                        | `60s`                                                                                              | ค่าเริ่มต้น 30s — ลด CPU / disk สำหรับ PoC                                                                                                                                                                             |
| `retention` / `retentionSize`                                         | `7d` / `12GB`                                                                                    | PVC 15Gi (Longhorn replica 2 → ใช้ disk จริง 30Gi)                                                                                                                                                                                 |
| Grafana`persistence`                                                    | ปิด                                                                                               | dashboard + datasource มาจาก provisioning (ConfigMap) และ user มาจาก Keycloak — pod restart แล้วไม่หาย ยกเว้น dashboard ที่สร้างเองใน UI (ให้ export เป็น JSON แล้วเก็บใน Git) |
| Grafana`role_attribute_path`                                            | `platform-admins` → Admin, `data-engineers` → Editor, อื่น ๆ → Viewer                    | ใช้ claim`groups` จาก Keycloak                                                                                                                                                                                                     |
| Grafana`tls_client_ca`                                                  | `/etc/platform-ca/ca.crt`                                                                          | Grafana ต้องเชื่อ cert ของ Keycloak ตอนแลก token —`ca.crt` จาก Certificate `grafana-ca-trust` (แบบเดียวกับ Argo CD)                                                                                   |
| Loki`deploymentMode`                                                    | `Monolithic` (+ `write/read/backend.replicas: 0`)                                                | pod เดียวทำทุกหน้าที่ — chart บังคับให้ target ของโหมดอื่นเป็น 0                                                                                                                                 |
| Loki`chunksCache` / `resultsCache`                                    | ปิด                                                                                               | ค่าเริ่มต้นสร้าง memcached ที่จอง RAM หลาย GB                                                                                                                                                                    |
| Loki`gateway`, `lokiCanary`, `test`, rules sidecar                  | ปิด                                                                                               | ไม่จำเป็นใน PoC — Grafana และ Vector ต่อ`loki:3100` ตรง                                                                                                                                                             |
| Loki S3                                                                   | `http://seaweedfs-s3.seaweedfs.svc:8333`, path-style, key จาก env (`-config.expand-env=true`) | Loki ไม่บังคับ TLS เหมือน Trino — key มาจาก Secret`loki-s3` (OpenBao `secret/seaweedfs/s3-admin`)                                                                                                                 |
| Loki`retention_period`                                                  | `168h`                                                                                             | compactor ลบ log เก่ากว่า 7 วันออกจาก bucket                                                                                                                                                                            |
| Vector labels                                                             | `namespace`, `pod`, `container`, `node`                                                      | ใช้แค่ field ที่ทุก log มี — label มากเกินทำให้ Loki ช้า (label ใน values ต้องเขียน`{{`{{ ... }}`}}` เพราะ chart ส่ง config ผ่าน `tpl` ของ Helm)                             |
| Vector`encoding.codec`                                                  | `text`                                                                                             | ส่งเฉพาะข้อความ log — ไม่ส่ง metadata ของ pod ซ้ำทุกบรรทัด                                                                                                                                            |

### Stackable metrics

operator ของ Stackable สร้าง Service `<cluster>-<role>-<group>-metrics` ที่มี label `stackable.tech/vendor=Stackable`, `prometheus.io/scrape=true` และ annotation `prometheus.io/{scheme,path,port}`
ServiceMonitor `stackable` (`gitops/monitoring/scrape.yaml`) อ่าน annotation เหล่านี้ (ตาม `stackabletech/demos` — `stacks/monitoring/prometheus-service-monitors.yaml`) ต่างจาก demo ตรงที่ไม่ใช้ client cert แต่ข้ามการตรวจ cert ถ้า endpoint เป็น HTTPS (PoC)

---

## ขั้นที่ 0: ตรวจ RAM ของ node (master)

monitoring ขอ RAM เพิ่มราว 2.5 GB — ถ้า master ยังรับ pod ส่วนใหญ่อยู่ (memory requests ~82%) ให้ย้าย Trino ออกก่อน

```bash
kubectl describe nodes | grep -E '^Name:|^  memory'
```

ถ้า master สูงกว่า ~75% (ข้ามได้ถ้าทำไปแล้ว):

```bash
kubectl taint node <ชื่อ node master> node-role.kubernetes.io/control-plane=:PreferNoSchedule
kubectl -n data-platform delete pod -l app.kubernetes.io/name=trino     # scheduler เลือก worker ก่อน
kubectl describe nodes | grep -E '^Name:|^  memory'
```

> `PreferNoSchedule` = เลี่ยง master ถ้ามีที่อื่น แต่ถ้า worker เต็มก็ยังลงที่ master ได้ (DaemonSet อย่าง node-exporter / Vector ไม่ได้รับผล)

## ขั้นที่ 1: เตรียม secret ใน OpenBao (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }

# admin ภายในของ Grafana (ใช้ตอน SSO เสีย)
bao kv put secret/grafana/admin admin-user=admin admin-password="$(openssl rand -base64 24 | tr -d '/+=')"

# ตรวจ secret ที่ต้องมีอยู่แล้ว
bao kv get -format=json secret/keycloak/clients | jq -r '.data.data | keys[]'      # ต้องมี grafana
bao kv get -format=json secret/seaweedfs/s3-admin | jq -r '.data.data | keys[]'    # access_key, secret_key
```

ตรวจว่ามี bucket `loki` (สร้างไว้ในขั้นที่ 6):

```bash
kubectl -n seaweedfs exec seaweedfs-master-0 -- sh -c 'echo "s3.bucket.list" | weed shell -master=localhost:9333' | grep loki
```

## ขั้นที่ 2: ดึง image ล่วงหน้า (master)

รายการนี้ได้จาก `helm template` ของ chart ทั้ง 3 ตัวกับ values ใน repo (Prometheus / Alertmanager / config-reloader ถูกสร้างโดย operator จึงไม่อยู่ใน Deployment ของ chart)

```bash
cat > /tmp/monitoring-images.txt <<'EOF'
quay.io/prometheus-operator/prometheus-operator:v0.94.1
quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1
quay.io/prometheus/prometheus:v3.15.0-distroless
quay.io/prometheus/alertmanager:v0.34.1
quay.io/prometheus/node-exporter:v1.12.1-distroless
registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0
quay.io/kiwigrid/k8s-sidecar:2.13.3
docker.io/grafana/grafana:13.2.3-distroless
docker.io/grafana/loki:3.7.8
docker.io/timberio/vector:0.59.0-distroless-libc
EOF

nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/monitoring-images.txt > /tmp/monitoring-prepull.log 2>&1 &
tail -f /tmp/monitoring-prepull.log          # รอจนจบด้วย "=== เสร็จ"
```

<details>
<summary>สร้างรายการ image เอง (ถ้าเปลี่ยน version ของ chart)</summary>

```bash
cd /root/K8s-Stackable-repo && git pull
V=gitops/monitoring/values
{
  helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 92.1.1 -n monitoring -f $V/kube-prometheus-stack.yaml
  helm template loki loki --repo https://grafana-community.github.io/helm-charts --version 18.14.0 -n monitoring -f $V/loki.yaml
  helm template vector vector --repo https://helm.vector.dev --version 0.59.0 -n monitoring -f $V/vector.yaml
} | grep -oE '(image: *"?|config-reloader=)[^" ]+' | sed -E 's/^(image: *"?|config-reloader=)//' | sort -u
```

</details>

## ขั้นที่ 3: Push และ sync

```bash
git push                                                               # Mac
```

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite     # master
kubectl -n argocd get applications -w         # monitoring, kube-prometheus-stack, loki, vector → Synced / Healthy
```

```bash
kubectl -n monitoring get externalsecret,certificate      # SecretSynced / True
kubectl -n monitoring get pods -o wide
```

ต้องเห็น (ชื่อโดยประมาณ):

| Pod                                                   | จำนวน      |
| ----------------------------------------------------- | --------------- |
| `kps-operator-…`                                   | 1               |
| `prometheus-kps-prometheus-0`                       | 1 (2/2)         |
| `alertmanager-kps-alertmanager-0`                   | 1 (2/2)         |
| `kube-prometheus-stack-grafana-…`                  | 1 (3/3)         |
| `kube-prometheus-stack-kube-state-metrics-…`       | 1               |
| `kube-prometheus-stack-prometheus-node-exporter-…` | 3 (ทุก node) |
| `loki-0`                                            | 1               |
| `vector-…`                                         | 3 (ทุก node) |

## ขั้นที่ 4: ตรวจ (master)

**4.1 Prometheus targets**

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 19090:9090 >/dev/null 2>&1 & PF=$!; sleep 3
curl -s localhost:19090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.health)\t\(.scrapePool)"' | sort | uniq -c
curl -s localhost:19090/api/v1/targets | jq -r '.data.activeTargets[] | select(.health!="up") | "\(.scrapePool)\t\(.scrapeUrl)\t\(.lastError)"'
kill $PF
```

ทุกบรรทัดควรเป็น `up` — ต้องมี `serviceMonitor/monitoring/stackable/0` (Hive, Trino), `podMonitor/monitoring/pg-platform/0`, `serviceMonitor/monitoring/longhorn/0`
ถ้าไม่มี target ของ Stackable เลย ส่งผลของคำสั่งนี้มา:

```bash
kubectl get svc -A -l prometheus.io/scrape=true -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VENDOR:.metadata.labels.stackable\.tech/vendor,ANN:.metadata.annotations'
```

**4.2 Loki ได้รับ log**

```bash
kubectl -n monitoring port-forward svc/loki 13100:3100 >/dev/null 2>&1 & PF=$!; sleep 3
curl -s localhost:13100/ready; echo
curl -s localhost:13100/loki/api/v1/label/namespace/values | jq -c .data      # ต้องเห็น namespace ต่าง ๆ
kill $PF
```

**4.3 Grafana SSO** (เบราว์เซอร์บน Mac)

1. เปิด `https://grafana.172.19.10.62.sslip.io` → **Sign in with Keycloak**
2. login `poc-engineer` (กลุ่ม `data-engineers`) → มุมล่างซ้าย profile ต้องเป็น role **Editor**; user ในกลุ่ม `platform-admins` → **Admin**
3. **Dashboards** → โฟลเดอร์ของ kube-prometheus-stack เช่น `Kubernetes / Compute Resources / Namespace (Pods)` → เลือก namespace `data-platform`
4. **Explore** → datasource **Loki** → query `{namespace="data-platform", container="trino"}`

admin ภายใน (กรณี SSO เสีย): user `admin`, password จาก `bao kv get -field=admin-password secret/grafana/admin`

---

## สิ่งที่ยังไม่ได้ทำ (ภายหลัง)

| เรื่อง                                                                | หมายเหตุ                                                                                                                                                    |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ช่องทางแจ้งเตือนของ Alertmanager                         | ตอนนี้ receiver`null` — เพิ่ม email / Slack / Teams ใน `alertmanager.config`                                                                      |
| Prometheus / Alertmanager UI                                                | ไม่มี Ingress (ไม่มี authentication ในตัว) — ใช้ port-forward หรือดูผ่าน Grafana                                                       |
| Dashboard ของ Stackable / Trino / CNPG / Longhorn                        | import จาก grafana.com แล้ว export เก็บเป็น ConfigMap (label`grafana_dashboard: "1"`) ใน `gitops/monitoring/`                                  |
| Metrics ของ Traefik, cert-manager, SeaweedFS, OpenBao, Argo CD, Keycloak | เปิด metrics / ServiceMonitor ใน values ของแต่ละตัว                                                                                                |
| log ของ Stackable แบบ structured                                      | Stackable รองรับส่ง log ผ่าน Vector aggregator (`vectorAggregatorConfigMapName`) — ตอนนี้เก็บจาก stdout ด้วย Vector agent ก็พอ |

---

## ปัญหาที่พบบ่อย

| อาการ                                                                                                  | สาเหตุ                                                                         | วิธีแก้                                                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Application`monitoring` ค้าง, ExternalSecret `SecretSyncedError`                                    | ยังไม่มี`secret/grafana/admin` หรือ key ผิดชื่อ                 | ขั้นที่ 1 — key ต้องเป็น`admin-user`, `admin-password`                                                                                                              |
| Grafana pod`CreateContainerConfigError`                                                                   | Secret`grafana-admin` / `grafana-oidc` ยังไม่ถูกสร้าง              | `kubectl -n monitoring get externalsecret` แล้วแก้ตามข้อบน                                                                                                             |
| Grafana login แล้ว`Login failed` / log `x509: certificate signed by unknown authority`              | Grafana ไม่เชื่อ cert ของ Keycloak                                        | ตรวจ`kubectl -n monitoring get certificate grafana-ca-trust` (READY) และ `kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- ls /etc/platform-ca` |
| Keycloak`Invalid parameter: redirect_uri`                                                                 | redirect URI ของ client`grafana` ไม่ตรง                                   | ใน Keycloak client`grafana` ต้องมี `https://grafana.172.19.10.62.sslip.io/*`                                                                                                |
| login ได้แต่ role เป็น Viewer ทุกคน                                                          | token ไม่มี claim`groups`                                                     | ตรวจ mapper`groups` ของ client `grafana` (Full group path: Off)                                                                                                              |
| `loki-0` CrashLoop, log `NoCredentialProviders` / `AccessDenied` / `NoSuchBucket`                   | key S3 ไม่ถูกส่งเข้า หรือไม่มี bucket`loki`                  | `kubectl -n monitoring get secret loki-s3`, ตรวจ bucket ในขั้นที่ 1                                                                                                      |
| Vector log`Failed to render template`                                                                     | log บางบรรทัดไม่มี field ที่ใช้ทำ label                        | ส่งแค่ log ชุดนั้นไม่ได้ (บรรทัดอื่นยังส่งปกติ) — แจ้งผลพร้อม log                                                                    |
| Loki`entry too far behind` / `rate limit` ตอนเริ่ม                                              | Vector ส่ง log เก่าทั้งหมดของ node รอบแรก                     | หายเองเมื่อส่งทันแล้ว —`out_of_order_action: accept` ช่วยไว้บางส่วน                                                                               |
| target `longhorn` เป็น `down` ด้วย `context deadline exceeded` | Longhorn 1.12 ตั้ง `networkPolicies.restrictInternalTraffic: true` เป็นค่าเริ่มต้น → NetworkPolicy `longhorn-manager` บล็อก Prometheus | NetworkPolicy `allow-prometheus-scrape` (ns `longhorn-system`) ใน `gitops/monitoring/scrape.yaml` เปิดให้ Prometheus เข้า :9500 |
| target`stackable` เป็น `down` ด้วย `connection refused` / `server returned HTTP status 400` | scheme / port ของ annotation ไม่ตรงกับที่ ServiceMonitor ตีความ | ส่งผลของคำสั่ง`kubectl get svc -A -l prometheus.io/scrape=true …` ในขั้นที่ 4.1                                                                               |
| `kube-prometheus-stack` OutOfSync ตลอดที่ Secret `kps-prometheus-token`                          | Kubernetes เติม`data` ให้ secret ชนิด service-account-token             | เพิ่ม`ignoreDifferences` ให้ Secret นี้ใน `gitops/apps/70-monitoring.yaml`                                                                                             |
| Pod`Pending` — `Insufficient memory`                                                                   | RAM ของ node ไม่พอ                                                           | ขั้นที่ 0                                                                                                                                                                        |

## ถอดออก

ลบ `gitops/apps/70-monitoring.yaml` แล้ว push — Argo CD ลบ resource ทั้งหมด (PVC ของ Prometheus / Loki ต้องลบเอง: `kubectl -n monitoring delete pvc --all`)
log ใน bucket `loki` ยังอยู่ — ลบด้วย S3 client ถ้าไม่ใช้แล้ว
