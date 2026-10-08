# (ทดลอง) Stackable Cockpit v2 — Trino SQL editor บนเว็บ

> ⚠️ **experimental** — github.com/stackabletech/cockpit ยังไม่มี release ใช้ build `0.0.0-dev` (จาก branch main) ซึ่งเปลี่ยนได้ทุกวัน
> ทดลองใน PoC เท่านั้น — เครื่องมือ query หลักของทีมยังเป็น **Superset SQL Lab** (ขั้นที่ 13)

| รายการ | ค่า |
|---|---|
| Image | `oci.stackable.tech/sdp/cockpit:0.0.0-dev@sha256:2e247ed3…` (build จาก main วันที่ 2026-10-06, commit `ae08039`) — pin ด้วย digest กันเปลี่ยนเอง |
| ความสามารถ | Trino SQL editor + autocomplete, schema browser, ดูผลลัพธ์ (storage browser ยังปิด) |
| Login | Keycloak realm `platform` — client **`cockpit`** (สร้างเพิ่มใน UI เพราะ realm import ทำครั้งเดียว) |
| Query รันในนามของ | **user ที่ login** (`X-Trino-User` = `preferred_username`) — Trino ยังไม่มี authentication จึงเชื่อ header นี้ |
| URL | `https://cockpit.172.19.10.62.sslip.io` |
| Namespace | `data-platform` |
| RAM | request 128 Mi / limit 512 Mi |
| ไฟล์ | `gitops/apps/60-cockpit.yaml`, `gitops/cockpit/cockpit.yaml` |

**ทำไมไม่ใช้ Helm chart ของ repo** — chart ยังไม่มีช่องเพิ่ม env / volume ทำให้ตั้ง `NODE_EXTRA_CA_CERTS` (ให้ Node.js เชื่อ internal CA ตอนคุยกับ Keycloak) ไม่ได้
จึงเขียน manifest เองตาม template ของ chart (`deploy/helm/cockpit/templates/`) — **เวลาอัปเดต image ให้เทียบกับ chart ใน repo ด้วยว่ามี env ใหม่หรือไม่**

```
ผู้ใช้ ──HTTPS──▶ Traefik ──▶ cockpit:3000
                                 ├─ OIDC (เชื่อ platform CA ผ่าน NODE_EXTRA_CA_CERTS) ──▶ Keycloak
                                 └─ HTTPS :8443 + X-Trino-User (เชื่อ CA ของ secret-operator ผ่าน SecretClass tls) ──▶ trino-coordinator
```

---

## ขั้นที่ 1: สร้าง client `cockpit` ใน Keycloak (UI)

Login `https://keycloak.172.19.10.62.sslip.io/admin/` (admin realm master) → สลับ realm เป็น **platform** → **Clients → Create client**

| หน้า | ค่า |
|---|---|
| General settings | Client type `OpenID Connect`, Client ID `cockpit`, Name `Stackable Cockpit` |
| Capability config | **Client authentication: On**, Authentication flow: **Standard flow** อย่างเดียว |
| Login settings | Valid redirect URIs: `https://cockpit.172.19.10.62.sslip.io/*`, Web origins: `+` |

หลัง Save:
1. แท็บ **Client scopes** → `cockpit-dedicated` → **Add mapper → By configuration → Group Membership** → Name `groups`, Token Claim Name `groups`, **Full group path: Off** → Save (ให้ส่ง group เหมือน client อื่น)
2. แท็บ **Credentials** → copy **Client Secret**

## ขั้นที่ 2: เก็บ secret ใน OpenBao (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }

read -rsp 'cockpit client secret (จาก Keycloak): ' S; echo
bao kv patch secret/keycloak/clients cockpit="$S"; unset S          # patch = เพิ่ม key โดยไม่ลบ key อื่น
bao kv put secret/cockpit/session session-secret="$(openssl rand -hex 32)"

bao kv get -format=json secret/keycloak/clients | jq -r '.data.data | keys[]'   # ต้องมี cockpit
```

## ขั้นที่ 3: ดึง image ล่วงหน้า (master)

```bash
echo "oci.stackable.tech/sdp/cockpit@sha256:2e247ed3d98f2cb1acee98b65c75f7d86c0881e81f995cc04c4fd2d759532db9" > /tmp/cockpit-images.txt
/root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/cockpit-images.txt 2>&1 | tee /tmp/cockpit-prepull.log
```

## ขั้นที่ 4: Push และ sync

```bash
git push                                                               # Mac
```

```bash
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite     # master
kubectl -n argocd get application cockpit -w                           # Synced / Healthy
kubectl -n data-platform get pods -l app.kubernetes.io/name=cockpit    # 1/1 Running
kubectl -n data-platform logs deploy/cockpit --tail=50
```

## ขั้นที่ 5: ทดสอบ

1. เปิด `https://cockpit.172.19.10.62.sslip.io` → redirect ไป Keycloak → login `poc-engineer`
2. Schema browser ต้องเห็น catalog `iceberg` → schema `demo` → table `nation`
3. รัน `SELECT name FROM iceberg.demo.nation ORDER BY nationkey LIMIT 5`
4. ตรวจว่า query รันในนามของ user ที่ login — ใน Trino Web UI (tunnel 18443, `https://localhost:18443/ui/`) คอลัมน์ **User** ต้องเป็น `poc-engineer` (build ปัจจุบันยังเป็น `anonymous` — ดู bug ในหัวข้อข้อจำกัด)

---

## ข้อจำกัด / สิ่งที่ต้องรู้

| เรื่อง | รายละเอียด |
|---|---|
| ⚠️ **Bug: ทุก query ไปถึง Trino เป็น user `anonymous`** (ยืนยันแล้ว 2026-10-08) | log ขึ้น `Resolved Trino user from OIDC claim` (Keycloak ส่ง `preferred_username` มาถูก) แต่ Cockpit ไม่เก็บค่าไว้ใน `username` → ใช้ค่า fallback `anonymous` — น่าจะมาจาก PR #330 (5 ต.ค.) ที่ตั้ง `input: false` ให้ field `username` ซึ่ง better-auth กรองค่าจาก `mapProfileToUser` ทิ้งไปด้วย — แก้ได้โดยรอ build ใหม่จาก upstream หรือถอยไปใช้ build ก่อน #330 (จะมีช่องโหว่ให้ผู้ใช้ตั้ง username ของตัวเองได้) |
| ความปลอดภัย | ตอนนี้ Trino ไม่มี authentication — Cockpit ส่ง `X-Trino-User` ให้ แต่ใครที่ต่อ Trino ตรง ๆ ได้ก็ตั้งชื่อ user เองได้ — สิทธิ์จริงต้องรอขั้น Trino SSO + OPA |
| หลังเปิด authentication ใน Trino | Cockpit รองรับ Trino auth แค่ `none` / `basic` + impersonation — ต้องให้ Cockpit login เป็น service user (basic) แล้ว OPA อนุญาตให้ impersonate ผู้ใช้ — ตั้งตอนทำ Trino SSO |
| อัปเดต | build ใหม่ออกบ่อย: ดู digest ล่าสุดของ `0.0.0-dev`, เทียบ env ใน chart ของ repo, แก้ `image:` ใน `gitops/cockpit/cockpit.yaml` แล้ว push |
| Trino TLS | ตรวจ cert ของ Trino ด้วย `ca.crt` จาก SecretClass `tls` — ถ้าชื่อใน cert ไม่ตรงกับ `trino-coordinator.data-platform.svc.cluster.local` ดูหัวข้อปัญหาด้านล่าง |

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| pod CrashLoop, log เรื่อง discovery / `unable to get local issuer certificate` | Node.js ไม่เชื่อ internal CA | ตรวจ `kubectl -n data-platform get certificate cockpit-ca-trust` (READY) และ `kubectl -n data-platform exec deploy/cockpit -- head -1 /etc/platform-ca/ca.crt` |
| ExternalSecret `cockpit` error `key not found: cockpit` | ยังไม่ได้เพิ่ม client secret ใน OpenBao | ขั้นที่ 2 |
| Keycloak `Invalid parameter: redirect_uri` | redirect URI ของ client ไม่ตรง | ขั้นที่ 1: `https://cockpit.172.19.10.62.sslip.io/*` |
| Login แล้ว `invalid_client` / `unauthorized_client` | client secret ใน OpenBao ไม่ตรงกับ Keycloak | copy จากแท็บ Credentials ใหม่ แล้ว `bao kv patch` + `kubectl -n data-platform rollout restart deploy/cockpit` |
| Query error เรื่อง TLS / `Hostname ... does not match` กับ Trino | cert ของ Trino ไม่มีชื่อ service นี้ | ชั่วคราว: เพิ่ม env `STACKABLE_COCKPIT_TRINO_TLS_INSECURE=true` (PoC เท่านั้น) แล้วแจ้งผล |
| CSRF / `Cross-site POST form submissions are forbidden` | `ORIGIN` ไม่ตรงกับ URL ที่เปิด | ต้องเปิดผ่าน `https://cockpit.172.19.10.62.sslip.io` เท่านั้น |

## ถอดออก

ลบ `gitops/apps/60-cockpit.yaml` แล้ว push — Argo CD ลบ resource ทั้งหมดให้ (`prune: true`)
ใน Keycloak ลบ client `cockpit` และ `bao kv metadata delete secret/cockpit/session`
