# 04 — Prometheus Operator CRDs + cert-manager + Internal CA (PoC)

พื้นฐานที่ service อื่นต้องใช้ ติดตั้งก่อน CNPG, SeaweedFS, Keycloak และ Stackable

| รายการ                       | ค่า                                                                                                                                                                 |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prometheus Operator CRDs           | Helm chart`prometheus-community/prometheus-operator-crds` 32.0.1 (operator v0.94.1 ตรงกับ kube-prometheus-stack 91.5.2 ที่จะติดตั้งภายหลัง) |
| cert-manager                       | v1.21.2 (Helm chart`jetstack/cert-manager` v1.21.2)                                                                                                                  |
| CA                                 | **Internal CA** สร้างเองใน cluster (ClusterIssuer `platform-ca`)                                                                                     |
| Certificate หลักของ Traefik | Wildcard`*.172.19.10.{62,63,64}.sslip.io` อายุ 90 วัน ต่ออายุอัตโนมัติ                                                                        |
| ไฟล์ใน repo                  | `platform/cert-manager/values.yaml`, `platform/cert-manager/internal-ca.yaml`, `platform/traefik/default-cert.yaml`                                              |
| ไฟล์บน master                | `/root/K8S-Stackable/cert-manager/`, `/root/K8S-Stackable/traefik/`                                                                                                |
| ต้องติดตั้งก่อน     | [03-traefik.md](03-traefik.md)                                                                                                                                          |

**ทำไมต้องติดตั้ง CRDs ของ Prometheus ตอนนี้** — chart ของ CNPG, SeaweedFS, Traefik และ Stackable สร้าง `ServiceMonitor` / `PodMonitor` ให้ Prometheus เก็บ metric ถ้ายังไม่มี CRD เหล่านี้ chart จะติดตั้งไม่ผ่าน จึงติดตั้ง CRD แยกไว้ก่อน ส่วน Prometheus จริงติดตั้งภายหลัง (ตอนนั้นต้องตั้ง `crds.enabled: false` ใน kube-prometheus-stack)

**โครงสร้าง CA**

```
ClusterIssuer selfsigned-bootstrap ──ออก──▶ Certificate platform-ca (Root CA อายุ 10 ปี, secret platform-ca ใน ns cert-manager)
                                                  │
                                    ClusterIssuer platform-ca ──ออก──▶ certificate ของทุก service
                                                                        เช่น wildcard ของ Traefik (ns traefik)
```

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master

รันบนเครื่อง local ที่ root ของ repo

```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/cert-manager /root/K8S-Stackable/traefik'
scp platform/cert-manager/values.yaml platform/cert-manager/internal-ca.yaml root@172.19.10.62:/root/K8S-Stackable/cert-manager/
scp platform/traefik/default-cert.yaml root@172.19.10.62:/root/K8S-Stackable/traefik/
```

---

## ขั้นที่ 2: Prometheus Operator CRDs (รันบน master)

Chart นี้มีแค่ CRD ไม่มี image ไม่ต้อง prepull

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
  -n monitoring --create-namespace --version 32.0.1

kubectl get crd | grep monitoring.coreos.com
```

ต้องเห็น CRD 10 ตัว เช่น `servicemonitors`, `podmonitors`, `prometheusrules`, `prometheuses`, `alertmanagers`

---

## ขั้นที่ 3: ดึง image ของ cert-manager ล่วงหน้า (รันบน master)

```bash
cd /root/K8S-Stackable/cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm template cert-manager jetstack/cert-manager -n cert-manager --version v1.21.2 -f values.yaml > rendered.yaml
grep -oE 'image: *"?[^" ]+' rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt        # ควรมี 4 ตัว: cert-manager-controller, -webhook, -cainjector, -startupapicheck

../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log
```

ต้องจบด้วย `imported` 2 ครั้งและ `=== เสร็จ`

> image `cert-manager-acmesolver` ไม่อยู่ในรายการเพราะส่งผ่าน argument และใช้เฉพาะ ACME (Let's Encrypt) ซึ่ง PoC ไม่ได้ใช้

---

## ขั้นที่ 4: ติดตั้ง cert-manager (รันบน master)

```bash
cd /root/K8S-Stackable/cert-manager
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --version v1.21.2 \
  -f values.yaml

kubectl -n cert-manager wait pod --all --for=condition=Ready --timeout=300s
kubectl -n cert-manager get pods
```

ต้องมี `cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector` เป็น `Running` (pod `startupapicheck` เป็น Job จะจบเป็น `Completed`)

---

## ขั้นที่ 5: สร้าง Internal CA

```bash
kubectl apply -f /root/K8S-Stackable/cert-manager/internal-ca.yaml

kubectl -n cert-manager wait certificate/platform-ca --for=condition=Ready --timeout=120s
kubectl get clusterissuer
```

ผลที่ถูกต้อง

```
NAME                   READY
platform-ca            True
selfsigned-bootstrap   True
```

---

## ขั้นที่ 6: Certificate หลักของ Traefik

```bash
kubectl apply -f /root/K8S-Stackable/traefik/default-cert.yaml
kubectl -n traefik wait certificate/wildcard-platform --for=condition=Ready --timeout=120s
kubectl -n traefik get certificate,tlsstore
```

ตรวจว่า Traefik ใช้ certificate ใหม่แล้ว (issuer ต้องเป็น `K8s-Stackable PoC Root CA` ไม่ใช่ `TRAEFIK DEFAULT CERT`)

```bash
echo | openssl s_client -connect 172.19.10.62:443 -servername longhorn.172.19.10.62.sslip.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Ingress ที่มีอยู่แล้ว (เช่น Longhorn UI) ใช้ certificate ใหม่ทันที ไม่ต้องแก้ เพราะเปิด TLS โดยไม่ได้ระบุ secret จึงใช้ certificate หลักของ `TLSStore default`

---

## ขั้นที่ 7: ให้เครื่องผู้ใช้เชื่อ CA

**7.1 Export CA certificate** (รันบน master)

```bash
kubectl -n cert-manager get secret platform-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /root/K8S-Stackable/platform-ca.crt
openssl x509 -in /root/K8S-Stackable/platform-ca.crt -noout -subject -enddate
```

> ไฟล์ `ca.crt` เป็นข้อมูลสาธารณะ แจกได้ **แต่ห้ามแจก `tls.key` ของ secret `platform-ca`** เพราะใครได้ไปจะออก certificate ปลอมที่ทุกเครื่องเชื่อได้

**7.2 Import บนเครื่องผู้ใช้**

| OS                                | คำสั่ง                                                                                                                                                                      |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS                             | `scp root@172.19.10.62:/root/K8S-Stackable/platform-ca.crt .` แล้ว `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain platform-ca.crt` |
| Windows (PowerShell แบบ Admin) | `certutil -addstore -f Root platform-ca.crt`                                                                                                                                    |
| Rocky / RHEL                      | `sudo cp platform-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust`                                                                                             |
| Ubuntu / Debian                   | `sudo cp platform-ca.crt /usr/local/share/ca-certificates/platform-ca.crt && sudo update-ca-certificates`                                                                       |
| Firefox                           | ใช้ store ของตัวเอง: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import                                                     |

ปิดแล้วเปิด browser ใหม่หลัง import

**7.3 ทดสอบ** (บนเครื่องที่ import แล้ว ไม่ต้องใช้ `-k`)

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://longhorn.172.19.10.62.sslip.io/      # ต้องได้ 401 และไม่มี error เรื่อง certificate
```

เปิด `https://longhorn.172.19.10.62.sslip.io` ใน browser ต้องขึ้นรูปกุญแจ ไม่มีคำเตือน

---

## การขอ certificate ให้ service อื่นในอนาคต

**แบบที่ 1 — ใช้ wildcard หลัก (ง่ายที่สุด):** Ingress ที่ใช้ host `*.172.19.10.6x.sslip.io` ไม่ต้องทำอะไร แค่เปิด TLS

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
```

**แบบที่ 2 — ออก certificate เฉพาะ service:** ใช้เมื่อ service ต้องมี certificate ของตัวเอง (เช่น TLS ภายในระหว่าง service)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-service-tls
  namespace: my-namespace
spec:
  secretName: my-service-tls
  dnsNames: [my-service.my-namespace.svc, my-service.my-namespace.svc.cluster.local]
  issuerRef: { name: platform-ca, kind: ClusterIssuer, group: cert-manager.io }
```

> Service ใน cluster ที่เรียกกันผ่าน HTTPS (เช่น Trino / Superset / Airflow เรียก Keycloak) ต้องเชื่อ CA นี้ด้วย จะจัดการตอนติดตั้ง Keycloak

---

## ปัญหาที่พบบ่อย

| อาการ                                                                                                                                     | สาเหตุ                                                                                                                                        | วิธีแก้                                                                                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `helm install cert-manager` error `Role "cert-manager-cainjector:leaderelection" in namespace "kube-system" exists and cannot be imported` | cert-manager ตัวเก่า (stack เดิม) ทิ้ง Role/RoleBinding ไว้ใน`kube-system` (script ล้าง cluster ไม่แตะ kube-system) | `kubectl -n kube-system get role,rolebinding,lease,serviceaccount,configmap,secret -o name \| grep -i cert-manager \| xargs -r kubectl -n kube-system delete` แล้วติดตั้งใหม่ |
| `kubectl apply -f internal-ca.yaml` error `failed calling webhook "webhook.cert-manager.io"`                                               | webhook ของ cert-manager ยังไม่พร้อม                                                                                                  | รอขั้นที่ 4 ให้ pod Ready ทุกตัว แล้ว apply ใหม่                                                                                                                   |
| Certificate ค้าง`READY False`                                                                                                            | ดูสาเหตุใน CertificateRequest                                                                                                             | `kubectl describe certificate <ชื่อ> -n <ns>` และ `kubectl get certificaterequest -A`                                                                                             |
| openssl ยังเห็น`TRAEFIK DEFAULT CERT`                                                                                                 | TLSStore ไม่ได้ชื่อ`default` หรือ secret ยังไม่ถูกสร้าง                                                               | `kubectl -n traefik get tlsstore,secret` และดู log ของ Traefik                                                                                                                     |
| Browser ยังเตือนหลัง import CA                                                                                                     | ยังไม่ได้ restart browser หรือเป็น Firefox (ใช้ store แยก)                                                                   | ปิด-เปิด browser / import ใน Firefox ตามตาราง 7.2                                                                                                                           |
| `helm install prometheus-operator-crds` error ว่า CRD มีอยู่แล้ว                                                                | มี CRD ค้างจากการติดตั้งเก่า                                                                                                 | `kubectl get crd \| grep monitoring.coreos.com` ถ้าเป็นของเก่าให้ลบก่อน                                                                                              |

ดู log

```bash
kubectl -n cert-manager logs deploy/cert-manager --tail=50
```

---

## ถอนการติดตั้ง

```bash
kubectl delete -f /root/K8S-Stackable/traefik/default-cert.yaml
kubectl delete -f /root/K8S-Stackable/cert-manager/internal-ca.yaml
helm uninstall cert-manager -n cert-manager
kubectl delete ns cert-manager
# CRD ของ cert-manager ไม่ถูกลบ (crds.keep: true) ถ้าต้องการลบ:
kubectl get crd -o name | grep cert-manager.io | xargs -r kubectl delete
```

> ถ้าลบ secret `platform-ca` แล้วสร้าง CA ใหม่ ทุกเครื่องต้อง import CA ใหม่อีกครั้ง
