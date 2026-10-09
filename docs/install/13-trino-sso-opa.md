# 13 — Trino: SSO (Keycloak) + สิทธิ์ด้วย OPA (GitOps, PoC)

ปิดช่องโหว่ "Trino ไม่มี authentication" จากขั้นที่ 10 — ทุก request ต้องยืนยันตัวตน และทุก action ถูกตรวจสิทธิ์โดย OPA ตาม group ใน Keycloak

| รายการ | ค่า |
|---|---|
| OPA | **1.16.2** (Stackable opa-operator 26.7.0) — OpaCluster `opa` เป็น DaemonSet ทุก node, ns `data-platform` |
| Authentication | **password** (AuthenticationClass `trino-users`, static) สำหรับ service user + **OIDC** (`keycloak`) สำหรับ Web UI |
| Authorization | OPA — rule ของ Stackable (`gitops/opa/rules/`) + สิทธิ์ของเรา (`gitops/opa/trino_policies.rego`) |
| Group | user-info-fetcher (sidecar ใน pod OPA) ถาม Keycloak ด้วย client `opa-user-info` — ได้ group เป็น path เช่น `/platform-admins` |
| Web UI | `https://trino.172.19.10.62.sslip.io` — login ผ่าน Keycloak (client `trino` มีอยู่แล้วจากขั้นที่ 11) |
| Client (CLI / JDBC / Python) | HTTPS :8443 ภายใน cluster + Basic auth ด้วย service user |
| ไฟล์ใน repo | `gitops/apps/20-stackable-operators.yaml` (เพิ่ม `opa-operator`), `gitops/apps/35-opa.yaml`, `gitops/opa/`, `gitops/trino/{trino,auth}.yaml`, `gitops/cockpit/cockpit.yaml` |
| ต้องติดตั้งก่อน | ขั้นที่ 10 (Trino), 11 (Keycloak) |

```
ผู้ใช้ (browser) ──HTTPS──▶ Traefik (trino.…sslip.io) ──HTTPS :8443──▶ trino-coordinator ──OIDC──▶ Keycloak
Python / Superset / Airflow / Cockpit ──HTTPS :8443 + Basic auth (service user)──▶ trino-coordinator
                                                                                        │ ทุก action: "user X ทำ Y ได้ไหม?"
                                                                                        ▼
                                                     OPA (pod บน node เดียวกัน) ── rule: trino + trino_policies
                                                        └─ user-info-fetcher ──▶ Keycloak admin API: user X อยู่ group ไหน
```

### สิทธิ์ (`gitops/opa/trino_policies.rego`)

| ใคร | iceberg | tpch | system | สร้าง schema / table | ดู query ของคนอื่น |
|---|---|---|---|---|---|
| group `platform-admins`, user `trino-admin` | อ่าน/เขียน | อ่าน/เขียน | อ่าน/เขียน | ✅ ทุก catalog | ✅ |
| group `data-engineers` | อ่าน/เขียน | อ่าน | อ่าน | ✅ เฉพาะ iceberg | — |
| user `airflow` (ETL) | อ่าน/เขียน | — | อ่าน | ✅ เฉพาะ iceberg | — |
| group `analysts`, user `superset`, `cockpit` | อ่าน | อ่าน | อ่าน | — | — |
| user ใน Keycloak ที่ไม่มี group / user อื่น | — | — | อ่าน | — | — |

- ทุกคนดู / kill query **ของตัวเอง** ได้เสมอ
- `superset` และ `cockpit` **impersonate** user อื่นได้ (รัน query ในนามของ user ที่ login อยู่ — สิทธิ์จะเป็นของ user นั้น)
- rule ใช้ตัวแรกที่ตรง (บนลงล่าง) เหมือน [file-based access control ของ Trino](https://trino.io/docs/current/security/file-system-access-control.html)
- แก้สิทธิ์: แก้ `trino_policies.rego` แล้ว push — OPA โหลด bundle ใหม่เอง ไม่ต้อง restart

### Service user (OpenBao `secret/trino/users`)

| User | ใช้กับ |
|---|---|
| `trino-admin` | admin สำหรับ CLI / script / งานดูแลระบบ |
| `superset` | Superset (ขั้นที่ 14) — impersonate user ที่ login Superset |
| `airflow` | Airflow (ขั้นที่ 14) — งาน ETL |
| `cockpit` | Stackable Cockpit — ตอนนี้ปิด impersonation (bug [cockpit#371](https://github.com/stackabletech/cockpit/issues/371)) ทุก query จึงรันในนาม `cockpit` (อ่านอย่างเดียว) |

service user ไม่อยู่ใน Keycloak → user-info-fetcher หาไม่เจอ → ไม่มี group → ใช้ rule ตามชื่อ user

### ข้อจำกัดที่ควรรู้

| เรื่อง | รายละเอียด |
|---|---|
| Web UI ใช้ได้แค่ OIDC | operator ตั้ง `web-ui.authentication.type=oauth2` — service user login Web UI ไม่ได้ (ใช้ได้แค่ผ่าน CLI / JDBC) |
| OIDC ได้ provider เดียว | Trino รองรับ AuthenticationClass แบบ OIDC ได้ตัวเดียว |
| Trino ต้องเชื่อ cert ของ Keycloak | ปิดการตรวจไม่ได้ — ใช้ SecretClass `platform-ca` (k8sSearch หา secret `platform-ca-trust` ใน namespace ของ pod) |
| Traefik → Trino ไม่ตรวจ cert | `ServersTransport insecureSkipVerify` (hop ภายใน cluster) — cert ของ Trino ออกโดย CA ของ secret-operator ซึ่ง Traefik ไม่รู้จัก |
| `http-server.process-forwarded=true` | Trino อยู่หลัง Traefik: ใช้ `X-Forwarded-*` สร้าง redirect URI ของ OAuth2 (ไม่เปิด = Trino ตอบ 406) |
| JDBC / CLI ด้วย SSO | ทำได้ด้วย `--external-authentication` ของ Trino CLI แต่ต้องเข้าถึง :8443 จากเครื่องผู้ใช้ — PoC ใช้ service user ไปก่อน |

---

## ขั้นที่ 1: สร้าง client `opa-user-info` ใน Keycloak (UI)

client นี้ให้ OPA อ่านรายชื่อ user และ group ของ realm `platform` (อ่านอย่างเดียว)

Login `https://keycloak.172.19.10.62.sslip.io/admin/` (realm master) → สลับ realm เป็น **platform** → **Clients → Create client**

| หน้า | ค่า |
|---|---|
| General settings | Client type `OpenID Connect`, Client ID **`opa-user-info`**, Name `OPA user-info-fetcher` |
| Capability config | **Client authentication: On**, Authentication flow: เลือก **Service accounts roles** อย่างเดียว (ปิด Standard flow, Direct access grants) |
| Login settings | เว้นว่าง |

หลัง Save:
1. แท็บ **Service accounts roles** → **Assign role** → เปลี่ยนตัวกรองเป็น **Filter by clients** → ค้น `view-users` → เลือก `realm-management` **view-users** → Assign
2. แท็บ **Credentials** → copy **Client Secret**

## ขั้นที่ 2: เก็บ secret ใน OpenBao (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }

# client secret ของ opa-user-info (จากขั้นที่ 1)
read -rsp 'opa-user-info client secret: ' S; echo
bao kv patch secret/keycloak/clients opa-user-info="$S"; unset S

# password ของ service user ของ Trino (key = username)
gen() { openssl rand -base64 24 | tr -d '/+='; }
bao kv put secret/trino/users trino-admin="$(gen)" superset="$(gen)" airflow="$(gen)" cockpit="$(gen)"

bao kv get -format=json secret/keycloak/clients | jq -r '.data.data | keys[]'    # ต้องมี opa-user-info และ trino
bao kv get -format=json secret/trino/users | jq -r '.data.data | keys[]'         # trino-admin, superset, airflow, cockpit
```

## ขั้นที่ 3: ดึง image ล่วงหน้า (master)

```bash
cd /root/K8s-Stackable-repo && git pull
cd /tmp
helm template opa-operator oci://oci.stackable.tech/sdp-charts/opa-operator --version 26.7.0 \
  | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u > opa-images.txt
echo "oci.stackable.tech/sdp/opa:1.16.2-stackable26.7.0" >> opa-images.txt
cat opa-images.txt

nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/opa-images.txt > /tmp/opa-prepull.log 2>&1 &
tail -f /tmp/opa-prepull.log          # รอจนจบด้วย "=== เสร็จ"
```

## ขั้นที่ 4: Push และ sync

> ทำขั้นที่ 1–2 ให้เสร็จก่อน push — ถ้า secret ยังไม่มี Trino จะ reconcile ไม่ผ่าน (pod เดิมยังรันต่อ แต่ยังไม่มี authentication)

```bash
git push                                                               # Mac
```

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite     # master
kubectl -n argocd get applications -w      # stackable-opa-operator, opa, trino, cockpit → Synced / Healthy
```

```bash
kubectl -n data-platform get opacluster,externalsecret,certificate
kubectl -n data-platform get pods -o wide | grep -E 'opa|trino|cockpit'
# opa-server-default-* 1 pod ต่อ node (หลาย container: opa, bundle-builder, user-info-fetcher)
# trino-coordinator / trino-worker restart ใหม่ (config เปลี่ยน)
```

## ขั้นที่ 5: ตรวจ

**5.1 ไม่มี password = เข้าไม่ได้** (master)

```bash
kubectl -n data-platform run trino-auth-test --rm -i --image=curlimages/curl --restart=Never -- \
  curl -sk -o /dev/null -w '%{http_code}\n' -H 'X-Trino-User: hacker' \
  https://trino-coordinator.data-platform.svc.cluster.local:8443/v1/statement -d 'SELECT 1'
# ต้องได้ 401 (ก่อนขั้นนี้ได้ 200)
```

**5.2 ทดสอบสิทธิ์ด้วย Python** (Mac — เปิด tunnel 18443 ค้างไว้ตาม [10-trino.md](10-trino.md) ขั้นที่ 4.1)

ดึง password ของ `trino-admin` และ `superset` (master)

```bash
bao kv get -field=trino-admin secret/trino/users; bao kv get -field=superset secret/trino/users
```

```bash
read -rsp 'trino-admin password: ' TRINO_ADMIN_PW; echo; export TRINO_ADMIN_PW
read -rsp 'superset password: ' TRINO_SUPERSET_PW; echo; export TRINO_SUPERSET_PW
python - <<'EOF'
import os
from trino.dbapi import connect
from trino.auth import BasicAuthentication
from trino.exceptions import TrinoUserError

def run(label, sql, login, password, as_user=None):
    # as_user = impersonate (ต้องได้รับอนุญาตใน OPA) — ไม่ใส่ = รันในนามของ login
    cur = connect(host="localhost", port=18443, http_scheme="https", verify=False,
                  auth=BasicAuthentication(login, password), user=as_user or login).cursor()
    try:
        cur.execute(sql); print(f"✅ {label}: {cur.fetchall()[:3]}")
    except TrinoUserError as e:
        print(f"⛔ {label}: {e.error_name} — {e.message[:120]}")

A, S = os.environ["TRINO_ADMIN_PW"], os.environ["TRINO_SUPERSET_PW"]
run("trino-admin whoami",      "SELECT current_user", "trino-admin", A)
run("trino-admin select",      "SELECT count(*) FROM iceberg.demo.nation", "trino-admin", A)
run("superset → poc-analyst select (ควรผ่าน)",   "SELECT count(*) FROM iceberg.demo.nation", "superset", S, "poc-analyst")
run("superset → poc-analyst insert (ควรถูกปฏิเสธ)", "INSERT INTO iceberg.demo.nation SELECT * FROM iceberg.demo.nation LIMIT 0", "superset", S, "poc-analyst")
run("superset → poc-engineer insert (ควรผ่าน)",  "INSERT INTO iceberg.demo.nation SELECT * FROM iceberg.demo.nation LIMIT 0", "superset", S, "poc-engineer")
run("superset select เอง (ควรผ่าน)",             "SELECT count(*) FROM tpch.tiny.nation", "superset", S)
run("superset สร้าง schema เอง (ควรถูกปฏิเสธ)",  "CREATE SCHEMA iceberg.should_fail", "superset", S)
EOF
```

ผลที่ถูกต้อง: บรรทัดที่เขียน "ควรถูกปฏิเสธ" ขึ้น `⛔ PERMISSION_DENIED` ที่เหลือ ✅
บรรทัด `superset → poc-analyst` / `poc-engineer` ผ่านได้ก็ต่อเมื่อ user-info-fetcher ดึง group จาก Keycloak ได้ (poc-analyst อยู่ `/analysts`, poc-engineer อยู่ `/data-engineers`)

**5.3 Web UI ผ่าน SSO** (browser บน Mac)

1. เปิด `https://trino.172.19.10.62.sslip.io/ui/` → redirect ไป Keycloak → login `poc-admin`
2. หน้า Cluster Overview → เห็น query จากข้อ 5.2 (platform-admins ดู query ของทุกคนได้)
3. logout แล้ว login `poc-analyst` → เห็นเฉพาะ query ของตัวเอง

**5.4 Cockpit** — เปิด `https://cockpit.172.19.10.62.sslip.io` → รัน `SELECT name FROM iceberg.demo.nation LIMIT 3` ต้องผ่าน (รันในนาม `cockpit`)

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| Application `opa` ค้าง, ExternalSecret `opa-user-info` `SecretSyncedError` | ยังไม่มี `opa-user-info` ใน `secret/keycloak/clients` | ขั้นที่ 2 |
| `trino-coordinator` ไม่ restart / operator log เรื่อง secret `trino-users` หรือ `trino-oidc` | ExternalSecret ยังไม่ sync | `kubectl -n data-platform get externalsecret` แล้วแก้ตามข้อความ |
| ทุก query `PERMISSION_DENIED` รวมถึง `trino-admin` | OPA ยังไม่โหลด rule (bundle) | `kubectl -n data-platform get cm -l opa.stackable.tech/bundle` (ต้องมี `trino-opa-rules`, `trino-opa-policies`) และ log ของ container `bundle-builder` ใน pod OPA |
| `trino-admin` ผ่าน แต่ user จาก Keycloak ถูกปฏิเสธทั้งหมด | user-info-fetcher ดึง group ไม่ได้ | log ของ container `user-info-fetcher` ใน pod OPA — มักเป็น role `view-users` ยังไม่ถูก assign (ขั้นที่ 1) หรือ client secret ผิด |
| user-info-fetcher log เรื่อง certificate | ไม่เชื่อ cert ของ Keycloak | `kubectl -n data-platform get certificate platform-ca-trust` (READY) และ `kubectl -n data-platform get secret platform-ca-trust --show-labels` (มี label `secrets.stackable.tech/class=platform-ca`) |
| Web UI: Keycloak `Invalid parameter: redirect_uri` | redirect URI ของ client `trino` ไม่ตรง | ต้องมี `https://trino.172.19.10.62.sslip.io/*` |
| Web UI: redirect ไป `https://trino-coordinator…:8443/oauth2/callback` | Trino ไม่ใช้ `X-Forwarded-*` | ตรวจว่ามี `http-server.process-forwarded=true` ใน `/stackable/config/config.properties` ของ coordinator |
| Web UI: `no available server` / 500 จาก Traefik | Traefik ต่อ Trino ไม่ได้ | `kubectl -n data-platform get ingressroute,serverstransport` และชื่อ Service `trino-coordinator` (`kubectl -n data-platform get svc`) |
| Cockpit query error `401` | password ใน secret `trino-users` ไม่มี key `cockpit` | ขั้นที่ 2 แล้ว `kubectl -n data-platform rollout restart deploy/cockpit` |

ดู log

```bash
kubectl -n data-platform get pods -l app.kubernetes.io/name=opa
P=$(kubectl -n data-platform get pod -l app.kubernetes.io/name=opa -o name | head -1)
kubectl -n data-platform logs $P -c user-info-fetcher --tail=30
kubectl -n data-platform logs $P -c bundle-builder --tail=30
kubectl -n data-platform logs $P -c opa --tail=30 | grep -i decision | tail -5
kubectl -n data-platform logs trino-coordinator-default-0 -c trino --tail=100 | grep -iE 'oauth|denied|error'
```

## ย้อนกลับ (ปิด authentication ชั่วคราว)

ลบบล็อก `authentication:` และ `authorization:` ออกจาก `gitops/trino/trino.yaml` แล้ว push — Trino กลับไปเป็นแบบไม่มี authentication (อย่าลืมเปลี่ยน Cockpit กลับเป็น `STACKABLE_COCKPIT_TRINO_AUTH_TYPE=none`)
