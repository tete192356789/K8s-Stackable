# 11 — Keycloak 26.7.4 (GitOps, PoC)

ระบบ login กลาง (SSO / OIDC) ของ platform — realm `platform` ใช้กับ Argo CD, Grafana, Trino, Superset, Airflow, OpenBao (ต่อแต่ละ service ในขั้นของ service นั้น)

| รายการ | ค่า |
|---|---|
| Keycloak | 26.7.4 ผ่าน **Keycloak Operator** (manifest ทางการ `keycloak/keycloak-k8s-resources` tag 26.7.4) |
| Namespace | `keycloak` (manifest ของ operator กำหนดไว้ตายตัว) |
| Instance | 1 (memory limit 1.5 GB) |
| Database | `keycloak` บน `pg-platform` (password: OpenBao `secret/postgres/keycloak`) |
| URL | `https://keycloak.172.19.10.62.sslip.io` (TLS จบที่ Traefik, wildcard cert จาก internal CA) |
| Realm | `platform` — group 3 ตัว + client 6 ตัว import ครั้งแรกจาก Git |
| Client secret | OpenBao `secret/keycloak/clients` → ESO → placeholder ใน realm import |
| ไฟล์ใน repo | `gitops/apps/20-keycloak-operator.yaml`, `gitops/apps/50-keycloak.yaml`, `gitops/keycloak/`, `gitops/postgres/roles/keycloak.yaml`, `gitops/postgres/pg-platform.yaml` (role `keycloak`) |
| ต้องติดตั้งก่อน | [09-gitops-hive.md](09-gitops-hive.md) (PostgreSQL + GitOps) |

```
OpenBao ─ESO─▶ keycloak-db ──────────────▶ Keycloak CR ──▶ pod keycloak-0 ──▶ pg-platform (db keycloak)
        └ESO─▶ keycloak-client-secrets ──▶ KeycloakRealmImport "platform" (placeholder ${..._SECRET})
ผู้ใช้ ──HTTPS──▶ Traefik ──HTTP :8080──▶ keycloak-service
```

---

## การจัดการ realm (แบบผสม)

| ส่วน | จัดการที่ | หมายเหตุ |
|---|---|---|
| realm `platform`, group, client พื้นฐาน | Git (`gitops/keycloak/realm-platform.yaml`) | **import ครั้งเดียว** — `KeycloakRealmImport` ไม่ update / ไม่เขียนทับ realm ที่มีอยู่ แก้ไฟล์นี้ภายหลังจะไม่มีผล |
| user, การใส่ user เข้า group, ปรับรายละเอียด client | UI ของ Keycloak | ทำได้ตลอด |
| client secret | OpenBao | ห้ามอยู่ใน Git (repo public) |

| Group | ใช้ทำอะไร (กำหนดสิทธิ์จริงในขั้นของแต่ละ service) |
|---|---|
| `platform-admins` | ดูแลระบบ: Argo CD admin, Grafana admin, OpenBao |
| `data-engineers` | สร้าง / แก้ตาราง, จัดการ Airflow |
| `analysts` | query และดู dashboard อย่างเดียว |

| Client | Redirect URI (PoC ใช้ wildcard ต่อ host) |
|---|---|
| `argocd` | `https://argocd.172.19.10.62.sslip.io/*`, `http://localhost:8085/*` (argocd CLI) |
| `grafana` | `https://grafana.172.19.10.62.sslip.io/*` |
| `trino` | `https://trino.172.19.10.62.sslip.io/*` |
| `superset` | `https://superset.172.19.10.62.sslip.io/*` |
| `airflow` | `https://airflow.172.19.10.62.sslip.io/*` |
| `openbao` | `https://bao.172.19.10.62.sslip.io/*`, `http://localhost:8250/*` (bao CLI) |

ทุก client ส่ง claim **`groups`** (ชื่อ group ไม่มี `/` นำหน้า) ใน ID token, access token และ userinfo

> ทำไมไม่ใช้ CRD `KeycloakOIDCClient` (จัดการ client แบบ GitOps ต่อเนื่อง): ใน 26.7 ยังเป็น **experimental** (เป็น preview ใน 26.8) — ทบทวนอีกครั้งตอนอัปเกรด Keycloak

---

## ขั้นที่ 1: เตรียม secret ใน OpenBao (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }
gen() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-32; }

bao kv put secret/postgres/keycloak username=keycloak password="$(gen)"
bao kv put secret/keycloak/clients \
  argocd="$(gen)" grafana="$(gen)" trino="$(gen)" superset="$(gen)" airflow="$(gen)" openbao="$(gen)"

bao kv list secret/keycloak
bao kv get -format=json secret/keycloak/clients | jq -r '.data.data | keys[]'     # แสดงแค่ชื่อ ไม่แสดงค่า
```

> ต้องทำก่อน push / sync — ไม่อย่างนั้น ExternalSecret จะ error และ realm import จะไม่มี client secret

---

## ขั้นที่ 2: ดึง image ล่วงหน้า (master)

```bash
cat > /tmp/keycloak-images.txt <<'EOF'
quay.io/keycloak/keycloak-operator:26.7.4
quay.io/keycloak/keycloak:26.7.4
EOF
nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/keycloak-images.txt > /tmp/keycloak-prepull.log 2>&1 &
tail -f /tmp/keycloak-prepull.log          # รอจนจบด้วย "=== เสร็จ"
```

> Deployment ของ operator ตั้ง `imagePullPolicy: Always` — node จะเช็ก registry ทุกครั้งที่สร้าง pod แต่ layer ที่ดึงไว้แล้วไม่ต้องโหลดใหม่

---

## ขั้นที่ 3: Push และ sync

```bash
git push                                                             # Mac
```

```bash
cd /root/K8s-Stackable-repo && git pull                              # master
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get applications -w      # keycloak-operator (wave 20), postgres (role keycloak), keycloak (wave 50) → Synced / Healthy
```

---

## ขั้นที่ 4: ตรวจ (master)

```bash
kubectl -n database get database keycloak                          # APPLIED true
kubectl -n keycloak get pods                                       # keycloak-operator-..., keycloak-0 Running 1/1
kubectl -n keycloak get keycloak keycloak -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl -n keycloak get externalsecret                             # keycloak-db, keycloak-client-secrets → SecretSynced
kubectl -n keycloak get keycloakrealmimport platform -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

- Keycloak: `Ready=True`
- Realm import: `Done=True` (operator สร้าง Job ชั่วคราวเพื่อ import — pod ของ Job จบเป็น `Completed`)

ทดสอบ OIDC discovery ของ realm (ใช้ทั้งจาก Mac และจาก pod ใน cluster — เครื่องที่ import CA แล้ว)

```bash
curl -s https://keycloak.172.19.10.62.sslip.io/realms/platform/.well-known/openid-configuration | jq '{issuer, authorization_endpoint}'
```

ต้องได้ `"issuer": "https://keycloak.172.19.10.62.sslip.io/realms/platform"`

---

## ขั้นที่ 5: Admin ถาวร + user ทดสอบ (UI)

**5.1 Login ด้วย admin ชั่วคราว** (master realm)

```bash
kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

เปิด `https://keycloak.172.19.10.62.sslip.io/admin/` → login

**5.2 สร้าง admin ถาวร** (realm **master**) — Users → Add user (เช่น `kcadmin`) → Credentials → Set password (ปิด Temporary) → Role mapping → Assign role → `admin`
แล้วเก็บรหัสใน OpenBao และลบ admin ชั่วคราว

```bash
read -rsp 'Keycloak kcadmin password: ' KC_PASS; echo
bao kv put secret/keycloak/admin username=kcadmin password="$KC_PASS"; unset KC_PASS
```

ใน UI: master realm → Users → ลบ user ชั่วคราว (`temp-admin` หรือชื่อตาม secret)

**5.3 สร้าง user ทดสอบ** (realm **platform**) — สลับ realm มุมบนซ้ายเป็น `platform` → Users → Add user

| User | Group |
|---|---|
| `poc-admin` | `platform-admins` |
| `poc-engineer` | `data-engineers` |
| `poc-analyst` | `analysts` |

ตั้ง password ให้แต่ละ user (Credentials → Set password)

**5.4 ทดสอบ login ของ user** — เปิด `https://keycloak.172.19.10.62.sslip.io/realms/platform/account/` → login ด้วย `poc-admin` ได้

---

## สิ่งที่ต้องรู้ก่อนต่อ service อื่น

| เรื่อง | รายละเอียด |
|---|---|
| Issuer | `https://keycloak.172.19.10.62.sslip.io/realms/platform` — ทุก service ต้องใช้ค่านี้ตรงกัน |
| Service ใน cluster เรียก Keycloak | pod ต้อง resolve `keycloak.172.19.10.62.sslip.io` ได้ (DNS ภายนอก) และ **เชื่อ internal CA** — ตั้งในขั้นของแต่ละ service (เช่น Stackable `AuthenticationClass` แบบ OIDC ใช้ `tls.verification.server.caCert`) |
| Client secret | อ่านจาก OpenBao `secret/keycloak/clients` (property ตามชื่อ client) ผ่าน ExternalSecret ใน namespace ของ service นั้น |
| เพิ่ม client ใหม่ภายหลัง | สร้างใน UI (realm import ไม่ update) แล้วเก็บ secret ใน OpenBao — และเพิ่มลงไฟล์ realm ไว้เป็นเอกสาร / ใช้ตอนติดตั้งใหม่ |

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| `keycloak-0` CrashLoop, log `password authentication failed` | role / password ใน pg-platform ไม่ตรง | ExternalSecret `keycloak-db` และ `pg-role-keycloak` อ่าน `secret/postgres/keycloak` เดียวกัน — ตรวจ `kubectl -n database get cluster pg-platform -o yaml \| grep -A8 managedRolesStatus` |
| `keycloak-0` CrashLoop, log `database "keycloak" does not exist` | Database ยังไม่ถูกสร้าง | `kubectl -n database get database keycloak` — Argo CD retry ให้เอง |
| เปิด UI แล้ว redirect loop / `HTTPS required` / ลิงก์เป็น http | ไม่ได้เชื่อ X-Forwarded-* | ตรวจ `spec.proxy.headers: xforwarded` และ Ingress ผ่าน `websecure` |
| Realm import ค้าง / `Done=False` | placeholder หา secret ไม่เจอ (ExternalSecret ยังไม่ sync) | `kubectl -n keycloak get secret keycloak-client-secrets` และ log ของ Job import: `kubectl -n keycloak logs job/platform` |
| แก้ `realm-platform.yaml` แล้วไม่มีอะไรเปลี่ยน | realm import ทำครั้งเดียว | แก้ใน UI — หรือ (PoC) ลบ realm ใน UI แล้วลบ `KeycloakRealmImport` ให้ Argo CD สร้างใหม่เพื่อ import อีกรอบ |
| Application `keycloak-operator` error เรื่อง namespace | manifest ของ operator ตั้ง namespace `keycloak` ตายตัว | ห้ามเปลี่ยน destination namespace |

ดู log

```bash
kubectl -n keycloak logs deploy/keycloak-operator --tail=50
kubectl -n keycloak logs keycloak-0 --tail=100
```
