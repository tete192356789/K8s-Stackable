# 15 — Apache Airflow 3.2.2 (GitOps, PoC)

ตั้งเวลารันงาน ETL — login ผ่าน Keycloak, DAG ดึงจาก Git (`dags/` ของ repo นี้), ต่อ Trino ด้วย service user `airflow`

| รายการ | ค่า |
|---|---|
| Airflow | **3.2.2** (Stackable airflow-operator 26.7.0, image `oci.stackable.tech/sdp/airflow:3.2.2-stackable26.7.0`) |
| URL | `https://airflow.172.19.10.62.sslip.io` |
| Login | Keycloak เท่านั้น — client `airflow` (มีอยู่แล้วจากขั้นที่ 11), AuthenticationClass `keycloak` ตัวเดียวกับ Trino / Superset |
| Executor | **KubernetesExecutor** — 1 task = 1 pod ใหม่ (ไม่มี Redis / Celery worker ค้างไว้) |
| DAG | git-sync จาก `https://github.com/tete192356789/K8s-Stackable.git` โฟลเดอร์ `dags/` ทุก 30 วินาที |
| Metadata DB | database `airflow` บน `pg-platform` (OpenBao `secret/postgres/airflow`) |
| Task log | SeaweedFS `s3://airflow-logs/` (HTTP ภายใน cluster) — ดู log ได้แม้ pod ของ task หายไปแล้ว |
| Trino | connection `trino_default` — service user `airflow` (อ่าน/เขียน catalog `iceberg` ตาม OPA) |
| RAM | webserver 2Gi + scheduler 2Gi (รวม dag-processor) + 1Gi ต่อ task ที่กำลังรัน |
| ไฟล์ใน repo | `gitops/apps/20-stackable-operators.yaml` (เพิ่ม `airflow-operator`), `gitops/apps/56-airflow.yaml`, `gitops/airflow/airflow.yaml`, `gitops/postgres/` (role `airflow`), `dags/trino_demo.py` |
| ต้องติดตั้งก่อน | ขั้นที่ 13 (Trino + OPA) |

```
ผู้ใช้ ──HTTPS──▶ Traefik ──HTTP :8080──▶ airflow-webserver ──OIDC──▶ Keycloak
                                         airflow-scheduler ◀── git-sync (dags/ จาก GitHub)
                                               │ สร้าง pod ต่อ task (KubernetesExecutor)
                                               ▼
                                        task pod ──▶ Trino (user airflow) ──▶ OPA
                                               └──▶ log ──▶ SeaweedFS s3://airflow-logs/
```

### Role ใน Airflow (มาจาก group ใน Keycloak ทุกครั้งที่ login)

| Group ใน Keycloak | Role ใน Airflow | ทำอะไรได้ |
|---|---|---|
| `platform-admins` | `Admin` | ทุกอย่าง (user, connection, variable) |
| `data-engineers` | `Op` | trigger / clear / pause DAG, จัดการ connection / variable |
| `analysts` | `Viewer` | ดูอย่างเดียว |
| ไม่มี group | `Public` | แทบไม่เห็นอะไร |

> DAG ทุกตัวรันในนาม service user `airflow` ใน Trino (ไม่ใช่คนที่กด trigger) — สิทธิ์ข้อมูลของ DAG = สิทธิ์ของ `airflow` ใน OPA

### ค่าที่ตั้ง

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `apiVersion` | `airflow.stackable.tech/v1alpha2` | 26.7 ใช้ v1alpha2 (`credentialsSecretName`, `metadataDatabase` แบบ struct) |
| `kubernetesExecutors` | resources limit 1Gi ต่อ task | ค่าเริ่มต้น 3Gi ต่อ task — PoC ใช้แค่ query Trino (งานหนักทำที่ Trino) |
| ไม่มี `dagProcessors` / `triggerers` | — | scheduler รัน dag-processor ในตัว; ยังไม่ใช้ deferrable operator |
| `AIRFLOW__FAB__ENABLE_PROXY_FIX` | `True` | อยู่หลัง Traefik: redirect URI ของ OIDC เป็น `https://airflow…/auth/oauth-authorized/keycloak` |
| `AIRFLOW__API__BASE_URL` | `https://airflow.172.19.10.62.sslip.io/` | URL ที่ผู้ใช้เห็น (link ใน UI / API) |
| Remote logging | `s3://airflow-logs/` ผ่าน connection `s3_logs` | KubernetesExecutor ลบ pod หลัง task จบ — log ต้องอยู่นอก pod |
| `envOverrides` / `podOverrides` | ใส่ซ้ำทั้ง webserver, scheduler, executor (YAML anchor `&env`) | pod ของ task ต้องมี env / secret เดียวกัน (S3, Trino) |
| secret ที่ operator สร้างเอง | `airflow-internal-secret`, `airflow-jwt-secret`, `airflow-fernet-key` | ไม่อยู่ใน Git — **ห้ามลบ** `airflow-fernet-key` (ใช้เข้ารหัส connection ที่สร้างใน UI) |

---

## ขั้นที่ 0: ตรวจ RAM (master)

```bash
kubectl describe nodes | grep -E '^Name:|^  memory  '
```

Airflow ขอ ~4 GB ตลอดเวลา + 1 GB ต่อ task ที่รัน — ถ้าทุก node เกิน ~80% ให้แจ้งก่อน

## ขั้นที่ 1: เตรียม secret ใน OpenBao (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }
gen() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-32; }     # ตัวอักษร + ตัวเลขเท่านั้น

bao kv put secret/postgres/airflow username=airflow password="$(gen)"
bao kv put secret/airflow/admin password="$(gen)"

# ต้องมีอยู่แล้วจากขั้นก่อน ๆ
bao kv get -format=json secret/keycloak/clients | jq -r '.data.data | keys[]'    # airflow
bao kv get -format=json secret/trino/users      | jq -r '.data.data | keys[]'    # airflow
```

## ขั้นที่ 2: ดึง image ล่วงหน้า (master)

image ของ Airflow ใหญ่ (~1.5 GB) — pod ของ task ใช้ image เดียวกัน จึงต้องมีครบทุก node

```bash
cd /root/K8s-Stackable-repo && git pull
cd /tmp
helm template airflow-operator oci://oci.stackable.tech/sdp-charts/airflow-operator --version 26.7.0 \
  | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u > airflow-images.txt
echo "oci.stackable.tech/sdp/airflow:3.2.2-stackable26.7.0" >> airflow-images.txt
cat airflow-images.txt

nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/airflow-images.txt > /tmp/airflow-prepull.log 2>&1 &
tail -f /tmp/airflow-prepull.log          # รอจนจบด้วย "=== เสร็จ"
```

## ขั้นที่ 3: Push และ sync

```bash
git push                                                               # Mac
```

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite     # master
kubectl -n argocd get applications | grep -E 'NAME|postgres|airflow'   # Synced / Healthy
```

```bash
kubectl -n database get database airflow                    # APPLIED true
kubectl -n data-platform get airflowcluster,externalsecret | grep -E 'NAME|airflow'
kubectl -n data-platform get pods | grep airflow
# airflow-webserver-default-0 และ airflow-scheduler-default-0 → Running
# ครั้งแรก scheduler รัน db migrate + สร้าง admin — pod อาจ restart 1–2 ครั้ง (ปกติ)
kubectl -n data-platform logs airflow-scheduler-default-0 -c airflow --tail=30
```

## ขั้นที่ 4: Login (browser บน Mac)

1. เปิด `https://airflow.172.19.10.62.sslip.io` → **Sign in with keycloak** → login `admin`
2. มุมซ้ายล่าง **User → Your Profile** (หรือ Security → List Users) → role ต้องเป็น **Admin**
3. หน้า **Dags** ต้องเห็น `trino_demo` (git-sync ดึงจาก `dags/` ภายใน ~30 วินาที)

## ขั้นที่ 5: รัน DAG ทดสอบ

1. เปิด `trino_demo` → ปุ่ม **Trigger** (▶)
2. ดูหน้า Grid — task `create_table` และ `load` ต้องเป็นสีเขียว (แต่ละ task สร้าง pod ใหม่ ~20–40 วินาที)
3. คลิก task `load` → **Logs** → ต้องเห็น `Trino user: airflow` และ `inserted run_id=...`
4. ระหว่างรัน ดู pod ของ task (master):
   ```bash
   kubectl -n data-platform get pods -w | grep trino-demo
   ```
5. ตรวจข้อมูลใน Superset SQL Lab หรือ Python: `SELECT * FROM iceberg.demo.airflow_runs`
6. ตรวจ log บน S3 (Mac — AWS CLI ตาม 06):
   ```bash
   aws --endpoint-url https://s3.172.19.10.62.sslip.io s3 ls --recursive s3://airflow-logs/ | tail -5
   ```

---

## เพิ่ม DAG ใหม่

วางไฟล์ `.py` ใน `dags/` แล้ว push — git-sync ดึงเองภายใน ~30 วินาที (ไม่ต้องผ่าน Argo CD)
connection ที่ใช้ได้ทันที: `trino_default` (Trino, user `airflow`), `s3_logs` (SeaweedFS)

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| ExternalSecret `airflow-*` `SecretSyncedError` | ยังไม่มี secret ใน OpenBao | ขั้นที่ 1 |
| scheduler CrashLoop `password authentication failed for user "airflow"` | role ใน PostgreSQL ยังไม่ถูกสร้าง | `kubectl -n database get database airflow`, Application `postgres` ต้อง Synced |
| webserver restart วนช่วงแรก | รอ scheduler รัน db migrate เสร็จ | รอ 2–3 นาที |
| Keycloak `Invalid parameter: redirect_uri` | redirect URI ไม่ตรง | client `airflow` ต้องมี `https://airflow.172.19.10.62.sslip.io/*` |
| redirect ไป `http://…` หลัง login | ProxyFix ไม่ทำงาน | ตรวจ env `AIRFLOW__FAB__ENABLE_PROXY_FIX=True` ใน pod webserver |
| login แล้วได้ role `Public` อย่างเดียว | ไม่มี claim `groups` ใน userinfo | mapper `groups` ของ client `airflow`: Add to userinfo On, Full group path Off |
| ไม่เห็น DAG | git-sync ดึงไม่ได้ / ยังไม่ push `dags/` | `kubectl -n data-platform logs airflow-scheduler-default-0 -c git-sync-0 --tail=20` |
| DAG มี error `Broken DAG` | import ไม่ผ่าน | ข้อความ error อยู่บนหน้า Dags; ทดสอบด้วย `kubectl -n data-platform exec airflow-scheduler-default-0 -c airflow -- airflow dags list-import-errors` |
| task ค้าง `queued` / pod `Pending` | RAM ของ node ไม่พอ | `kubectl -n data-platform describe pod <pod ของ task>` |
| task error `Access Denied` จาก Trino | OPA ไม่ให้สิทธิ์ `airflow` | `airflow` เขียนได้เฉพาะ catalog `iceberg` (`gitops/opa/trino_policies.rego`) |
| Logs ของ task ว่าง / error `NoSuchBucket` / `AccessDenied` | remote logging ไป S3 ไม่ได้ | `kubectl -n data-platform get secret airflow-env`, bucket `airflow-logs` ต้องมี |

ดู log

```bash
kubectl -n data-platform logs airflow-webserver-default-0 -c airflow --tail=50 | grep -iE 'error|oauth'
kubectl -n data-platform logs airflow-scheduler-default-0 -c airflow --tail=50
kubectl -n stackable-operators logs deploy/stackable-airflow-operator-deployment --tail=50
```
