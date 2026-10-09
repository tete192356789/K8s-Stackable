# 10 — Trino 481 (GitOps, PoC)

Query engine ของ platform — อ่าน/เขียนตาราง Iceberg บน SeaweedFS ผ่าน Hive Metastore (Thrift)

> **หลังขั้นที่ 13** Trino มี authentication (password / Keycloak) และ OPA แล้ว — ตัวอย่าง Python ในขั้นที่ 4 ต้องเพิ่ม `auth=BasicAuthentication("trino-admin", ...)` ดู [13-trino-sso-opa.md](13-trino-sso-opa.md)

| รายการ | ค่า |
|---|---|
| Trino | 481 (Stackable 26.7.0, image `oci.stackable.tech/sdp/trino:481-stackable26.7.0`) |
| Node | coordinator 1 (3 GB) + worker 1 (5 GB) |
| Client | **HTTPS :8443 ไม่มี authentication** (PoC ช่วงแรก) — เข้าถึงได้แค่ภายใน cluster / port-forward; cert ออกโดย CA ของ secret-operator (SecretClass `tls`) |
| Catalog | `iceberg` (Hive Metastore + SeaweedFS), `tpch` (ข้อมูลตัวอย่าง) |
| Namespace | `data-platform` (เดียวกับ Hive — ใช้ S3Connection `seaweedfs` และ ConfigMap `hive` ร่วมกัน) |
| ไฟล์ใน repo | `gitops/apps/20-stackable-operators.yaml` (เพิ่ม `trino-operator`), `gitops/apps/25-s3-tls.yaml` + `gitops/s3-tls/`, `gitops/hive/s3.yaml` (S3Connection แบบ TLS), `gitops/apps/40-trino.yaml`, `gitops/trino/trino.yaml` |
| ต้องติดตั้งก่อน | [09-gitops-hive.md](09-gitops-hive.md) |

### S3 ต้องเป็น TLS

trino-operator ของ Stackable **บังคับให้ Trino 469 ขึ้นไปต่อ S3 ผ่าน TLS** (ไม่อย่างนั้น operator ไม่สร้าง pod เลย — log: `trino 469 and greater require TLS for S3`)
SeaweedFS chart เปิด HTTPS ให้ S3 ได้เฉพาะเมื่อเปิด `enableSecurity` (mTLS ทั้งระบบ) จึงให้ **Traefik ทำ TLS อยู่หน้า S3** สำหรับ traffic ภายใน cluster:

```
Trino / Hive ──HTTPS :443──▶ s3-tls.seaweedfs.svc.cluster.local (Service ExternalName → traefik.traefik.svc)
                                └─ Traefik: cert seaweedfs-s3-tls (cert-manager, platform-ca) ──HTTP :8333──▶ seaweedfs-s3
```

| Resource (`gitops/s3-tls/s3-tls.yaml`) | หน้าที่ |
|---|---|
| Certificate `seaweedfs-s3-tls` (ns `seaweedfs`) | cert สำหรับชื่อ `s3-tls.seaweedfs.svc.cluster.local` จาก ClusterIssuer `platform-ca` — secret ติด label `secrets.stackable.tech/class=seaweedfs-s3-ca` |
| SecretClass `seaweedfs-s3-ca` | ให้ Stackable หา `ca.crt` จาก secret ข้างบน (k8sSearch ใน ns `seaweedfs`) เพื่อตรวจ cert ของ S3 |
| Service `s3-tls` (ExternalName) | ชื่อ DNS ภายใน cluster ที่ชี้ไปหา Traefik |
| Ingress `seaweedfs-s3-tls` | Traefik route host นี้ → `seaweedfs-s3:8333` ด้วย cert ข้างบน |

S3Connection `seaweedfs` (`gitops/hive/s3.yaml`) จึงเปลี่ยนเป็น `host: s3-tls.seaweedfs.svc.cluster.local`, `port: 443`, `tls.verification.server.caCert.secretClass: seaweedfs-s3-ca` — Hive ใช้ S3Connection เดียวกันจึงเปลี่ยนเป็น TLS ด้วย (pod ของ Hive restart เองหลัง sync)

> secret `seaweedfs-s3-tls` มี `tls.key` อยู่ด้วยและ secret-operator mount ทุก key — PoC รับได้ (production ควรใช้ trust-manager แจก CA อย่างเดียว)

```
Python / DBeaver / Superset ──HTTPS :8443──▶ trino-coordinator ──▶ trino-worker
                                                 │ Thrift :9083            │ S3 (path-style)
                                                 ▼                         ▼
                                           Hive Metastore            SeaweedFS (warehouse/)
```

> ⚠️ **ไม่มี authentication** — ใครเข้าถึง port 8443 ได้ query / ลบข้อมูลได้ทุกตาราง
> ห้ามเปิดผ่าน Ingress / LoadBalancer จนกว่าจะเพิ่ม Keycloak (OIDC) — TLS เปิดอยู่แล้ว (Trino บังคับ TLS เมื่อมี authentication)

---

## ค่าที่ตั้ง

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `clusterConfig.tls` | ไม่ตั้ง (ใช้ค่าเริ่มต้น `tls`) | HTTPS :8443 ทั้งฝั่ง client และภายใน — ไม่ปิด TLS เพราะ authentication ภายหลังบังคับต้องมี TLS และการตั้ง `serverSecretClass: null` ไม่รอดผ่าน Argo CD (ค่า null หายระหว่าง apply แล้ว API server เติม `tls` ให้ → Application OutOfSync ตลอด) |
| `coordinators.config.resources` | CPU 250m–1, memory 3Gi | ค่าเริ่มต้นของ operator คือ 4Gi — ลดตามงบ RAM ของ PoC |
| `workers.config.resources` | CPU 0.5–2, memory 5Gi | worker ทำงานหนักกว่า coordinator |
| TrinoCatalog `iceberg` | `metastore.configMap: hive`, `s3.reference: seaweedfs` | operator สร้าง config ของ Iceberg connector ให้เอง (endpoint, path-style, credential) |
| TrinoCatalog `tpch` | — | ข้อมูลตัวอย่าง (`tpch.tiny.nation` ฯลฯ) ไว้สร้างตารางทดสอบ |

---

## ขั้นที่ 1: Push และดึง image ล่วงหน้า

**1.1 Push** (Mac) — ถ้ายังไม่ได้ push

```bash
git push
```

**1.2 ดึง image** (master) — image ของ Trino ใหญ่ (~1.5 GB) ใช้เวลานาน

```bash
cd /root/K8s-Stackable-repo && git pull
cd /tmp
helm template trino-operator oci://oci.stackable.tech/sdp-charts/trino-operator --version 26.7.0 \
  | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u > trino-images.txt
echo "oci.stackable.tech/sdp/trino:481-stackable26.7.0" >> trino-images.txt
cat trino-images.txt

nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/trino-images.txt > /tmp/trino-prepull.log 2>&1 &
tail -f /tmp/trino-prepull.log          # รอจนจบด้วย "=== เสร็จ"
```

> ถ้า Argo CD sync ก่อนดึง image เสร็จ ไม่เสียหาย — pod จะรอดึง image เอง แค่นานกว่า

---

## ขั้นที่ 2: ให้ Argo CD sync (master)

root app จะเห็น `stackable-trino-operator` (wave 20), `s3-tls` (wave 25) และ `trino` (wave 40) ภายใน ~3 นาที หรือสั่ง refresh ทันที

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get applications -w            # stackable-trino-operator, s3-tls, hive และ trino ต้องเป็น Synced / Healthy
```

ตรวจ S3 ผ่าน TLS ก่อน

```bash
kubectl -n seaweedfs get certificate seaweedfs-s3-tls                 # READY True
kubectl -n seaweedfs get secret seaweedfs-s3-tls --show-labels        # มี label secrets.stackable.tech/class=seaweedfs-s3-ca
kubectl -n data-platform run s3tls-test --rm -i --image=busybox:1.36 --restart=Never -- \
  wget -S -O- --no-check-certificate https://s3-tls.seaweedfs.svc.cluster.local/ 2>&1 | grep -E 'HTTP/|Error'
# ต้องได้ HTTP/1.1 403 (S3 ตอบว่าไม่ได้ส่ง key มา = ผ่าน Traefik ถึง SeaweedFS แล้ว)
kubectl -n data-platform get pods                                     # hive-metastore restart ใหม่หลัง S3Connection เปลี่ยน
```

---

## ขั้นที่ 3: ตรวจ (master)

```bash
kubectl -n data-platform get trinocluster,trinocatalog
kubectl -n data-platform get pods -o wide            # trino-coordinator-default-0 และ trino-worker-default-0 เป็น 1/1
kubectl -n data-platform get svc | grep trino

# TLS ค่าเริ่มต้น — ต้องเห็น serverSecretClass=tls และ Service มี port 8443
kubectl -n data-platform get trinocluster trino -o jsonpath='{.spec.clusterConfig.tls}'; echo
kubectl -n data-platform logs trino-coordinator-default-0 -c trino --tail=200 | grep -iE 'SERVER STARTED|error' | tail -5
```

---

## ขั้นที่ 4: ทดสอบด้วย Python จาก Mac

**4.1 เปิด tunnel** (Mac — เปิด terminal ค้างไว้) ใช้ port 18443 บน Mac กันชนกับ tunnel อื่น

```bash
ssh -L 18443:localhost:18443 k8s-master \
  'kubectl -n data-platform port-forward svc/trino-coordinator 18443:8443'
```

ชื่อ Service ตรวจได้จากขั้นที่ 3 (`kubectl -n data-platform get svc | grep trino`)

**4.2 รัน query** (Mac — อีก terminal)

```bash
pip install trino
python - <<'EOF'
from trino.dbapi import connect
# verify=False: cert ของ Trino ออกโดย CA ของ secret-operator (ไม่ใช่ internal CA ของ cert-manager) และชื่อใน cert ไม่ใช่ localhost
cur = connect(host="localhost", port=18443, user="admin", catalog="iceberg", schema="default",
              http_scheme="https", verify=False).cursor()

def q(sql):
    cur.execute(sql)
    rows = cur.fetchall()
    print(f"\n> {sql}\n{rows}")

q("SHOW CATALOGS")                                                  # iceberg, system, tpch
q("SHOW SCHEMAS FROM iceberg")                                      # ต้องเห็น poc_rest (สร้างผ่าน REST ในขั้น 09)
q("CREATE SCHEMA IF NOT EXISTS iceberg.demo WITH (location = 's3a://warehouse/external/demo.db')")
q("CREATE TABLE IF NOT EXISTS iceberg.demo.nation WITH (format_version = 2) AS SELECT * FROM tpch.tiny.nation")
q("SELECT count(*) FROM iceberg.demo.nation")                       # 25
q("SELECT name FROM iceberg.demo.nation ORDER BY nationkey LIMIT 3")
q('SELECT snapshot_id, operation FROM iceberg.demo."nation$snapshots"')
EOF
```

**4.3 ยืนยันว่า REST เห็นตารางที่ Trino สร้าง** (master) — Thrift และ REST ใช้ Hive Metastore ตัวเดียวกัน

```bash
kubectl -n data-platform run rest-test --rm -i --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://hive-iceberg-rest:9001/iceberg/v1/namespaces/demo/tables; echo
```

ต้องเห็น `{"identifiers":[{"namespace":["demo"],"name":"nation"}]...}`

**4.4 ไฟล์จริงบน SeaweedFS** (Mac — ใช้ AWS CLI ตาม 06 ขั้นที่ 6)

```bash
aws --endpoint-url https://s3.172.19.10.62.sslip.io s3 ls --recursive s3://warehouse/external/demo.db/ | head
```

ต้องเห็นไฟล์ `data/*.parquet` และ `metadata/*.metadata.json`

**Trino Web UI:** เปิด `https://localhost:18443/ui/` ระหว่างที่ tunnel เปิดอยู่ (browser จะเตือนเรื่อง cert — กดยอมรับได้; ใส่ username อะไรก็ได้ — ยังไม่มี authentication)

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| operator log `trino 469 and greater require TLS for S3` / ไม่มี pod ของ Trino | S3Connection ยังเป็น HTTP | ใช้ S3Connection แบบ TLS (`gitops/hive/s3.yaml` + `gitops/s3-tls/`) |
| Hive / Trino error `PKIX path building failed` / `unable to find valid certification path` ตอนใช้ S3 | ไม่เชื่อ cert ของ S3 | ตรวจ secret `seaweedfs-s3-tls` มี `ca.crt` และ label ถูก, SecretClass `seaweedfs-s3-ca` มีอยู่ |
| `wget` / Trino ต่อ `s3-tls...:443` แล้ว 404 | Traefik ไม่มี route ของ host นี้ | `kubectl -n seaweedfs get ingress seaweedfs-s3-tls` |
| Python error `SSL: CERTIFICATE_VERIFY_FAILED` | cert ของ Trino ออกโดย CA ของ secret-operator | ใช้ `verify=False` (PoC) หรือ export CA: `kubectl -n stackable-operators get secret secret-provisioner-tls-ca -o jsonpath='{.data.ca\.crt}' \| base64 -d` แล้วใช้ `verify="ca.crt"` (ชื่อ host ใน cert ต้องตรงด้วย) |
| Application `trino` OutOfSync ที่ `TrinoCluster/trino` | ค่าใน Git ไม่ตรงกับที่ API server / webhook เติมให้ | ดู APP DIFF ใน UI — อย่าตั้ง `serverSecretClass: null` (ค่า null ไม่รอดผ่าน Argo CD) |
| pod `Pending` / `Insufficient memory` | node ไม่มี RAM ว่างพอ (worker ขอ 5Gi) | `kubectl -n data-platform describe pod trino-worker-default-0`; ลด `memory.limit` ของ worker เป็น 4Gi แล้ว push |
| query error `Access Denied` / `Failed checking path` ตอน CREATE TABLE | S3 key / path-style ผิด | `kubectl -n data-platform get secret s3-credentials --show-labels` และ log ของ worker |
| `SHOW SCHEMAS` ไม่เห็น `poc_rest` / error ต่อ metastore | Trino ต่อ Hive Metastore ไม่ได้ | `kubectl -n data-platform get cm hive -o yaml` (ต้องมี `HIVE` = `thrift://...:9083`) |
| query ช้าหรือ worker ถูก OOM kill | ข้อมูลใหญ่เกิน RAM ของ PoC | ใช้ข้อมูลทดสอบขนาดเล็ก (`tpch.tiny`, `tpch.sf1`) |

ดู log

```bash
kubectl -n data-platform logs trino-coordinator-default-0 -c trino --tail=100
kubectl -n data-platform logs trino-worker-default-0 -c trino --tail=100
kubectl -n stackable-operators logs deploy/stackable-trino-operator-deployment --tail=50
```
