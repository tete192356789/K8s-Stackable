# 02 — ติดตั้ง MetalLB 0.16.1 (PoC)

แจก External IP ให้ Service ประเภท `LoadBalancer` (เช่น Traefik) เพื่อให้เครื่องนอก cluster เข้าถึงได้ผ่าน port มาตรฐาน

| รายการ | ค่า |
|---|---|
| MetalLB | Helm chart `metallb/metallb` 0.16.1, **L2 mode**, ปิด FRR |
| IP ที่ใช้ | **IP ของ node เอง** `172.19.10.62` (master), `.63` (worker1), `.64` (worker2) — ไม่มี IP ว่างเพิ่ม |
| ไฟล์ใน repo | `platform/metallb/values.yaml`, `platform/metallb/pool.yaml`, `scripts/prepull-images.sh` |
| ไฟล์บน master | `/root/K8S-Stackable/metallb/`, `/root/K8S-Stackable/scripts/` |
| ต้องติดตั้งก่อน | [01-longhorn.md](01-longhorn.md) (ขั้นที่ 0.4 ตั้ง SSH key ไป worker แล้ว) |

> ⚠️ **PoC นี้ใช้ MetalLB แบบไม่ปกติ** — ใช้ IP ของ node เป็น LoadBalancer IP ซึ่ง MetalLB ไม่รองรับอย่างเป็นทางการ
> อ่าน [หมายเหตุเรื่อง IP pool](#หมายเหตุเรื่อง-ip-pool) ให้เข้าใจก่อนติดตั้งและก่อนสร้าง Service ประเภท LoadBalancer ทุกครั้ง

---

## ค่าที่ตั้งใน `values.yaml`

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `frrk8s.enabled` | `false` | Chart 0.16 เปิด frr-k8s เป็นค่าเริ่มต้น ซึ่งใช้กับ BGP mode เท่านั้น ปิดเพื่อไม่ต้องดึง image เพิ่มและประหยัด RAM |
| `speaker.frr.enabled` | `false` | เหตุผลเดียวกัน ใช้ L2 mode อย่างเดียว |
| `controller.resources`, `speaker.resources` | req 50m / 64Mi, limit 128Mi | PoC มี RAM น้อย |

---

## ขั้นที่ 0: เช็กก่อนติดตั้ง

**0.1 kube-proxy ต้องเป็น mode `iptables` หรือ `ipvs` + `strictARP: true`** (รันบน master)
```bash
curl -s http://localhost:10249/proxyMode; echo                          # PoC นี้ได้: iptables
kubectl -n kube-system get cm kube-proxy -o yaml | grep -E 'mode:|strictARP'
```
ถ้าเป็น `iptables` ไม่ต้องทำอะไร (`strictARP` มีผลเฉพาะ mode ipvs)

**0.2 เอา label ที่กัน master ออกจาก LoadBalancer** (รันบน master)

kubeadm ติด label `node.kubernetes.io/exclude-from-external-load-balancers` ให้ control-plane อัตโนมัติ ถ้าไม่เอาออก speaker ของ MetalLB บน master จะไม่ประกาศ IP `.62`
```bash
kubectl get node master --show-labels | tr ',' '\n' | grep exclude-from-external
kubectl label node master node.kubernetes.io/exclude-from-external-load-balancers-
```

**0.3 Firewall** (รันบนทุก node)
```bash
systemctl is-active firewalld
```
ถ้าเป็น `active` ต้องเปิด port ที่ speaker ใช้คุยกันระหว่าง node
```bash
sudo firewall-cmd --permanent --add-port=7946/tcp --add-port=7946/udp --add-port=7472/tcp
sudo firewall-cmd --reload
```

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master

รันบนเครื่อง local ที่ root ของ repo
```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/metallb /root/K8S-Stackable/scripts'
scp platform/metallb/values.yaml platform/metallb/pool.yaml root@172.19.10.62:/root/K8S-Stackable/metallb/
scp scripts/prepull-images.sh root@172.19.10.62:/root/K8S-Stackable/scripts/
ssh root@172.19.10.62 'chmod +x /root/K8S-Stackable/scripts/prepull-images.sh'
```

---

## ขั้นที่ 2: ดึง image ล่วงหน้า (รันบน master)

MetalLB เขียนชื่อ image ไว้ในบรรทัด `image:` ครบ จึงใช้ `helm template` สร้างรายชื่อได้ (ต่างจาก Longhorn)
```bash
cd /root/K8S-Stackable/metallb
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm template metallb metallb/metallb --version 0.16.1 -f values.yaml \
  | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt                          # ควรมีแค่ quay.io/metallb/controller และ quay.io/metallb/speaker

../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log
```
Image มีขนาดเล็ก ใช้เวลาไม่กี่นาที ต้องจบด้วย `=== เสร็จ`

---

## ขั้นที่ 3: ติดตั้ง MetalLB (รันบน master)

```bash
cd /root/K8S-Stackable/metallb
helm install metallb metallb/metallb \
  -n metallb-system --create-namespace \
  --version 0.16.1 \
  -f values.yaml

kubectl -n metallb-system wait pod --all --for=condition=Ready --timeout=300s
kubectl -n metallb-system get pods -o wide
```
ต้องมี `metallb-controller` 1 ตัว และ `metallb-speaker` 3 ตัว (node ละ 1 ตัว) ทุกตัวเป็น `Running`

---

## ขั้นที่ 4: สร้าง IP pool

ต้องรอให้ controller เป็น `Ready` ก่อน (ขั้นที่ 3) เพราะ controller เป็นตัวตรวจสอบ pool ผ่าน webhook
```bash
kubectl apply -f pool.yaml
kubectl -n metallb-system get ipaddresspool,l2advertisement
```

ผลที่ถูกต้อง
```
NAME                                     AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
ipaddresspool.metallb.io/node-master     false         false             ["172.19.10.62/32"]
ipaddresspool.metallb.io/node-worker1    false         false             ["172.19.10.63/32"]
ipaddresspool.metallb.io/node-worker2    false         false             ["172.19.10.64/32"]

NAME                                     IPADDRESSPOOLS     IPADDRESSPOOL SELECTORS   INTERFACES
l2advertisement.metallb.io/node-master   ["node-master"]
l2advertisement.metallb.io/node-worker1  ["node-worker1"]
l2advertisement.metallb.io/node-worker2  ["node-worker2"]
```

---

## ขั้นที่ 5: ทดสอบ

สร้าง web server ทดสอบ 1 ตัว แล้วเปิดผ่าน IP ของทั้ง 3 node (ใช้ image busybox ที่มีอยู่แล้ว และใช้ port 18080 ซึ่งไม่ชนกับ port ของ node)
```bash
kubectl create deployment lb-test --image=busybox:1.36 -- \
  sh -c 'echo "hello from $(hostname)" > /tmp/index.html && httpd -f -p 8080 -h /tmp'

for n in 62 63 64; do
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: lb-test-$n
  annotations:
    metallb.io/loadBalancerIPs: 172.19.10.$n
spec:
  type: LoadBalancer
  selector: { app: lb-test }
  ports: [{ port: 18080, targetPort: 8080 }]
EOF
done

kubectl get svc | grep lb-test          # EXTERNAL-IP ต้องเป็น .62 / .63 / .64 ไม่ใช่ <pending>
```

ทดสอบจาก**เครื่องอื่นใน network** (เช่น Mac)
```bash
for n in 62 63 64; do curl -s --max-time 5 http://172.19.10.$n:18080 || echo "172.19.10.$n FAIL"; done
```
ต้องได้ `hello from lb-test-...` ครบทั้ง 3 IP

ลบของทดสอบ
```bash
kubectl delete svc lb-test-62 lb-test-63 lb-test-64
kubectl delete deployment lb-test
```

---

## หมายเหตุเรื่อง IP pool

### ทำไมต้องใช้ IP ของ node
PoC นี้มีแค่ IP ของ node 3 ตัว (`.62–.64`) ไม่มี IP ว่างให้ MetalLB แจก จึงให้ MetalLB ใช้ IP ของ node เอง โดยแยกเป็น **1 pool ต่อ node** และ**ให้ node เจ้าของ IP เป็นคนประกาศเท่านั้น** (`nodeSelectors`) คนที่ตอบ ARP จึงยังเป็นเครื่องเดิมด้วย MAC เดิม ทำให้ไม่มี IP ชนกัน

### สิ่งที่ได้และไม่ได้

| | ได้ไหม |
|---|---|
| Service ประเภท `LoadBalancer` ได้ `EXTERNAL-IP` เหมือน production | ✅ |
| เข้าผ่าน port มาตรฐาน (80/443) ไม่ต้องใช้ NodePort | ✅ |
| **Failover: node ล่มแล้ว IP ย้ายไป node อื่น** | ❌ **ไม่ได้** IP ของ node ย้ายไม่ได้ ถ้า master ล่ม `.62` ใช้ไม่ได้จนกว่า master จะกลับมา ให้ผู้ใช้เข้าผ่าน `.63` หรือ `.64` แทน |
| รองรับอย่างเป็นทางการ | ❌ เอกสาร MetalLB ระบุว่า IP ใน pool ต้องไม่ใช่ IP ที่มีเครื่องใช้อยู่ ใช้ได้เฉพาะ PoC ก่อนอัปเกรด MetalLB ต้องทดสอบซ้ำ |

### ⚠️ กติกาที่ต้องทำตามเมื่อสร้าง Service ประเภท LoadBalancer

**1. ต้องระบุ IP เองทุกครั้ง** เพราะทุก pool ตั้ง `autoAssign: false` ไว้ ถ้าไม่ใส่ annotation Service จะค้าง `EXTERNAL-IP <pending>`
```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 172.19.10.62
```

**2. หลาย Service ใช้ IP เดียวกันได้ ถ้าใส่ sharing key เดียวกันและใช้ port ไม่ซ้ำกัน** มีแค่ 3 IP ดังนั้น Service ส่วนใหญ่ต้องใช้ IP ร่วมกัน
```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 172.19.10.62
    metallb.io/allow-shared-ip: "node-ip"      # ใช้ key เดียวกันทุก Service ที่แชร์ IP นี้
spec:
  externalTrafficPolicy: Cluster                # Service ที่แชร์ IP กันต้องใช้ค่าเดียวกัน
```

**3. ห้ามเปิด Service บน port ที่ node ใช้อยู่** kube-proxy จะดักทุก traffic ที่เข้ามาที่ `IP:port` นั้นแล้วส่งไปที่ pod แทน **ทำให้ service ของ node หยุดทำงานทันที** เช่น เปิด Service port 22 บน `.62` จะทำให้ SSH เข้า master ไม่ได้

| Port ห้ามใช้ | ของใคร |
|---|---|
| 22 | SSH |
| 6443 | Kubernetes API server (master) |
| 2379–2380 | etcd (master) |
| 10250, 10256, 10257, 10259 | kubelet, kube-proxy, controller-manager, scheduler |
| 179, 5473 | Calico BGP, Calico Typha |
| 7946, 7472 | MetalLB speaker |
| 9100 | node-exporter (หลังติดตั้ง Prometheus) |
| 111, 2049 | NFS (master) |
| 3260 | iSCSI (Longhorn) |

เช็กก่อนว่า port ที่จะใช้ว่างบน node ไหม
```bash
ss -ltnup | grep -E ':(80|443)\s' || echo "ว่าง"
```

**4. IP ไหนใช้กับอะไร** จดไว้ในตารางนี้ทุกครั้งที่สร้าง Service ใหม่

| IP | Port | Service | Namespace |
|---|---|---|---|
| 172.19.10.62 | 80, 443 | Traefik (จะติดตั้งในขั้นถัดไป) | traefik |
| 172.19.10.63 | 80, 443 | Traefik (Service ตัวที่ 2 ชี้ไปที่ pod เดียวกัน) | traefik |
| 172.19.10.64 | 80, 443 | Traefik (Service ตัวที่ 3 ชี้ไปที่ pod เดียวกัน) | traefik |

> **Service หนึ่งตัวได้ LoadBalancer IP แค่ 1 IP** ถ้าต้องการให้ Traefik เข้าได้จากทั้ง 3 IP ต้องสร้าง Service 3 ตัวที่ใช้ selector เดียวกัน รายละเอียดอยู่ในเอกสารติดตั้ง Traefik

### ย้ายไป production
1. ขอ IP ว่างจากทีม Network (อยู่นอกช่วง DHCP)
2. แก้ `pool.yaml` ให้เหลือ pool เดียวที่เป็น IP ว่างจริง และ**ลบ `nodeSelectors` และ `autoAssign: false` ออก**
3. เปลี่ยน annotation `metallb.io/loadBalancerIPs` ของ Traefik เป็น IP ใหม่ แล้วลบ Service ตัวที่ 2 และ 3 ออก
4. เปลี่ยน DNS ให้ชี้ไปที่ IP ใหม่

จากนั้น IP จะย้ายไป node อื่นเองเมื่อ node ล่ม (failover)

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| `EXTERNAL-IP <pending>` | ไม่ได้ใส่ annotation `metallb.io/loadBalancerIPs` (pool เป็น `autoAssign: false`) | ใส่ annotation ตามกติกาข้อ 1 |
| `EXTERNAL-IP <pending>` และ event ขึ้นว่า `can't change sharing key` หรือ `port is already allocated` | ใช้ IP ร่วมกันแต่ sharing key ไม่ตรงกัน หรือ port ซ้ำกัน | ใส่ `metallb.io/allow-shared-ip` ให้ตรงกัน และใช้ port ที่ไม่ซ้ำ |
| `.62` ได้ IP แต่ curl จากภายนอกไม่ได้ | label `exclude-from-external-load-balancers` ยังติดอยู่บน master หรือ firewall ปิด port | ทำขั้นที่ 0.2 และ 0.3 |
| `kubectl apply -f pool.yaml` ขึ้น error เรื่อง webhook | controller ยังไม่ Ready | รอขั้นที่ 3 ให้เสร็จแล้ว apply ใหม่ |
| SSH หรือ `kubectl` ไปที่ master ใช้ไม่ได้หลังสร้าง Service | Service ไปใช้ port 22 หรือ 6443 บน `.62` | ลบ Service นั้นทันที (รัน `kubectl` จาก worker หรือใช้ console ของ VM) แล้วอ่านกติกาข้อ 3 |

ดู log ประกอบการแก้ปัญหา
```bash
kubectl -n metallb-system logs deploy/metallb-controller --tail=50
kubectl -n metallb-system logs -l app.kubernetes.io/component=speaker --tail=50
kubectl describe svc <ชื่อ service> | sed -n '/Events:/,$p'
```

---

## ถอนการติดตั้ง

ต้องลบ Service ประเภท LoadBalancer ทั้งหมดก่อน
```bash
kubectl get svc -A | grep LoadBalancer
kubectl delete -f pool.yaml
helm uninstall metallb -n metallb-system
kubectl delete ns metallb-system
```
