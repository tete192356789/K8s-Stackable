# 05 — ติดตั้ง CloudNativePG Operator 1.30.1 (PoC)

Operator ที่ดูแล PostgreSQL บน Kubernetes (สร้าง, failover, backup, upgrade) — เอกสารนี้ติดตั้งแค่ **operator** และทดสอบด้วย cluster ชั่วคราว
PostgreSQL cluster ตัวจริงที่ Keycloak / Hive / Airflow / Superset ใช้ สร้างภายหลังในขั้น "CNPG Cluster"

| รายการ | ค่า |
|---|---|
| CNPG operator | 1.30.1 (Helm chart `cnpg/cloudnative-pg` 0.29.1) |
| PostgreSQL image | `ghcr.io/cloudnative-pg/postgresql:17.11-standard-trixie` |
| Namespace | `cnpg-system` |
| ไฟล์ใน repo | `platform/cnpg/values.yaml`, `platform/cnpg/images-postgres.txt` |
| ไฟล์บน master | `/root/K8S-Stackable/cnpg/` |
| ต้องติดตั้งก่อน | [01-longhorn.md](01-longhorn.md) (storage), [04-crds-cert-manager.md](04-crds-cert-manager.md) (CRD ของ `PodMonitor`) |

**ทำไม PostgreSQL 17** — ทุก service ใน PoC รองรับ 17 (Keycloak 14–18, Airflow 14–18, Hive ≥ 9.1, OpenMetadata ≥ 15) และตรงกับแผน production (GitLab 19 รับเฉพาะ 17)

---

## ค่าที่ตั้งใน `values.yaml`

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `replicaCount` | `1` | PoC — operator ล่มชั่วคราว PostgreSQL ที่รันอยู่ยังทำงานต่อได้ |
| `resources` | req 50m / 128Mi, limit 256Mi | PoC มี RAM น้อย |
| `monitoring.podMonitorEnabled` | `true` | สร้าง `PodMonitor` ให้ Prometheus เก็บ metric ของ operator (CRD มีแล้วจาก 04) |

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master (รันบนเครื่อง local ที่ root ของ repo)

```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/cnpg'
scp platform/cnpg/values.yaml platform/cnpg/images-postgres.txt root@172.19.10.62:/root/K8S-Stackable/cnpg/
```

---

## ขั้นที่ 2: ดึง image ล่วงหน้า (รันบน master)

**2.1 image ของ operator**

```bash
cd /root/K8S-Stackable/cnpg
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg

helm template cnpg cnpg/cloudnative-pg -n cnpg-system --version 0.29.1 -f values.yaml > rendered.yaml
grep -oE 'image: *"?[^" ]+' rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt                     # ควรมีแค่ ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1

../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log
```

**2.2 image ของ PostgreSQL** (ใหญ่ ~200–300 MB ใช้เวลาหลายนาที — รันเบื้องหลังได้ระหว่างทำขั้นที่ 3)

```bash
cd /root/K8S-Stackable/cnpg
nohup ../scripts/prepull-images.sh images-postgres.txt > prepull-postgres.log 2>&1 &
tail -f prepull-postgres.log       # Ctrl+C เพื่อออก (script ยังทำงานต่อ)
```

ต้องจบด้วย `imported` 2 ครั้งและ `=== เสร็จ` ก่อนทำขั้นที่ 5

---

## ขั้นที่ 3: ติดตั้ง operator (รันบน master)

```bash
cd /root/K8S-Stackable/cnpg
helm install cnpg cnpg/cloudnative-pg \
  -n cnpg-system --create-namespace \
  --version 0.29.1 \
  -f values.yaml

kubectl -n cnpg-system wait pod --all --for=condition=Ready --timeout=300s
kubectl -n cnpg-system get pods
kubectl get crd | grep postgresql.cnpg.io
```

ต้องมี pod `cnpg-cloudnative-pg-...` เป็น `Running` และ CRD เช่น `clusters.postgresql.cnpg.io`, `databases.postgresql.cnpg.io`, `poolers.postgresql.cnpg.io`, `scheduledbackups.postgresql.cnpg.io`

---

## ขั้นที่ 4: ติดตั้ง kubectl plugin `cnpg` (ไม่บังคับ แต่แนะนำ — รันบน master)

ใช้ดูสถานะ cluster, เปิด psql, สั่ง promote / restart ได้สะดวก

```bash
curl -fsSL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
  | sh -s -- -b /usr/local/bin v1.30.1
kubectl cnpg version
```

---

## ขั้นที่ 5: ทดสอบด้วย cluster ชั่วคราว (รันบน master)

ต้องทำขั้น 2.2 ให้เสร็จก่อน ไม่อย่างนั้น pod จะรอดึง image นาน

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-test
  namespace: default
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.11-standard-trixie
  storage:
    size: 1Gi
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
EOF

kubectl wait cluster/pg-test --for=condition=Ready --timeout=600s
kubectl get cluster pg-test
kubectl get pods,pvc -l cnpg.io/cluster=pg-test
```

ผลที่ถูกต้อง: `STATUS` = `Cluster in healthy state`, pod `pg-test-1` เป็น `Running`, PVC เป็น `Bound` (StorageClass `longhorn`)

ทดสอบเชื่อมต่อ

```bash
kubectl exec -it pg-test-1 -- psql -U postgres -c 'select version();'
kubectl get secret pg-test-app -o jsonpath='{.data.password}' | base64 -d; echo    # รหัสผ่านของ user app ที่ CNPG สร้างให้
kubectl cnpg status pg-test                                                        # ถ้าติดตั้ง plugin แล้ว
```

ต้องเห็น `PostgreSQL 17.11 ...`

ลบ cluster ทดสอบ (PVC ถูกลบตามไปด้วย)

```bash
kubectl delete cluster pg-test
```

---

## สิ่งที่ CNPG สร้างให้เมื่อสร้าง Cluster (อ้างอิงสำหรับขั้นถัดไป)

| สิ่งที่สร้าง | ชื่อ (cluster ชื่อ `pg-test`) | ใช้ทำอะไร |
|---|---|---|
| Service อ่าน/เขียน | `pg-test-rw` | ชี้ไป primary เสมอ — **app ทุกตัวต่อที่นี่** |
| Service อ่านอย่างเดียว | `pg-test-ro` / `pg-test-r` | replica / ทุก instance |
| Secret ของ app | `pg-test-app` | username, password, `uri`, `jdbc-uri` ของ database `app` |
| Secret ของ superuser | ไม่สร้างโดยค่าเริ่มต้น | เปิดได้ด้วย `enableSuperuserAccess: true` |
| PVC | `pg-test-1` | ข้อมูลของ instance |

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| `helm install` error ว่ามี resource ของ CNPG อยู่แล้ว (`cannot be imported into the current release`) | CNPG ตัวเก่าจาก stack เดิมทิ้ง Role / ClusterRole / webhook ไว้ | `kubectl get clusterrole,clusterrolebinding,validatingwebhookconfigurations,mutatingwebhookconfigurations -o name \| grep -i cnpg` แล้วลบของเก่า |
| Pod `pg-test-1-initdb-...` ค้าง `ContainerCreating` นาน | ยังไม่มี PostgreSQL image บน node | ทำขั้น 2.2 ให้เสร็จ |
| `kubectl apply` Cluster error `failed calling webhook "mcluster.cnpg.io"` | operator ยังไม่ Ready | รอขั้นที่ 3 แล้ว apply ใหม่ |
| Cluster ค้าง `Setting up primary` | PVC ไม่ Bound หรือ pod ถูก OOM kill | `kubectl describe pvc pg-test-1`, `kubectl describe pod pg-test-1` |

ดู log

```bash
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --tail=50
kubectl logs pg-test-1 --tail=50
```

---

## ถอนการติดตั้ง

ต้องลบ Cluster ทุกตัวก่อน (`kubectl get clusters -A`)

```bash
helm uninstall cnpg -n cnpg-system
kubectl delete ns cnpg-system
# CRD ของ CNPG ไม่ถูกลบโดย helm ถ้าต้องการลบ:
kubectl get crd -o name | grep postgresql.cnpg.io | xargs -r kubectl delete
```
