# 03 — ติดตั้ง Traefik 3.7.13 (PoC)

Ingress controller สำหรับทุก service ที่เป็น HTTP/HTTPS (Grafana, Superset, Airflow, Keycloak, ArgoCD, Longhorn UI ฯลฯ) ใช้ IP ของ node ร่วมกันผ่าน port 80/443

| รายการ                   | ค่า                                                                                          |
| ------------------------------ | ----------------------------------------------------------------------------------------------- |
| Traefik                        | 3.7.13 (Helm chart`traefik/traefik` 41.6.0)                                                   |
| รูปแบบ                   | **DaemonSet** (ทุก node มี 1 ตัว)                                                 |
| เข้าถึงผ่าน         | `172.19.10.62`, `.63`, `.64` port 80 และ 443 (IP จาก MetalLB แบบ IP ของ node) |
| IngressClass                   | `traefik` (ตั้งเป็น default)                                                          |
| ไฟล์ใน repo              | `platform/traefik/values.yaml`, `platform/traefik/extra-services.yaml`                      |
| ไฟล์บน master            | `/root/K8S-Stackable/traefik/`                                                                |
| ต้องติดตั้งก่อน | [02-metallb.md](02-metallb.md)                                                                   |

```
Mac / ผู้ใช้ ──▶ 172.19.10.62:443 ──▶ Service traefik          ─┐
            ──▶ 172.19.10.63:443 ──▶ Service traefik-worker1  ─┼──▶ pod Traefik (ทุก node) ──▶ Service ปลายทาง
            ──▶ 172.19.10.64:443 ──▶ Service traefik-worker2  ─┘
```

---

## ค่าที่ตั้งใน `values.yaml`

| ค่า                                                 | ตั้งเป็น            | เหตุผล                                                                                                                                                                                                   |
| ------------------------------------------------------ | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deployment.kind`                                    | `DaemonSet`               | ทุก node มี Traefik ถ้า node ใดล่ม ยังมี Traefik บน node อื่นรับงานต่อทันที                                                                                              |
| `resources`                                          | req 50m / 64Mi, limit 192Mi | PoC มี RAM น้อย (3 ตัวรวมกันไม่เกิน ~576 MB)                                                                                                                                             |
| `ingressClass.isDefaultClass`                        | `true`                    | Ingress ที่ไม่ระบุ`ingressClassName` จะใช้ Traefik อัตโนมัติ                                                                                                                         |
| `service.annotations` `metallb.io/loadBalancerIPs` | `172.19.10.62`            | ขอ IP ของ master (pool ของ MetalLB เป็น`autoAssign: false`)                                                                                                                                      |
| `service.annotations` `metallb.io/allow-shared-ip` | `node-ip`                 | ให้ Service อื่นใช้ IP นี้ร่วมได้ (คนละ port)                                                                                                                                          |
| `service.spec.externalTrafficPolicy`                 | `Cluster`                 | MetalLB บังคับให้ Service ที่แชร์ IP กันใช้ค่าเดียวกัน ข้อเสียคือ Traefik จะเห็น source IP เป็น IP ของ node ไม่ใช่ IP จริงของผู้ใช้ |

`extra-services.yaml` สร้าง Service อีก 2 ตัว (`traefik-worker1` → `.63`, `traefik-worker2` → `.64`) ชี้ไปที่ pod Traefik ชุดเดียวกัน เพราะ Service 1 ตัวได้ LoadBalancer IP แค่ 1 IP

---

## ขั้นที่ 0: เช็กก่อนติดตั้ง

**0.1 port 80 และ 443 ต้องว่างบนทุก node**

LoadBalancer IP เป็น IP เดียวกับ node ถ้ามีโปรแกรมบน node ใช้ port 80/443 อยู่ kube-proxy จะดัก traffic ไปที่ Traefik แทน (โปรแกรมนั้นจะรับ traffic จากภายนอกไม่ได้)

```bash
for h in 172.19.10.62 172.19.10.63 172.19.10.64; do
  echo "== $h"; ssh root@$h "ss -ltnp | grep -E ':(80|443)\s' || echo 'ว่าง'"
done
```

**0.2 Firewall** (ถ้า `firewalld` เป็น active บนทุก node)

```bash
sudo firewall-cmd --permanent --add-service=http --add-service=https && sudo firewall-cmd --reload
```

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master

รันบนเครื่อง local ที่ root ของ repo

```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/traefik'
scp platform/traefik/values.yaml platform/traefik/extra-services.yaml root@172.19.10.62:/root/K8S-Stackable/traefik/
```

---

## ขั้นที่ 2: เช็ก values และดึง image ล่วงหน้า (รันบน master)

```bash
cd /root/K8S-Stackable/traefik
helm repo add traefik https://traefik.github.io/charts
helm repo update

# 2.1 สร้าง YAML ดูก่อน เพื่อยืนยันว่า values ถูกนำไปใช้ (chart มี schema ถ้าใส่ key ผิดจะ error ตรงนี้)
helm template traefik traefik/traefik -n traefik --version 41.6.0 -f values.yaml > rendered.yaml
grep -E '^kind: (DaemonSet|Deployment)' rendered.yaml         # ต้องได้: kind: DaemonSet
grep -A3 'metallb.io' rendered.yaml                          # ต้องเห็น annotation ของ .62
grep -E 'type: LoadBalancer|externalTrafficPolicy' rendered.yaml

# 2.2 ดึง image
grep -oE 'image: *"?[^" ]+' rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt                                               # ควรมีแค่ docker.io/traefik:v3.7.13
../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log
```

---

## ขั้นที่ 3: ติดตั้ง (รันบน master)

```bash
cd /root/K8S-Stackable/traefik
helm install traefik traefik/traefik \
  -n traefik --create-namespace \
  --version 41.6.0 \
  -f values.yaml

kubectl -n traefik rollout status ds/traefik --timeout=300s
kubectl -n traefik get pods -o wide --show-labels         # ต้องมี 3 pod (node ละ 1 ตัว)
```

ตรวจว่า label ของ pod มี `app.kubernetes.io/name=traefik` (selector ใน `extra-services.yaml` ใช้ label นี้) แล้วสร้าง Service ของ worker

```bash
kubectl apply -f extra-services.yaml
kubectl -n traefik get svc
```

ผลที่ถูกต้อง

```
NAME              TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)
traefik           LoadBalancer   10.x.x.x        172.19.10.62   80:3xxxx/TCP,443:3xxxx/TCP
traefik-worker1   LoadBalancer   10.x.x.x        172.19.10.63   80:3xxxx/TCP,443:3xxxx/TCP
traefik-worker2   LoadBalancer   10.x.x.x        172.19.10.64   80:3xxxx/TCP,443:3xxxx/TCP
```

ถ้า `EXTERNAL-IP` ค้าง `<pending>` ดู [ปัญหาที่พบบ่อย](#ปัญหาที่พบบ่อย)

ตรวจว่า Service ทั้ง 3 ตัวมี endpoint ครบ (ต้องเห็น IP ของ pod 3 ตัวทุก Service)

```bash
kubectl -n traefik get endpointslices
```

---

## ขั้นที่ 4: ทดสอบ routing

ยังไม่ต้องมี DNS ใช้ `curl -H "Host: ..."` แทนการพิมพ์ชื่อ domain

```bash
# 4.1 สร้าง app ทดสอบ + Ingress
kubectl create deployment ing-test --image=busybox:1.36 -- \
  sh -c 'echo "hello-traefik" > /tmp/index.html && httpd -f -p 8080 -h /tmp'
kubectl expose deployment ing-test --port=80 --target-port=8080
kubectl create ingress ing-test --rule="ing-test.local/*=ing-test:80"
```

ทดสอบจาก**เครื่องอื่นใน network** (เช่น Mac)

```bash
for n in 62 63 64; do
  echo "== .$n"
  curl -s  --max-time 5 -H 'Host: ing-test.local' http://172.19.10.$n/        # ต้องได้ hello-traefik
  curl -sk --max-time 5 -H 'Host: ing-test.local' https://172.19.10.$n/       # ต้องได้ hello-traefik (cert ยังเป็น self-signed ของ Traefik)
done
curl -s -o /dev/null -w '%{http_code}\n' http://172.19.10.62/                 # host ที่ไม่มี Ingress → ต้องได้ 404
```

ลบของทดสอบ

```bash
kubectl delete ingress ing-test && kubectl delete svc,deployment ing-test
```

---

## ขั้นที่ 5: เปิด Longhorn UI ผ่าน Traefik + Basic Auth

Longhorn UI ไม่มีระบบ login จึงต้องมี Basic Auth ที่ Traefik ก่อนเปิดใช้ (หลังติดตั้ง Keycloak ค่อยเปลี่ยนเป็น SSO)

**5.1 เลือก domain** — ถ้ายังไม่มี DNS ขององค์กร ใช้ `sslip.io` ได้ทันที (ชื่อ `xxx.172.19.10.62.sslip.io` จะแปลงเป็น IP `172.19.10.62` เอง เครื่องผู้ใช้ต้องใช้ DNS ภายนอกได้)

```bash
DOMAIN=172.19.10.62.sslip.io          # ถ้าได้ wildcard DNS จากทีม Network แล้ว ให้เปลี่ยนเป็น เช่น platform.kube.com
```

**5.2 สร้าง user/password** (ใช้ `htpasswd` จาก package `httpd-tools`)

ใช้ `read` เพื่อพิมพ์รหัสโดยไม่แสดงบนจอและไม่ติดอยู่ใน shell history รหัสผ่าน**ใช้ได้แค่ตัวอักษรภาษาอังกฤษ ตัวเลข และสัญลักษณ์** เพราะ browser ส่งภาษาไทยใน Basic Auth ไม่ถูกต้อง

```bash
dnf install -y httpd-tools
read -rsp 'Longhorn UI password: ' LH_PASS; echo
kubectl -n longhorn-system create secret generic longhorn-basic-auth \
  --from-literal=users="$(htpasswd -nbB admin "$LH_PASS")" \
  --dry-run=client -o yaml | kubectl apply -f -
```

คำสั่งนี้ใช้เปลี่ยนรหัสผ่านภายหลังได้ด้วย Traefik อ่าน Secret ใหม่ให้เอง ไม่ต้อง restart

**5.3 สร้าง Middleware และ Ingress**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth
  namespace: longhorn-system
spec:
  basicAuth:
    secret: longhorn-basic-auth
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.middlewares: longhorn-system-basic-auth@kubernetescrd
spec:
  rules:
    - host: longhorn.${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: longhorn-frontend, port: { number: 80 } }
EOF
```

**5.4 ทดสอบ**

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://longhorn.${DOMAIN}/                      # ต้องได้ 401 (ไม่ได้ใส่รหัส)
curl -sk -o /dev/null -w '%{http_code}\n' -u "admin:$LH_PASS" https://longhorn.${DOMAIN}/   # ต้องได้ 200
```

ถ้าได้ 401 ทั้งสองบรรทัด แปลว่ารหัสผ่านไม่ตรงกับที่ตั้งไว้ใน Secret เช็กได้ด้วย
```bash
kubectl -n longhorn-system get secret longhorn-basic-auth -o jsonpath='{.data.users}' | base64 -d > /tmp/lh.htpasswd
htpasswd -vb /tmp/lh.htpasswd admin "$LH_PASS"      # ต้องได้: Password for user admin correct.
rm -f /tmp/lh.htpasswd
```
ถ้าไม่ตรง ให้ทำขั้น 5.2 ใหม่เพื่อตั้งรหัสใหม่

เปิดใน browser ที่ `https://longhorn.172.19.10.62.sslip.io` (browser จะเตือนเรื่อง certificate เพราะยังเป็น self-signed จะแก้เมื่อติดตั้ง cert-manager)

> ชื่อ annotation ของ middleware คือ `<namespace>-<ชื่อ middleware>@kubernetescrd` เช่น `longhorn-system-basic-auth@kubernetescrd`

---

## ปัญหาที่พบบ่อย

| อาการ                                                                     | สาเหตุ                                                                                                                                                             | วิธีแก้                                                                                             |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `helm template` / `helm install` error เรื่อง schema                 | ใส่ key ใน`values.yaml` ไม่ตรงกับ chart 41.6.0                                                                                                           | ดู key ที่ถูกต้องด้วย`helm show values traefik/traefik --version 41.6.0 \| less`          |
| `EXTERNAL-IP <pending>`                                                      | ไม่มี annotation`metallb.io/loadBalancerIPs` หรือ sharing key / `externalTrafficPolicy` ไม่ตรงกับ Service อื่นที่ใช้ IP เดียวกัน | `kubectl -n traefik describe svc <ชื่อ>` ดู event แล้วแก้ตามกติกาใน 02-metallb.md |
| `traefik-worker1/2` ได้ IP แต่ curl ไม่ได้ / ไม่มี endpoint | selector ไม่ตรงกับ label ของ pod                                                                                                                             | เทียบ`kubectl -n traefik get pods --show-labels` กับ selector ใน `extra-services.yaml`       |
| curl ได้ 404 ทั้งที่มี Ingress                                     | Host header ไม่ตรงกับ`host` ใน Ingress หรือ Ingress ไม่ได้ใช้ class `traefik`                                                                | `kubectl get ingress -A` ดูคอลัมน์ CLASS และ HOSTS                                           |
| Middleware ไม่ทำงาน (ไม่ถามรหัส)                             | ชื่อใน annotation ผิด                                                                                                                                           | ต้องเป็น`<namespace>-<name>@kubernetescrd`                                                       |
| `.62` ใช้ได้แต่ `.63/.64` ใช้ไม่ได้                      | ยังไม่ได้ apply`extra-services.yaml`                                                                                                                          | ขั้นที่ 3                                                                                           |

ดู log

```bash
kubectl -n traefik logs ds/traefik --tail=50
```

---

## ถอนการติดตั้ง

```bash
kubectl delete -f extra-services.yaml
helm uninstall traefik -n traefik
kubectl delete ns traefik
# CRD ของ Traefik (traefik.io) ไม่ถูกลบโดย helm ถ้าต้องการลบ:
kubectl get crd -o name | grep traefik.io | xargs -r kubectl delete
```
