# 14 — Apache Superset 6.1.0 (GitOps, PoC)

Dashboard และ SQL Lab บนเว็บ — login ผ่าน Keycloak, query Trino **ในนามของคนที่ login** (OPA ตรวจสิทธิ์ตาม group ของคนนั้น)

| รายการ | ค่า |
|---|---|
| Superset | **6.1.0** (Stackable superset-operator 26.7.0, image `oci.stackable.tech/sdp/superset:6.1.0-stackable26.7.0`) |
| URL | `https://superset.172.19.10.62.sslip.io` |
| Login | Keycloak เท่านั้น — client `superset` (มีอยู่แล้วจาก realm import ขั้นที่ 11), AuthenticationClass `keycloak` ตัวเดียวกับ Trino |
| Metadata DB | database `superset` บน `pg-platform` (password: OpenBao `secret/postgres/superset`) |
| ต่อ Trino | service user `superset` (Basic auth, HTTPS :8443) + **impersonate** คนที่ login |
| Namespace | `data-platform` |
| RAM | node: limit 1.5 GB (+ statsd exporter 64 MB) |
| ไฟล์ใน repo | `gitops/apps/20-stackable-operators.yaml` (เพิ่ม `superset-operator`), `gitops/apps/55-superset.yaml`, `gitops/superset/superset.yaml`, `gitops/postgres/pg-platform.yaml` (role `superset`), `gitops/postgres/roles/superset.yaml` |
| ต้องติดตั้งก่อน | ขั้นที่ 13 (Trino + OPA) |

```
ผู้ใช้ ──HTTPS──▶ Traefik ──HTTP :8088──▶ superset-node ──OIDC──▶ Keycloak (realm platform)
                                              │ metadata ──▶ pg-platform (db superset)
                                              └ SQL: login = superset, X-Trino-User = <คนที่ login> ──▶ Trino ──▶ OPA
```

### Role ใน Superset (มาจาก group ใน Keycloak ทุกครั้งที่ login)

| Group ใน Keycloak | Role ใน Superset | ทำอะไรได้ |
|---|---|---|
| `platform-admins` | `Admin` | ทุกอย่าง รวมถึงตั้งค่า database / user / role |
| `data-engineers` | `Alpha` + `sql_lab` | สร้าง dataset / chart / dashboard, ใช้ SQL Lab, เข้าถึงทุก database |
| `analysts` | `Gamma` + `sql_lab` + `trino_access` | ดู dashboard, ใช้ SQL Lab กับ database Trino |
| ไม่มี group | `Public` | แทบไม่เห็นอะไร |

- **สิทธิ์ข้อมูลจริงตัดสินที่ Trino (OPA)** — Superset ส่งชื่อคนที่ login ไปให้ Trino (impersonate) analysts จึง SELECT ได้อย่างเดียวแม้ใช้ SQL Lab
- role `trino_access` สร้างเองใน UI (ขั้นที่ 5.3) — Admin / Alpha เข้าถึงทุก database อยู่แล้ว แต่ Gamma ต้องได้สิทธิ์ database แยก
- ย้าย group ใน Keycloak แล้ว role เปลี่ยนตอน login ครั้งถัดไป (`syncRolesAt: Login`) — **แก้ role ของ user ใน Superset UI ไม่ได้ผล** (ถูกเขียนทับตอน login)

### ค่าที่ตั้ง

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `metadataDatabase.postgresql` | `pg-platform-rw…:5432/superset` + secret `superset-db` | 26.7 เปลี่ยนจาก connection string เป็น struct — password ต้องไม่มีอักขระพิเศษ (operator ไม่ escape ใน URI) |
| `credentialsSecret` | `superset-admin` (`adminUser.*`) | operator สร้าง admin ภายในตอน start — เปิดแค่ OIDC จึง login ด้วย user นี้ผ่านหน้าเว็บไม่ได้ |
| `SECRET_KEY` | operator สร้าง Secret `superset-secret-key` ให้เอง | ใช้เข้ารหัส password ของ database ที่บันทึกใน Superset — **ห้ามลบ** (ไม่อย่างนั้นต้องใส่ password ของ Trino ใหม่) |
| `userRegistrationRole` | `Public` | user ใหม่ได้ role ว่าง — สิทธิ์จริงมาจาก `AUTH_ROLES_MAPPING` |
| `ENABLE_PROXY_FIX` | `True` | อยู่หลัง Traefik: ใช้ `X-Forwarded-*` สร้าง redirect URI `https://superset…/oauth-authorized/keycloak` |
| `resources.memory.limit` | `1536Mi` | ค่าเริ่มต้น 2Gi — ลดตามงบ RAM |

---

## ขั้นที่ 0: ตรวจ RAM (master)

```bash
kubectl describe nodes | grep -E '^Name:|^  memory'
```

Superset ขอ ~1.6 GB — ถ้าทุก node เกิน ~85% ให้แจ้งก่อน

## ขั้นที่ 1: เตรียม secret ใน OpenBao (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }
gen() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-32; }     # ตัวอักษร + ตัวเลขเท่านั้น

bao kv put secret/postgres/superset username=superset password="$(gen)"
bao kv put secret/superset/admin password="$(gen)"

bao kv get -format=json secret/keycloak/clients | jq -r '.data.data | keys[]'    # ต้องมี superset (จากขั้นที่ 11)
```

## ขั้นที่ 2: ดึง image ล่วงหน้า (master)

image ของ Superset ใหญ่ (~1 GB) — ใช้เวลานาน

```bash
cd /root/K8s-Stackable-repo && git pull
cd /tmp
helm template superset-operator oci://oci.stackable.tech/sdp-charts/superset-operator --version 26.7.0 \
  | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u > superset-images.txt
echo "oci.stackable.tech/sdp/superset:6.1.0-stackable26.7.0" >> superset-images.txt
cat superset-images.txt

nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/superset-images.txt > /tmp/superset-prepull.log 2>&1 &
tail -f /tmp/superset-prepull.log          # รอจนจบด้วย "=== เสร็จ"
```

## ขั้นที่ 3: Push และ sync

```bash
git push                                                               # Mac
```

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite     # master
kubectl -n argocd get applications -w      # postgres, stackable-superset-operator, superset → Synced / Healthy
```

```bash
kubectl -n database get database superset                  # APPLIED true
kubectl -n data-platform get supersetcluster,externalsecret | grep -E 'NAME|superset'
kubectl -n data-platform get pods | grep superset          # superset-node-default-0 2/2 (start ครั้งแรก ~2–3 นาที: db upgrade + init)
kubectl -n data-platform logs superset-node-default-0 -c superset --tail=30
```

## ขั้นที่ 4: Login ผ่าน Keycloak (browser บน Mac)

1. เปิด `https://superset.172.19.10.62.sslip.io` → **Sign in with keycloak** → login `admin` (group `platform-admins`)
2. มุมขวาบน **Settings → List Users** → user `admin` ต้องมี role **Admin**

## ขั้นที่ 5: เพิ่ม Trino เป็น database (UI, login เป็น Admin)

**5.1 ดึง password ของ service user `superset`** (master)

```bash
bao kv get -field=superset secret/trino/users; echo
```

**5.2 เพิ่ม database** — **Settings → Database Connections → + Database** → เลือก **Trino** (หรือ "Other" ถ้าไม่มีในรายการ)

| ช่อง | ค่า |
|---|---|
| Display name | `Trino` |
| SQLAlchemy URI | `trino://superset:<password จาก 5.1>@trino-coordinator.data-platform.svc.cluster.local:8443/iceberg` |
| Advanced → Other → Engine parameters | `{"connect_args": {"http_scheme": "https", "verify": false}}` |
| Advanced → SQL Lab | ✅ Expose database in SQL Lab, ✅ Allow DML, ✅ Allow this database to be explored |
| Advanced → Security | ✅ **Impersonate logged in user** |

กด **Test connection** → `Connection looks good!` → **Connect**

> `verify: false` — cert ของ Trino ออกโดย CA ของ secret-operator (hop ภายใน cluster, PoC)
> **Impersonate logged in user** สำคัญที่สุด — ไม่เปิด = ทุก query รันในนาม `superset` (อ่านอย่างเดียวทุกคน)

**5.3 สร้าง role `trino_access`** (ให้ analysts ใช้ database Trino ได้) — **Settings → List Roles → +**
- Name: `trino_access`
- Permissions: `database access on [Trino].(id:1)` (พิมพ์ `Trino` ในช่องค้นหา)
- Save

## ขั้นที่ 6: ทดสอบ

**6.1 SQL Lab** — **SQL → SQL Lab** → database `Trino`, schema `demo`

```sql
SELECT current_user;                                  -- ต้องได้ admin (ไม่ใช่ superset) = impersonation ทำงาน
SELECT name FROM iceberg.demo.nation LIMIT 5;
```

**6.2 user อื่น** — logout แล้ว login `poc-engineer` (ต้องตั้ง password ใน Keycloak ก่อน: Users → poc-engineer → Credentials)
- role ต้องเป็น `Alpha` + `sql_lab`
- SQL Lab: `SELECT current_user` → `poc-engineer`
- `CREATE TABLE iceberg.demo.t1 AS SELECT 1 AS x` → ผ่าน (data-engineers เขียน iceberg ได้) แล้ว `DROP TABLE iceberg.demo.t1`

**6.3 ดูใน Trino** — `https://trino.172.19.10.62.sslip.io/ui/` (login `admin`) → คอลัมน์ User ของ query จาก Superset ต้องเป็นชื่อคนที่ login Superset

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| ExternalSecret `superset-*` `SecretSyncedError` | ยังไม่มี secret ใน OpenBao | ขั้นที่ 1 |
| pod CrashLoop, log `password authentication failed for user "superset"` | role ใน PostgreSQL ยังไม่ถูกสร้าง / password ไม่ตรง | `kubectl -n database get database superset` และ `kubectl -n database get cluster pg-platform -o jsonpath='{.status.managedRolesStatus}'` |
| pod CrashLoop, log เรื่อง `database "superset" does not exist` | Database CR ยังไม่ apply | Application `postgres` ต้อง Synced (`kubectl -n argocd get app postgres`) |
| Keycloak `Invalid parameter: redirect_uri` | redirect URI ไม่ตรง | client `superset` ต้องมี `https://superset.172.19.10.62.sslip.io/*` |
| redirect ไป `http://…:8088/oauth-authorized/keycloak` | ProxyFix ไม่ทำงาน | ตรวจ `ENABLE_PROXY_FIX = True` ใน `kubectl -n data-platform exec superset-node-default-0 -c superset -- cat /stackable/app/pythonpath/superset_config.py` |
| login แล้วได้ role `Public` อย่างเดียว | ไม่มี claim `groups` ใน userinfo | mapper `groups` ของ client `superset` ต้องเปิด "Add to userinfo" และ Full group path: Off |
| login แล้ว error `x509` / `CERTIFICATE_VERIFY_FAILED` | ไม่เชื่อ cert ของ Keycloak | SecretClass `platform-ca` + secret `platform-ca-trust` ต้องอยู่ใน `data-platform` (ขั้นที่ 13) |
| Test connection: `401` | password ของ `superset` ใน URI ผิด | ขั้นที่ 5.1 |
| Test connection: `Cannot impersonate user` | ไม่ใช่ปัญหาตอน test — ถ้าเกิดตอน query: OPA ไม่ได้อนุญาต `superset` impersonate | ตรวจ `impersonation` ใน `gitops/opa/trino_policies.rego` |
| SQL Lab ของ analyst ไม่เห็น database Trino | ยังไม่ได้สร้าง role `trino_access` | ขั้นที่ 5.3 แล้ว logout / login ใหม่ |
| SQL Lab: `Access Denied: Cannot access catalog iceberg` | user ไม่มี group ใน Keycloak (OPA ไม่ให้สิทธิ์) | เพิ่ม user เข้า group ใน Keycloak |

ดู log

```bash
kubectl -n data-platform logs superset-node-default-0 -c superset --tail=100 | grep -iE 'error|oauth|role'
kubectl -n stackable-operators logs deploy/stackable-superset-operator-deployment --tail=50
```
