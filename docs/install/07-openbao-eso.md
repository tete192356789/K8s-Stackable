# 07 — ติดตั้ง OpenBao 2.7.0 + External Secrets Operator 2.11.0 (PoC)

เก็บ secret ทั้งหมดของ platform ไว้ที่เดียว (OpenBao) แล้วให้ External Secrets Operator (ESO) สร้าง Kubernetes Secret ให้ service ที่ต้องใช้
ใน Git เก็บแค่ `ExternalSecret` ที่บอกว่า "ดึง secret ตัวไหน" — ไม่มีค่าจริงของ password / key อยู่ใน Git

| รายการ | ค่า |
|---|---|
| OpenBao | 2.7.0 (Helm chart `openbao/openbao` 0.30.0), Raft 1 replica, PVC 2 GB บน Longhorn |
| External Secrets | 2.11.0 (Helm chart `external-secrets/external-secrets` 2.11.0) |
| Unseal | Shamir 3 ชิ้น ใช้ 2 ชิ้นเปิด (ต้อง unseal เองทุกครั้งที่ pod OpenBao restart) |
| KV engine | `secret/` (KV v2) |
| การยืนยันตัวตนของ ESO | Kubernetes auth, role `external-secrets` อ่านได้อย่างเดียว |
| UI | `https://bao.172.19.10.62.sslip.io` |
| ไฟล์ใน repo | `platform/openbao/values.yaml`, `platform/openbao/ingress.yaml`, `platform/external-secrets/values.yaml`, `platform/external-secrets/cluster-secret-store.yaml` |
| ไฟล์บน master | `/root/K8S-Stackable/openbao/`, `/root/K8S-Stackable/external-secrets/` |
| ต้องติดตั้งก่อน | [01-longhorn.md](01-longhorn.md), [03-traefik.md](03-traefik.md), [06-seaweedfs.md](06-seaweedfs.md) (ใช้ย้าย S3 key เข้า OpenBao ในขั้นที่ 8) |

```
OpenBao (secret/)  ◀──Kubernetes auth (ServiceAccount external-secrets)──  ESO
                                                                           │ อ่านตาม ExternalSecret
                                                                           ▼
                                                              Kubernetes Secret ใน namespace ของ service
```

---

## ค่าที่ตั้ง

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `server.ha.raft.enabled`, `replicas: 1` | Raft 1 ตัว | ใช้ `bao operator raft snapshot` backup ได้ และขยายเป็น 3 replica ภายหลังได้โดยไม่ต้องย้ายข้อมูล |
| `server.dataStorage` | 2 GB บน `longhorn` | ข้อมูล secret มีขนาดเล็ก |
| `injector.enabled` | `false` | ใช้ ESO แทน agent injector ประหยัด RAM |
| `ui.enabled` | `true` | เปิดหน้าเว็บของ OpenBao |
| TLS ของ listener | ปิด (ค่าเริ่มต้นของ chart) | traffic ใน cluster เป็น HTTP ภายนอกใช้ HTTPS ผ่าน Traefik |
| Unseal | 3 ชิ้น / ใช้ 2 | ฝึกขั้นตอนแบบ production (production แนะนำ 5 / 3 หรือ auto-unseal ด้วย HSM) |

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master (รันบนเครื่อง local ที่ root ของ repo)

```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/openbao /root/K8S-Stackable/external-secrets'
scp platform/openbao/values.yaml platform/openbao/ingress.yaml root@172.19.10.62:/root/K8S-Stackable/openbao/
scp platform/external-secrets/values.yaml platform/external-secrets/cluster-secret-store.yaml root@172.19.10.62:/root/K8S-Stackable/external-secrets/
```

---

## ขั้นที่ 2: ดึง image ล่วงหน้า (รันบน master)

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo add external-secrets https://charts.external-secrets.io
helm repo update openbao external-secrets

cd /root/K8S-Stackable/openbao
helm template openbao openbao/openbao -n openbao --version 0.30.0 -f values.yaml > rendered.yaml
grep -E '^kind: (StatefulSet|Deployment)' rendered.yaml       # ต้องมีแค่ StatefulSet (ไม่มี Deployment ของ injector)
grep -oE 'image: *"?[^" ]+' rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt                                                # quay.io/openbao/openbao:2.7.0
../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log

cd /root/K8S-Stackable/external-secrets
helm template external-secrets external-secrets/external-secrets -n external-secrets --version 2.11.0 -f values.yaml > rendered.yaml
grep -oE 'image: *"?[^" ]+' rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt                                                # ghcr.io/external-secrets/external-secrets:v2.11.0
../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log
```

---

## ขั้นที่ 3: ติดตั้ง OpenBao (รันบน master)

```bash
cd /root/K8S-Stackable/openbao
helm install openbao openbao/openbao -n openbao --create-namespace --version 0.30.0 -f values.yaml
kubectl -n openbao get pods -w          # รอจน openbao-0 เป็น Running แล้ว Ctrl+C
```

> `openbao-0` จะเป็น `Running` แต่ `READY 0/1` — **ปกติ** เพราะยังไม่ได้ init และยังถูก seal อยู่ (readiness probe ผ่านเมื่อ unseal แล้วเท่านั้น) อย่าใช้ `kubectl wait --for=condition=Ready` ในขั้นนี้

```bash
kubectl -n openbao exec openbao-0 -- bao status     # Initialized: false, Sealed: true
```

---

## ขั้นที่ 4: Init และ Unseal (รันบน master)

**4.1 Init** — ทำครั้งเดียวตลอดอายุของ OpenBao

```bash
cd /root/K8S-Stackable/openbao
umask 077
kubectl -n openbao exec openbao-0 -- bao operator init -key-shares=3 -key-threshold=2 -format=json > init-keys.json
jq '{unseal_keys: (.unseal_keys_b64 | length), threshold: .unseal_threshold, has_root_token: (.root_token != null)}' init-keys.json
```

> ⚠️ **`init-keys.json` มี unseal key 3 ชิ้นและ root token** — ถ้าหาย **กู้ข้อมูลใน OpenBao ไม่ได้อีก**
> - copy ไปเก็บที่ปลอดภัยนอก cluster ทันที (password manager ขององค์กร / ตู้เซฟ) และแยกเก็บ key แต่ละชิ้นไว้กับคนละคนถ้าเป็นไปได้
> - PoC เก็บไฟล์ไว้บน master ได้ (สิทธิ์ `600` จาก `umask 077`) แต่ **ห้าม commit เข้า Git**
> - production: ลบไฟล์ออกจาก server หลังเก็บเรียบร้อย และ revoke root token หลังตั้งค่าเสร็จ

**4.2 Unseal** (ใช้ 2 ใน 3 ชิ้น)

```bash
for i in 0 1; do
  kubectl -n openbao exec openbao-0 -- bao operator unseal "$(jq -r ".unseal_keys_b64[$i]" init-keys.json)" >/dev/null
done
kubectl -n openbao exec openbao-0 -- bao status | grep -E 'Initialized|Sealed|HA Mode'
kubectl -n openbao get pods                     # openbao-0 ต้องเป็น READY 1/1
```

ผลที่ถูกต้อง: `Initialized true`, `Sealed false`, `HA Mode active`

---

## ขั้นที่ 5: ตั้งค่า OpenBao (รันบน master)

ใช้ root token ตั้งค่าครั้งแรก — เปิด KV v2, เปิด Kubernetes auth, สร้าง policy และ role ให้ ESO

```bash
cd /root/K8S-Stackable/openbao
bao() { kubectl -n openbao exec -i openbao-0 -- env BAO_TOKEN="$(jq -r .root_token init-keys.json)" bao "$@"; }

bao secrets enable -path=secret kv-v2
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

bao policy write external-secrets - <<'EOF'
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
EOF

bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h

bao secrets list
bao auth list
```

> ฟังก์ชัน `bao()` ใช้ได้เฉพาะใน shell ปัจจุบัน ถ้าเปิด terminal ใหม่ต้องประกาศใหม่ (ต้องอยู่ใน directory ที่มี `init-keys.json`)

---

## ขั้นที่ 6: ติดตั้ง External Secrets Operator (รันบน master)

```bash
cd /root/K8S-Stackable/external-secrets
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --version 2.11.0 -f values.yaml
kubectl -n external-secrets wait pod --all --for=condition=Ready --timeout=300s
kubectl -n external-secrets get pods,sa
```

ต้องมี pod 3 ตัว (`external-secrets`, `-webhook`, `-cert-controller`) และ ServiceAccount ชื่อ `external-secrets` (ชื่อที่ผูกไว้กับ role ในขั้นที่ 5)

สร้าง ClusterSecretStore

```bash
kubectl apply -f cluster-secret-store.yaml
kubectl get clustersecretstore openbao        # STATUS ต้องเป็น Valid, READY True
```

---

## ขั้นที่ 7: ทดสอบ (รันบน master)

```bash
cd /root/K8S-Stackable/openbao
bao kv put secret/poc/test hello=world

cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-test
  namespace: default
spec:
  refreshInterval: 1m
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: eso-test }
  data:
    - secretKey: hello
      remoteRef: { key: poc/test, property: hello }
EOF

kubectl wait externalsecret/eso-test --for=condition=Ready --timeout=60s
kubectl get secret eso-test -o jsonpath='{.data.hello}' | base64 -d; echo      # ต้องได้: world
```

ทดสอบว่าแก้ค่าใน OpenBao แล้ว Secret เปลี่ยนตาม (รอไม่เกิน `refreshInterval` = 1 นาที)

```bash
bao kv put secret/poc/test hello=updated
sleep 70; kubectl get secret eso-test -o jsonpath='{.data.hello}' | base64 -d; echo   # ต้องได้: updated
```

ลบของทดสอบ

```bash
kubectl delete externalsecret eso-test          # Secret eso-test ถูกลบตามไปด้วย
bao kv metadata delete secret/poc/test
```

---

## ขั้นที่ 8: ย้าย S3 key ของ SeaweedFS เข้า OpenBao (รันบน master)

Hive / Trino / Loki / Airflow จะดึง S3 key จาก OpenBao ผ่าน ESO แทนการ copy secret เอง

```bash
cd /root/K8S-Stackable/openbao
s3key() { kubectl -n seaweedfs get secret seaweedfs-s3-secret -o jsonpath="{.data.$1}" | base64 -d; }

bao kv put secret/seaweedfs/s3-admin \
  access_key="$(s3key admin_access_key_id)" secret_key="$(s3key admin_secret_access_key)"
bao kv put secret/seaweedfs/s3-read \
  access_key="$(s3key read_access_key_id)" secret_key="$(s3key read_secret_access_key)"

bao kv list secret/seaweedfs
```

ตัวอย่าง ExternalSecret ที่ service อื่นจะใช้ภายหลัง

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: s3-credentials
  namespace: <namespace ของ service>
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: s3-credentials }
  data:
    - secretKey: accessKey
      remoteRef: { key: seaweedfs/s3-admin, property: access_key }
    - secretKey: secretKey
      remoteRef: { key: seaweedfs/s3-admin, property: secret_key }
```

---

## ขั้นที่ 9: เปิด UI ผ่าน Traefik (รันบน master)

```bash
kubectl apply -f /root/K8S-Stackable/openbao/ingress.yaml
curl -s --cacert /root/K8S-Stackable/platform-ca.crt https://bao.172.19.10.62.sslip.io/v1/sys/health | jq '{initialized, sealed, version}'
```

เปิด `https://bao.172.19.10.62.sslip.io` → Method **Token** → ใส่ root token (`jq -r .root_token init-keys.json`)
หลังติดตั้ง Keycloak จะเปิด OIDC login แทนการใช้ root token

---

## หลัง OpenBao restart (reboot node, pod ถูกย้าย, helm upgrade) — ต้อง Unseal ใหม่

OpenBao เก็บ master key ไว้ใน memory เท่านั้น ทุกครั้งที่ pod เริ่มใหม่จะกลับไปเป็น `Sealed` และ `READY 0/1`

```bash
cd /root/K8S-Stackable/openbao
kubectl -n openbao exec openbao-0 -- bao status | grep Sealed          # Sealed true = ต้อง unseal
for i in 0 1; do
  kubectl -n openbao exec openbao-0 -- bao operator unseal "$(jq -r ".unseal_keys_b64[$i]" init-keys.json)" >/dev/null
done
kubectl -n openbao exec openbao-0 -- bao status | grep Sealed          # Sealed false
```

> ระหว่างที่ OpenBao ถูก seal **Secret ที่ ESO สร้างไว้แล้วยังใช้งานได้ปกติ** — service ที่รันอยู่ไม่กระทบ แค่สร้าง / แก้ secret ใหม่ไม่ได้จนกว่าจะ unseal

---

## Backup

```bash
cd /root/K8S-Stackable/openbao
bao operator raft snapshot save /tmp/openbao.snap                       # snapshot อยู่ใน pod
kubectl -n openbao cp openbao-0:/tmp/openbao.snap ./openbao-$(date +%F).snap
kubectl -n openbao exec openbao-0 -- rm -f /tmp/openbao.snap
```

> snapshot ใช้ได้เฉพาะคู่กับ unseal key ชุดเดิม — เก็บ snapshot และ `init-keys.json` แยกที่กัน

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| `openbao-0` `READY 0/1` ตลอด | ยังไม่ได้ init / unseal หรือ pod เพิ่ง restart | ขั้นที่ 4 หรือหัวข้อ "หลัง OpenBao restart" |
| `bao ...` error `permission denied` / `missing client token` | ไม่ได้ส่ง token หรือไม่ได้อยู่ใน directory ที่มี `init-keys.json` | ประกาศฟังก์ชัน `bao()` ใหม่ในขั้นที่ 5 |
| ClusterSecretStore `InvalidProviderConfig` / `permission denied` | role / policy / ServiceAccount ไม่ตรงกัน หรือ OpenBao ยัง seal | `kubectl describe clustersecretstore openbao` ตรวจว่า SA ชื่อ `external-secrets` ใน ns `external-secrets` ตรงกับ role |
| ExternalSecret `SecretSyncedError` `secret not found` | path ผิด — ใน ExternalSecret ใช้ `key: seaweedfs/s3-admin` (ไม่ต้องมี `secret/` หรือ `data/`) | ตรวจด้วย `bao kv get secret/seaweedfs/s3-admin` |
| `helm install external-secrets` error ว่ามี resource อยู่แล้ว | ESO / Vault ตัวเก่าจาก stack เดิมทิ้ง CRD / ClusterRole / webhook ไว้ | `kubectl get crd,clusterrole,validatingwebhookconfigurations -o name \| grep -iE 'external-secrets\|vault'` แล้วลบของเก่า |

ดู log

```bash
kubectl -n openbao logs openbao-0 --tail=50
kubectl -n external-secrets logs deploy/external-secrets --tail=50
```

---

## ถอนการติดตั้ง

```bash
kubectl delete -f /root/K8S-Stackable/external-secrets/cluster-secret-store.yaml
helm uninstall external-secrets -n external-secrets && kubectl delete ns external-secrets
kubectl delete -f /root/K8S-Stackable/openbao/ingress.yaml
helm uninstall openbao -n openbao
kubectl -n openbao delete pvc --all            # ลบข้อมูล secret ทั้งหมด กู้คืนไม่ได้ (ยกเว้นมี snapshot + unseal key)
kubectl delete ns openbao
```
