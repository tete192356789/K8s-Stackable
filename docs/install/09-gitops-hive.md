# 09 — GitOps: PostgreSQL + Stackable operators + Hive 4.2.0 (REST catalog)

ขั้นแรกของ **ชั้น 1 (GitOps)** — ทุกอย่างในขั้นนี้ Argo CD sync จากโฟลเดอร์ `gitops/` บน GitHub
ทางเลือก catalog ของ Iceberg: **Hive Metastore 4.2.0 + Iceberg REST API ในตัว (ทางเลือก E)** — เหตุผลใน [docs/design/iceberg-catalog-hive4.md](../design/iceberg-catalog-hive4.md)

| Wave | Application | สิ่งที่สร้าง | Namespace |
|---|---|---|---|
| 10 | `postgres` | CNPG Cluster `pg-platform` (PostgreSQL 17.11, 1 instance, 20 GB) + role / database `hive` | `database` |
| 20 | `stackable-{commons,secret,listener,hive}-operator` | Stackable operators 26.7.0 (Helm OCI) | `stackable-operators` |
| 30 | `hive` | S3Connection + HiveCluster 4.2.0 + Service REST `hive-iceberg-rest:9001` | `data-platform` |

```
gitops/
├── root.yaml                          # App-of-Apps — kubectl apply ครั้งเดียว
├── apps/                              # Application ลูก (Argo CD sync ตาม sync-wave)
│   ├── 10-postgres.yaml
│   ├── 20-stackable-operators.yaml
│   └── 30-hive.yaml
├── postgres/
│   ├── pg-platform.yaml               # CNPG Cluster
│   └── roles/hive.yaml                # ExternalSecret (password) + Database
└── hive/
    ├── s3.yaml                        # SecretClass + ExternalSecret (S3 key) + S3Connection
    └── hive.yaml                      # ExternalSecret (DB) + HiveCluster + Service REST
```

**Secret ทั้งหมดอยู่ใน OpenBao** — ใน Git มีแค่ `ExternalSecret`

| OpenBao path | ใช้กับ |
|---|---|
| `secret/postgres/hive` (`username`, `password`) | role `hive` ใน PostgreSQL และ Hive Metastore |
| `secret/seaweedfs/s3-admin` (`access_key`, `secret_key`) | S3Connection (จากขั้น 07 ข้อ 8) |

| ต้องติดตั้งก่อน | |
|---|---|
| [05-cnpg-operator.md](05-cnpg-operator.md), [06-seaweedfs.md](06-seaweedfs.md), [07-openbao-eso.md](07-openbao-eso.md) (รวมข้อ 8 ย้าย S3 key), [08-argocd.md](08-argocd.md) | |

---

## ขั้นที่ 0: เตรียม (รันบน Mac และ master)

**0.1 Push repo** (Mac) — Argo CD อ่านจาก GitHub

```bash
git push
```

**0.2 สร้าง password ของ Hive ใน OpenBao** (master)

```bash
cd /root/K8S-Stackable/openbao
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token init-keys.json)" bao "$@"; }

bao kv put secret/postgres/hive username=hive password="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
bao kv get -field=username secret/postgres/hive          # hive
bao kv get secret/seaweedfs/s3-admin >/dev/null && echo "S3 key มีแล้ว"
```

**0.3 อัปเดต repo บน master**

```bash
cd /root/K8s-Stackable-repo && git pull
```

---

## ขั้นที่ 1: ดึง image ล่วงหน้า (รันบน master)

```bash
cd /tmp
# Stackable operators (commons / secret / listener / hive)
for op in commons secret listener hive; do
  helm template $op-operator oci://oci.stackable.tech/sdp-charts/$op-operator --version 26.7.0
done | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u > stackable-images.txt

# product image ของ Hive (ใหญ่ ~1 GB) — operator สร้าง pod ด้วย image นี้
echo "oci.stackable.tech/sdp/hive:4.2.0-stackable26.7.0" >> stackable-images.txt
cat stackable-images.txt

nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/stackable-images.txt > /tmp/stackable-prepull.log 2>&1 &
tail -f /tmp/stackable-prepull.log          # Ctrl+C เพื่อออก (script ยังทำงานต่อ)
```

> `oci.stackable.tech` ตอบช้าและ timeout เป็นระยะ — script retry ให้เอง
> PostgreSQL image (`17.11-standard-trixie`) ดึงไว้แล้วในขั้น 05

ต้องจบด้วย `imported` 2 ครั้งและ `=== เสร็จ` ก่อนทำขั้นที่ 2

---

## ขั้นที่ 2: Bootstrap App-of-Apps (รันบน master — ครั้งเดียว)

```bash
kubectl apply -f /root/K8s-Stackable-repo/gitops/root.yaml
kubectl -n argocd get applications -w      # Ctrl+C เมื่อทุกตัวเป็น Synced / Healthy
```

ลำดับที่ควรเห็น (หลายนาที)

```
root                          Synced   Healthy
postgres                      Synced   Healthy      ← wave 10
stackable-commons-operator    Synced   Healthy      ← wave 20 (เริ่มหลัง postgres Healthy)
stackable-secret-operator     Synced   Healthy
stackable-listener-operator   Synced   Healthy
stackable-hive-operator       Synced   Healthy
hive                          Synced   Healthy      ← wave 30
```

ดูรายละเอียดใน UI (`https://argocd.172.19.10.62.sslip.io`) ได้ — กด Application เพื่อดู resource และ event

---

## ขั้นที่ 3: ตรวจ PostgreSQL (รันบน master)

```bash
kubectl -n database get cluster pg-platform            # STATUS: Cluster in healthy state
kubectl -n database get externalsecret,secret | grep -E 'pg-role-hive'
kubectl -n database get database hive                  # APPLIED: true
kubectl -n database exec pg-platform-1 -- psql -U postgres -c '\du hive' -c '\l hive'
```

ต้องเห็น role `hive` (Login) และ database `hive` owner `hive`

---

## ขั้นที่ 4: ตรวจ Stackable operators (รันบน master)

```bash
kubectl -n stackable-operators get pods
kubectl get crd | grep -E 'stackable.tech' | wc -l                 # มี CRD ของ Stackable หลายตัว
kubectl get csidrivers | grep stackable                            # secrets.stackable.tech, listeners.stackable.tech
kubectl get listenerclasses
```

ต้องมี pod ของ commons / secret / listener / hive operator เป็น `Running` (secret และ listener มี DaemonSet บนทุก node)

---

## ขั้นที่ 5: ตรวจ Hive Metastore (รันบน master)

**5.1 Pod และ Service**

```bash
kubectl -n data-platform get externalsecret,s3connection,hivecluster
kubectl -n data-platform get pods -o wide --show-labels
kubectl -n data-platform get svc
```

- pod `hive-metastore-default-0` เป็น `Running` / `READY 1/1`
- label ของ pod ต้องมี `app.kubernetes.io/name=hive`, `app.kubernetes.io/instance=hive`, `app.kubernetes.io/component=metastore` (selector ของ Service `hive-iceberg-rest`) — ถ้าไม่ตรง แก้ `gitops/hive/hive.yaml` แล้ว push
- Service `hive-metastore` (9083) และ `hive-iceberg-rest` (9001)

**5.2 Log — schema และ REST servlet**

```bash
kubectl -n data-platform logs hive-metastore-default-0 -c hive --tail=300 | grep -iE 'schema|servlet|iceberg|9001|error' | tail -30
kubectl -n data-platform get endpointslices -l kubernetes.io/service-name=hive-iceberg-rest
```

ต้องไม่มี error เรื่อง schema และต้องเห็นว่า servlet ของ Iceberg REST เริ่มที่ port 9001

**5.3 ทดสอบ Iceberg REST API**

```bash
kubectl -n data-platform run rest-test --rm -i --image=busybox:1.36 --restart=Never -- sh -c '
  echo "== config";          wget -qO- http://hive-iceberg-rest:9001/iceberg/v1/config; echo
  echo "== create namespace"; wget -qO- --header "Content-Type: application/json" \
        --post-data "{\"namespace\":[\"poc_rest\"]}" http://hive-iceberg-rest:9001/iceberg/v1/namespaces; echo
  echo "== list namespaces";  wget -qO- http://hive-iceberg-rest:9001/iceberg/v1/namespaces; echo'
```

ผลที่ถูกต้อง: `config` ได้ JSON (`defaults` / `overrides`), `list namespaces` มี `poc_rest`

**5.4 ยืนยันว่า REST เขียนลง Hive Metastore ตัวเดียวกับ Thrift**

```bash
kubectl -n database exec pg-platform-1 -- psql -U postgres -d hive -c 'select "NAME", "DB_LOCATION_URI" from "DBS";'
```

ต้องเห็น `poc_rest` พร้อม location `s3a://warehouse/poc_rest.db` — Trino (Thrift) จะเห็น schema นี้ด้วยเมื่อติดตั้งแล้ว

> ⚠️ Service `hive-iceberg-rest` ตั้ง auth เป็น `none` — **ห้ามเปิดผ่าน Ingress / LoadBalancer** ใช้ภายใน cluster เท่านั้น (production ใช้ `oauth2` กับ Keycloak)

---

## วิธีทำงานแบบ GitOps หลังจากนี้

```
แก้ไฟล์ใน gitops/ บน Mac → git commit → git push → Argo CD sync อัตโนมัติ (ภายใน ~3 นาที หรือกด Refresh / Sync ใน UI)
```

| ต้องการ | ทำ |
|---|---|
| แก้ config ของ service | แก้ไฟล์ใน `gitops/<service>/` แล้ว push |
| เพิ่ม service ใหม่ | prepull image บน master → เพิ่มไฟล์ใน `gitops/<service>/` + `gitops/apps/NN-<service>.yaml` → push |
| เพิ่ม database ให้ service ใหม่ | `bao kv put secret/postgres/<service> ...` → เพิ่ม role ใน `gitops/postgres/pg-platform.yaml` + ไฟล์ `gitops/postgres/roles/<service>.yaml` → push |
| **ห้าม** | `kubectl edit` / `helm upgrade` resource ใน ชั้น 1 เอง — Argo CD (`selfHeal: true`) จะเขียนทับกลับตาม Git |

> Application ของ `postgres` และ `hive` ตั้ง `prune: false` — ลบไฟล์ออกจาก Git แล้ว Argo CD **ไม่ลบ** database / HiveCluster ให้ (กันข้อมูลหาย) ต้องลบเองด้วย `kubectl` ถ้าตั้งใจ

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| Application `ComparisonError` / `repository not found` | ยังไม่ได้ `git push` หรือ path ผิด | push แล้วกด Refresh |
| Stackable operator app `Unknown` / error ดึง chart | oci.stackable.tech timeout | รอ retry หรือกด Refresh; ตรวจ Settings → Repositories |
| sync error `metadata.annotations: Too long` | CRD ใหญ่ ไม่ได้ใช้ ServerSideApply | Application ต้องมี `ServerSideApply=true` (มีแล้วใน repo) |
| `postgres` ค้าง `Progressing` / ExternalSecret `SecretSyncedError` | ยังไม่ได้สร้าง `secret/postgres/hive` ใน OpenBao หรือ OpenBao ถูก seal | ขั้น 0.2 / unseal OpenBao |
| `hive` sync error `no matches for kind "HiveCluster"` | CRD ของ Stackable ยังไม่พร้อม | Argo CD retry ให้เอง (limit 10) หรือกด Sync อีกครั้ง |
| Hive pod CrashLoop, log `password authentication failed` | password ใน `hive-db-credentials` ไม่ตรงกับ role | ExternalSecret ทั้ง 2 ตัวอ่าน `secret/postgres/hive` เดียวกัน — ตรวจ `kubectl -n database get secret pg-role-hive` และสถานะ role ใน `kubectl -n database get cluster pg-platform -o yaml \| grep -A5 managedRolesStatus` |
| Hive pod ค้าง `ContainerCreating` นาน | ยังไม่มี image Hive บน node | ขั้นที่ 1 |
| `wget: can't connect` ที่ port 9001 | REST servlet ไม่เปิด (config ไม่ถูกใช้ / image ไม่มีส่วน REST) หรือ selector ของ Service ไม่ตรง | ขั้น 5.1–5.2 — ถ้า image ไม่มีส่วน REST จริง ให้กลับไปดูทางเลือก A / C ใน design doc |
| S3 error ใน log ของ Hive (`403` / `SignatureDoesNotMatch`) | key ผิดหรือไม่ได้ใช้ path-style | `kubectl -n data-platform get secret s3-credentials --show-labels` ต้องมี label `secrets.stackable.tech/class=s3-credentials` |

ดู log

```bash
kubectl -n argocd get applications
kubectl -n argocd describe application hive | sed -n '/Status:/,$p' | head -40
kubectl -n stackable-operators logs deploy/hive-operator-deployment --tail=50
kubectl -n data-platform logs hive-metastore-default-0 -c hive --tail=100
```
