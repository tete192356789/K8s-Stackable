# 18 — MLflow 3.17.1 + SSO / สิทธิ์ราย group (GitOps, PoC)

เก็บ experiment, run, metric, model ของงาน ML — login ผ่าน Keycloak และแยกสิทธิ์ตาม group ด้วยปลั๊กอิน **mlflow-oidc-auth**

| รายการ | ค่า |
|---|---|
| MLflow | **3.17.1** + mlflow-oidc-auth **10.0.0** — image `ghcr.io/mlflow-oidc/mlflow-tracking-server:3.17.1-10.0.0-20261014` (ของผู้ดูแลปลั๊กอิน) |
| Chart | `community-charts/mlflow` 1.11.7 (override image) |
| URL | `https://mlflow.172.19.10.62.sslip.io` |
| Login | Keycloak (client `mlflow`) — ทุก group เข้าได้ |
| Database | `mlflow` (tracking) + `mlflow_auth` (ปลั๊กอิน: user / สิทธิ์ / session) บน `pg-platform` |
| Artifact | SeaweedFS bucket `mlflow` — client อัปโหลดผ่าน MLflow (`--serve-artifacts`) ไม่ต้องถือ key ของ S3 |
| Namespace | `mlflow` |
| Resource | request 100m / 1Gi, limit 1 core / 3Gi, 1 worker — 1.5Gi ยัง OOMKilled ตอน login (กำลังวัดค่าจริง) |
| ไฟล์ใน repo | `gitops/apps/66-mlflow.yaml`, `gitops/mlflow/secrets.yaml`, `gitops/mlflow/values/mlflow.yaml`, `gitops/postgres/` (role `mlflow`), `scripts/mlflow-permissions.sh` |

### สิทธิ์

| Group | Login | ดู experiment / model | สร้าง experiment / model | log run / แก้ |
|---|---|---|---|---|
| `platform-admins` | ✅ | ทั้งหมด | ✅ | ✅ ทั้งหมด (admin — ข้ามการตรวจสิทธิ์) |
| `data-engineers` | ✅ | ทั้งหมด | ✅ | ✅ ทั้งหมด |
| `analysts` | ✅ | ทั้งหมด | ❌ | ❌ |
| ไม่มี group | ❌ (login ไม่ได้) | | | |

- คนที่สร้าง experiment / model ได้ **MANAGE** ของชิ้นนั้นอัตโนมัติ (ลบ / ให้สิทธิ์คนอื่นได้)
- ทำด้วย 3 ส่วน: `DEFAULT_MLFLOW_PERMISSION=NO_PERMISSIONS` (ไม่มี grant = มองไม่เห็น) + `RESTRICT_RESOURCE_CREATION=true` (สร้างได้เฉพาะคนที่มี EDIT ผ่าน regex) + grant แบบ group-regex `.*` (ตั้งด้วย `scripts/mlflow-permissions.sh`)
- ปลั๊กอินไม่มีตั้งค่า "group ที่สร้างได้" ตรง ๆ และ grant ตั้งผ่าน config ไม่ได้ (ผ่าน API / UI เท่านั้น — เก็บใน DB `mlflow_auth`)

### ค่าที่ต้องรู้

| เรื่อง | รายละเอียด |
|---|---|
| ไม่ใช้บล็อก `oidcAuth` ของ chart | สุ่ม `SECRET_KEY` ใหม่ทุก sync (ใช้ `lookup` ซึ่งใช้ไม่ได้ใน Argo CD) → ทุกคนหลุด login และค่าเริ่มต้นให้ทุกคน MANAGE — ตั้งผ่าน env เองแทน (`SECRET_KEY` จาก OpenBao `secret/mlflow/app`) |
| `MLFLOW_FLASK_SERVER_SECRET_KEY` | chart ยังสุ่มใหม่ทุกครั้งที่ sync (helm hook) — ไม่กระทบ login (ปลั๊กอินใช้ `SECRET_KEY`) |
| `OIDC_USE_REFRESH_TOKEN=true` | session ของปลั๊กอินหมดตามอายุ access token ของ Keycloak (5 นาที) — ใช้ refresh token แทน |
| `TRUSTED_PROXIES` | pod CIDR ของ Calico (`10.244.0.0/16`) — ให้ปลั๊กอินเชื่อ `X-Forwarded-*` จาก Traefik |
| `serverAllowedHosts` | MLflow 3.x ปฏิเสธ request ที่ hostname ไม่รู้จัก — ใส่ชื่อ Service ภายใน cluster ไว้ให้ Airflow เรียก |
| `/metrics` | ปลั๊กอินไม่ตรวจ auth — ยังไม่เปิด ServiceMonitor |
| ปลั๊กอินออกเวอร์ชันบ่อยมาก | pin image ด้วย tag ที่มีวันที่ — 11.x เปลี่ยนการตรวจสิทธิ์ของ prompt (breaking) |

---

## ขั้นที่ 0: ตรวจ resource (master)

```bash
kubectl describe nodes | grep -E '^Name:|^  cpu  |^  memory  '
```
MLflow ขอ CPU 100m — ต้องมี node ที่ CPU requests < 97% (ตอนนี้น่าจะลง master)

## ขั้นที่ 1: Client `mlflow` ใน Keycloak (UI)

realm **platform** → **Clients → Create client**

| หน้า | ค่า |
|---|---|
| General settings | Client ID **`mlflow`**, Name `MLflow` |
| Capability config | Client authentication **On**, Standard flow เท่านั้น |
| Login settings | Valid redirect URIs: `https://mlflow.172.19.10.62.sslip.io/callback`, Valid post logout redirect URIs: `https://mlflow.172.19.10.62.sslip.io/*`, Web origins: `+` |

หลัง Save:
1. **Client scopes** → `mlflow-dedicated` → **Add mapper → By configuration → Group Membership** → Name `groups`, Token Claim Name `groups`, **Full group path Off**, Add to ID token / access token / userinfo **On**
2. `mlflow-dedicated` → **Add mapper → By configuration → Audience** → Name `audience`, Included Client Audience `mlflow`, Add to access token **On** (ปลั๊กอินตรวจ `aud` = `mlflow`)
3. แท็บ **Client scopes** ของ client → ตรวจว่ามี `offline_access` (Optional)
4. **Credentials** → copy **Client Secret**

## ขั้นที่ 2: Secret ใน OpenBao + bucket (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }
gen() { openssl rand -base64 48 | tr -d '/+=' | cut -c1-"$1"; }

read -rsp 'mlflow client secret (Keycloak): ' S; echo
bao kv patch secret/keycloak/clients mlflow="$S"; unset S

bao kv put secret/postgres/mlflow username=mlflow password="$(gen 32)"     # ตัวอักษร + ตัวเลข (ใช้ใน URI)
bao kv put secret/mlflow/app secret_key="$(gen 48)"

kubectl -n seaweedfs exec seaweedfs-master-0 -- sh -c 'echo "s3.bucket.create -name mlflow" | weed shell -master=localhost:9333'
```

## ขั้นที่ 3: ดึง image ล่วงหน้า

ถ้าทำ Harbor (ขั้นที่ 17) ครบทุก node แล้ว — ไม่ต้อง: node ดึงผ่าน Harbor (proxy cache `ghcr`) เอง
ถ้ายัง:
```bash
echo ghcr.io/mlflow-oidc/mlflow-tracking-server:3.17.1-10.0.0-20261014 > /tmp/mlflow-images.txt
/root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/mlflow-images.txt
```

## ขั้นที่ 4: Push และ sync

```bash
git push                                                               # Mac
```

```bash
cd /root/K8s-Stackable-repo && git pull
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd annotate application postgres argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get applications | grep -E 'NAME|postgres|mlflow'
kubectl -n database get database mlflow mlflow-auth                   # APPLIED true
kubectl -n mlflow get externalsecret,certificate                      # SecretSynced / READY True
kubectl -n mlflow get pods -o wide                                    # mlflow-… 1/1 (init container migrate DB ก่อน)
kubectl -n mlflow logs deploy/mlflow --tail=40
```

## ขั้นที่ 5: Login และตั้งสิทธิ์

1. เปิด `https://mlflow.172.19.10.62.sslip.io` → **Login with Keycloak** → login `platform-admin` (group `platform-admins`)
2. มุมขวาบน → ต้องเห็นเมนู admin
3. **สร้าง access token**: มุมขวาบน → หน้า user (`/user`) → **Tokens** → สร้าง (เช่น `bootstrap`, อายุสั้น) → copy `mlf_...`
4. ตั้งสิทธิ์ราย group (master):
```bash
cd /root/K8s-Stackable-repo
MLFLOW_ADMIN_USER=platform-admin MLFLOW_ADMIN_TOKEN='mlf_...' ./scripts/mlflow-permissions.sh
```
ต้องเห็น `data-engineers ... EDIT` และ `analysts ... READ` ของ `experiment-patterns` และ `registered-models-patterns`

## ขั้นที่ 6: ทดสอบสิทธิ์

| ทดสอบ (Private Window แยกแต่ละ user) | ผลที่ถูกต้อง |
|---|---|
| `poc-engineer` → **Create Experiment** `e2e-test` | ✅ สร้างได้ |
| `poc-engineer` → log run จาก Python (ด้านล่าง) | ✅ |
| `poc-analyst` → เห็น experiment `e2e-test` + run | ✅ |
| `poc-analyst` → **Create Experiment** | ❌ ถูกปฏิเสธ |
| `poc-analyst` → ลบ / rename experiment ของ engineer | ❌ |
| user ที่ไม่มี group | ❌ login ไม่ได้ |

log run จาก Mac ในนามของ `poc-engineer` (ใช้ access token ที่ `poc-engineer` สร้างเองในหน้า `/user`):
```bash
pip install -q "mlflow==3.17.1"
export MLFLOW_TRACKING_URI=https://mlflow.172.19.10.62.sslip.io
export MLFLOW_TRACKING_USERNAME=poc-engineer
read -rs "MLFLOW_TRACKING_PASSWORD?token ของ poc-engineer (mlf_...): "; echo; export MLFLOW_TRACKING_PASSWORD
export REQUESTS_CA_BUNDLE="$HOME/projects/K8s-Stackable/platform-ca.crt"
python - <<'EOF'
import mlflow, random
mlflow.set_experiment("e2e-test")
with mlflow.start_run(run_name="hello"):
    mlflow.log_param("alpha", 0.5)
    for step in range(5):
        mlflow.log_metric("rmse", 1 / (step + 1) + random.random() * 0.05, step=step)
    with open("/tmp/note.txt", "w") as f: f.write("artifact test\n")
    mlflow.log_artifact("/tmp/note.txt")
print("ok")
EOF
```
UI → experiment `e2e-test` → run `hello` → ต้องเห็น metric `rmse` และ artifact `note.txt` (เก็บใน SeaweedFS bucket `mlflow`)

---

## ภายหลัง: Airflow ใช้ MLflow

แนะนำให้ Airflow ใช้ Keycloak client-credentials (client `airflow-mlflow` + Audience `mlflow`) แล้ว admin สร้าง user `service-account-airflow-mlflow` + grant EDIT ใน MLflow — ทำตอนเริ่มมีงาน train model จริง

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| ExternalSecret `mlflow-*` `SecretSyncedError` | ยังไม่มีค่าใน OpenBao | ขั้นที่ 2 |
| init container `mlflow-db-migration` error `password authentication failed` / `database "mlflow" does not exist` | role / database ยังไม่ถูกสร้าง | `kubectl -n database get database mlflow`, Application `postgres` ต้อง Synced |
| pod log `x509` / `CERTIFICATE_VERIFY_FAILED` ตอน login | ไม่เชื่อ cert ของ Keycloak | `kubectl -n mlflow get certificate mlflow-ca-trust` (READY), env `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` |
| เปิดเว็บได้ `Invalid Host header` / 400 | hostname ไม่อยู่ใน `serverAllowedHosts` | เพิ่มใน values แล้ว push |
| Keycloak `Invalid parameter: redirect_uri` | redirect URI ไม่ตรง | `https://mlflow.172.19.10.62.sslip.io/callback` |
| login แล้ว `not in allowed groups` / 403 | ไม่มี claim `groups` ใน ID token หรือ user ไม่อยู่ group ไหน | mapper `groups` (Add to ID token On) |
| analyst สร้าง experiment ได้ | ยังไม่ได้รัน `mlflow-permissions.sh` หรือ `DEFAULT_MLFLOW_PERMISSION` ไม่ใช่ `NO_PERMISSIONS` | ขั้นที่ 5 |
| engineer สร้าง experiment ไม่ได้ | ยังไม่มี grant `.*` = EDIT ของ `data-engineers` | ขั้นที่ 5 |
| หลุด login ทุก ~5 นาที | refresh token ใช้ไม่ได้ | client `mlflow` ต้องมี `offline_access` (Optional) |
| pod restart วน, `Last State: OOMKilled`, probe `connection refused` | RAM เกิน limit (แต่ละ worker โหลด MLflow ทั้งชุด) | ลด `extraArgs.workers` หรือเพิ่ม `resources.limits.memory` |
| `log_artifact` error / upload ค้าง | MLflow เขียน S3 ไม่ได้ | bucket `mlflow` ต้องมี, `kubectl -n mlflow logs deploy/mlflow` |

ดู log
```bash
kubectl -n mlflow logs deploy/mlflow --tail=80
kubectl -n mlflow logs deploy/mlflow -c mlflow-db-migration --tail=30 2>/dev/null
```
