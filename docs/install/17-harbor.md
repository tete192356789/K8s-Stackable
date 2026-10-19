# 17 — Harbor 2.15.4: image registry + proxy cache (GitOps, PoC)

ที่เก็บ image ของเราเอง (เช่น MLflow + ปลั๊กอิน, Airflow ที่เพิ่ม library) และ **proxy cache** ของ registry สาธารณะ —
node ดึง image ผ่าน Harbor ครั้งเดียว ครั้งต่อไปได้จาก cache (แทน `prepull-images.sh` ในระยะยาว)

| รายการ | ค่า |
|---|---|
| Harbor | **2.15.4** (chart `harbor` 1.19.4 จาก `https://helm.goharbor.io`) |
| URL | `https://harbor.172.19.10.62.sslip.io` (UI + registry ใช้ host เดียวกัน) |
| Login | Keycloak (OIDC, client `harbor`) — `platform-admins` = Harbor admin; `admin` ภายในใช้ได้เฉพาะ API / กรณีฉุกเฉิน |
| Database | `harbor` บน `pg-platform` |
| Image storage | SeaweedFS bucket `harbor` (HTTP ภายใน cluster) |
| Redis | Valkey ภายใน (PVC 1Gi) |
| ปิดไว้ | Trivy (สแกนช่องโหว่), metrics exporter — ประหยัด CPU / RAM |
| Proxy cache | `dockerhub` ← docker.io, `quay` ← quay.io, `ghcr` ← ghcr.io, `k8s` ← registry.k8s.io, `stackable` ← oci.stackable.tech |
| Resource (request) | CPU ~160m, RAM ~670Mi รวมทุก component |
| ไฟล์ใน repo | `gitops/apps/65-harbor.yaml`, `gitops/harbor/secrets.yaml`, `gitops/harbor/values/harbor.yaml`, `gitops/postgres/` (role `harbor`), `scripts/harbor-proxy-cache.sh`, `scripts/containerd-harbor-mirror.sh` |

```
docker push / pull (คน, CI) ──HTTPS──▶ Traefik ──▶ harbor-core / harbor-registry ──▶ SeaweedFS (bucket harbor)
                                                     │ metadata ──▶ pg-platform (db harbor)
                                                     └ OIDC ──▶ Keycloak
kubelet → containerd (ทุก node)
   docker.io/library/nginx ──hosts.toml──▶ https://harbor…/v2/dockerhub/library/nginx ──(ไม่มีใน cache)──▶ docker.io
                           └─ Harbor ล่ม → ดึงจาก docker.io ตรง (fallback)
```

### ค่าที่ต้องรู้

| เรื่อง | รายละเอียด |
|---|---|
| Secret ภายในของ Harbor | chart สุ่มค่าเองทุกครั้งที่ render ถ้าไม่ให้ — Argo CD render ใหม่ทุก sync → Harbor พัง จึงให้ค่าทั้งหมดจาก OpenBao (`secret/harbor/*`) + cert-manager (token cert) — **`secret_key` ห้ามเปลี่ยนหลังใช้งาน** (ใช้เข้ารหัส credential ใน DB) |
| OIDC แบบ declarative | ตั้งผ่าน `CONFIG_OVERWRITE_JSON` (secret `harbor-oidc`) → **config ทั้งหมดใน UI เป็น read-only** — แก้ที่ `gitops/harbor/secrets.yaml` แล้ว restart core |
| `disableredirect: true` | ไม่อย่างนั้น registry ส่ง client ไปดึงไฟล์จาก URL ของ S3 ภายใน cluster ที่ node resolve ไม่ได้ |
| TLS | จบที่ Traefik (wildcard cert) — chart ไม่ทำ TLS เอง (`expose.tls.enabled: false`) |
| quay.io | chart ไม่อนุญาต endpoint type `quay` สำหรับ proxy cache → ใช้ `docker-registry` แทน |
| Proxy cache project | **push ไม่ได้** (ดึงอย่างเดียว) · public = ดึงได้โดยไม่ login · ลบ image ที่ไม่ถูกดึงเกิน 7 วันเอง |
| containerd 2.1.5 | ไม่ได้ตั้ง `config_path` เป็นค่าเริ่มต้น → ต้องตั้งเองบนทุก node (ขั้นที่ 7) |

---

## ขั้นที่ 0: ตรวจ resource (master)

```bash
kubectl describe nodes | grep -E '^Name:|^  cpu  |^  memory  '
```

Harbor ขอ CPU ~160m รวม — master ยังว่าง ~0.9 core (worker1 / worker2 CPU requests > 90%) → pod ส่วนใหญ่น่าจะไปลง master

## ขั้นที่ 1: Client `harbor` ใน Keycloak (UI)

`https://keycloak.172.19.10.62.sslip.io/admin/` (`kcadmin`) → realm **platform** → **Clients → Create client**

| หน้า | ค่า |
|---|---|
| General settings | Client ID **`harbor`**, Name `Harbor` |
| Capability config | Client authentication **On**, Standard flow เท่านั้น |
| Login settings | Valid redirect URIs: `https://harbor.172.19.10.62.sslip.io/c/oidc/callback`, Web origins: `+` |

หลัง Save:
1. **Client scopes** → `harbor-dedicated` → **Add mapper → By configuration → Group Membership** → Name `groups`, Token Claim Name `groups`, **Full group path Off**, Add to ID token / access token / userinfo **On**
2. **Client scopes** (แท็บของ client) → ตรวจว่ามี `offline_access` (Optional) — Harbor ใช้ refresh token สำหรับ CLI secret
3. **Credentials** → copy **Client Secret**

## ขั้นที่ 2: Secret ใน OpenBao + bucket (master)

```bash
type bao >/dev/null 2>&1 || bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token /root/K8S-Stackable/openbao/init-keys.json)" bao "$@"; }
gen() { openssl rand -base64 48 | tr -d '/+=' | cut -c1-"$1"; }      # ตัวอักษร + ตัวเลข ยาวตามที่ระบุ

read -rsp 'harbor client secret (Keycloak): ' S; echo
bao kv patch secret/keycloak/clients harbor="$S"; unset S

bao kv put secret/postgres/harbor username=harbor password="$(gen 32)"

bao kv put secret/harbor/core \
  admin_password="$(gen 24)" \
  secret_key="$(gen 16)" core_secret="$(gen 16)" csrf_key="$(gen 32)" \
  jobservice_secret="$(gen 16)" registry_http_secret="$(gen 16)"

# registry credential: password + htpasswd แบบ bcrypt (ต้องใช้ htpasswd จาก httpd-tools)
dnf install -y httpd-tools >/dev/null
RP="$(gen 24)"
bao kv put secret/harbor/registry password="$RP" htpasswd="$(htpasswd -nbB harbor_registry_user "$RP")"; unset RP

bao kv get -format=json secret/harbor/core | jq -r '.data.data | keys[]'      # 6 key
```

สร้าง bucket `harbor`

```bash
kubectl -n seaweedfs exec seaweedfs-master-0 -- sh -c 'echo "s3.bucket.create -name harbor" | weed shell -master=localhost:9333'
kubectl -n seaweedfs exec seaweedfs-master-0 -- sh -c 'echo "s3.bucket.list" | weed shell -master=localhost:9333' | grep harbor
```

## ขั้นที่ 3: ดึง image ล่วงหน้า (master)

```bash
cat > /tmp/harbor-images.txt <<'EOF'
docker.io/goharbor/harbor-core:v2.15.4
docker.io/goharbor/harbor-portal:v2.15.4
docker.io/goharbor/harbor-jobservice:v2.15.4
docker.io/goharbor/registry-photon:v2.15.4
docker.io/goharbor/harbor-registryctl:v2.15.4
docker.io/goharbor/valkey-photon:v2.15.4
EOF
nohup /root/K8s-Stackable-repo/scripts/prepull-images.sh /tmp/harbor-images.txt > /tmp/harbor-prepull.log 2>&1 &
tail -f /tmp/harbor-prepull.log
```

## ขั้นที่ 4: Push และ sync

```bash
git push                                                               # Mac
```

```bash
cd /root/K8s-Stackable-repo && git pull
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get applications | grep -E 'NAME|postgres|harbor'          # Synced / Healthy
kubectl -n database get database harbor                                       # APPLIED true
kubectl -n harbor get externalsecret,certificate                              # SecretSynced / READY True
kubectl -n harbor get pods                                                    # harbor-core, harbor-jobservice, harbor-portal, harbor-registry (2/2), harbor-redis-0 → Running
kubectl -n harbor logs deploy/harbor-core --tail=30
```

## ขั้นที่ 5: Login (browser บน Mac)

1. `https://harbor.172.19.10.62.sslip.io` → **LOGIN VIA OIDC PROVIDER** → Keycloak → login `admin` (`platform-admins`)
2. ครั้งแรก Harbor ถาม username → ยืนยัน
3. มุมขวาบน → ต้องเห็นเมนู **Administration** (เป็น admin จาก group)
4. User Profile → copy **CLI secret** (ใช้ `docker login` แทน password)

## ขั้นที่ 6: สร้าง proxy cache (master)

```bash
cd /root/K8s-Stackable-repo
HARBOR_ADMIN_PASSWORD="$(bao kv get -field=admin_password secret/harbor/core)" ./scripts/harbor-proxy-cache.sh
```

ตรวจ: UI → **Projects** ต้องเห็น `dockerhub`, `quay`, `ghcr`, `k8s`, `stackable` (Type: Proxy Cache, Public)

ทดสอบดึงผ่าน Harbor ตรง ๆ (Mac — Docker Desktop เชื่อ CA จาก Keychain)
```bash
docker pull harbor.172.19.10.62.sslip.io/dockerhub/library/busybox:1.36
```
UI → Projects → `dockerhub` → ต้องเห็น `library/busybox` ถูก cache

## ขั้นที่ 7: ให้ containerd ดึงผ่าน Harbor (ทุก node — ทำทีละเครื่อง)

ทำ **worker2 ก่อน** ทดสอบผ่านแล้วค่อยทำ worker1 และ master

```bash
# บน master: copy script + CA ไป node
for n in 172.19.10.64; do      # worker2 ก่อน
  scp /root/K8s-Stackable-repo/scripts/containerd-harbor-mirror.sh /root/K8S-Stackable/platform-ca.crt root@$n:/root/
done
```

```bash
# บน node นั้น
head -3 /etc/containerd/config.toml                 # ต้องมี version = 3
/root/containerd-harbor-mirror.sh /root/platform-ca.crt
crictl pull docker.io/library/busybox:1.36          # ดึงผ่าน Harbor
crictl pull quay.io/prometheus/busybox:latest
```

ยืนยันว่าผ่าน Harbor จริง: UI → Projects → `dockerhub` / `quay` → Repositories ต้องเห็น image ที่เพิ่งดึง
ผ่านแล้วทำ worker1 (`172.19.10.63`) และ master (`172.19.10.62`) ต่อ

> ถอนได้ทุกเมื่อ: `/root/containerd-harbor-mirror.sh --remove` (containerd กลับไปดึงจาก upstream ตรง)
> Harbor ล่ม → containerd ดึงจาก upstream เอง (`server = ...` ใน hosts.toml) — cluster ไม่ติด

## ขั้นที่ 8: Push image ของเราเอง (Mac)

1. UI → **Projects → New Project** → `platform` (Private)
2. ดึง CLI secret ของตัวเอง (ขั้นที่ 5) แล้ว:
```bash
docker login harbor.172.19.10.62.sslip.io -u admin          # password = CLI secret
docker pull --platform linux/amd64 busybox:1.36
docker tag busybox:1.36 harbor.172.19.10.62.sslip.io/platform/busybox:test
docker push harbor.172.19.10.62.sslip.io/platform/busybox:test
```
3. ใน cluster (private project) ต้องใช้ **robot account**: Project `platform` → Robot Accounts → New (Pull) → สร้าง `imagePullSecret` จาก robot นั้น

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| ExternalSecret `harbor-*` `SecretSyncedError` | ยังไม่มีค่าใน OpenBao | ขั้นที่ 2 |
| `harbor-core` CrashLoop, log `failed to ... auth_mode` | เปลี่ยน auth mode ไม่ได้เพราะมี user ภายในอื่นนอกจาก admin แล้ว | ลบ user ภายในใน UI ก่อน (ต้องเอา `CONFIG_OVERWRITE_JSON` ออกชั่วคราว) |
| `harbor-core` log `x509` ตอน OIDC | ไม่เชื่อ cert ของ Keycloak | `kubectl -n harbor get certificate harbor-ca-trust` (READY) |
| Keycloak `Invalid parameter: redirect_uri` | redirect URI ไม่ตรง | `https://harbor.172.19.10.62.sslip.io/c/oidc/callback` |
| login แล้วไม่เห็น Administration | ไม่มี claim `groups` / ไม่อยู่ `platform-admins` | mapper `groups` ของ client `harbor` (ขั้นที่ 1) |
| `docker push` error `unauthorized` | ใช้ password ของ Keycloak แทน CLI secret | ใช้ CLI secret จาก User Profile |
| `docker push` ค้าง / `blob upload unknown` | registry เขียน S3 ไม่ได้ | `kubectl -n harbor logs deploy/harbor-registry -c registry --tail=30`; bucket `harbor` ต้องมี |
| script ขึ้น `พบ section registry มากกว่า 1 อัน` / `table registry already exists` | script เวอร์ชันแรกต่อ section ซ้ำ (containerd 2 ใช้ `'` ในชื่อ section) | `sed -i '/^\[plugins\."io\.containerd\.cri\.v1\.images"\.registry\]$/,+1d' /etc/containerd/config.toml` แล้ว `containerd config dump >/dev/null` ต้องไม่ error — **ห้าม restart containerd ก่อนแก้** |
| หลัง restart containerd: `crictl` error `unknown service runtime.v1.ImageService`, log `too many open files` | inotify ของ node เต็ม (ค่าเริ่มต้น 128) → CRI plugin โหลดไม่ขึ้น — **node ใช้งานไม่ได้** | ตั้ง `fs.inotify.max_user_instances = 8192`, `max_user_watches = 524288` ใน `/etc/sysctl.d/99-inotify.conf` → `sysctl --system` → `systemctl restart containerd` (script เวอร์ชันล่าสุดทำให้แล้ว) |
| `crictl pull` ขึ้น `Image is up to date` | ข้อความปกติเมื่อดึงสำเร็จ — ไม่ได้บอกว่าดึงจากไหน | ดูใน Harbor UI ว่า image โผล่ใน project proxy cache หรือไม่ |
| `crictl pull` ไม่ผ่าน Harbor (ไม่โผล่ใน project) | containerd ไม่อ่าน `config_path` | `containerd config dump \| grep -A2 'cri.v1.images".registry'` ต้องเห็น `config_path = "/etc/containerd/certs.d"` |
| `crictl pull` error `x509` | containerd ไม่เชื่อ CA | `/etc/containerd/certs.d/platform-ca.crt` ต้องมี และ `ca = ...` ใน hosts.toml |
| harbor-core / registry OOMKilled | memory limit ต่ำเกิน | เพิ่ม `resources.limits.memory` ใน `gitops/harbor/values/harbor.yaml` |

ดู log

```bash
kubectl -n harbor logs deploy/harbor-core --tail=50
kubectl -n harbor logs deploy/harbor-registry -c registry --tail=50
kubectl -n harbor logs deploy/harbor-jobservice --tail=30
```
