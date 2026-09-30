# 01 — ติดตั้ง Longhorn 1.12.1 (PoC)

Block storage สำหรับ PVC ของ PostgreSQL (CNPG), Prometheus, Loki และ OpenBao

| รายการ | ค่า |
|---|---|
| Longhorn | 1.12.1 (Helm chart `longhorn/longhorn` 1.12.1) |
| Cluster | kubeadm K8s 1.33.6, Rocky Linux 9.6, containerd 2.1.5, Calico |
| Node | master `172.19.10.62`, worker1 `172.19.10.63`, worker2 `172.19.10.64` (4 vCPU / 15 GB ต่อ node) |
| ที่เก็บข้อมูล | `/var/lib/longhorn` บน root filesystem (ไม่มี data disk แยก) |
| ไฟล์ใน repo | `platform/longhorn/values.yaml`, `scripts/prepull-images.sh` |
| ไฟล์บน master | `/root/K8S-Stackable/longhorn/`, `/root/K8S-Stackable/scripts/` |

> **ทำไมต้องดึง image ล่วงหน้า:** internet ของ server ช้า (~465 KB/s) และการดาวน์โหลดไฟล์ใหญ่จาก Docker Hub มักถูกตัดกลางทาง (`connection reset by peer`) ถ้าให้ kubelet ดึงเองทั้ง 3 node pod จะค้าง `ContainerCreating` นานเป็นชั่วโมง จึงให้ดึงบน master ครั้งเดียวแล้วส่งต่อไป worker ผ่าน LAN

---

## ค่าที่ตั้งใน `values.yaml`

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `persistence.defaultClass` | `true` | ให้ `longhorn` เป็น StorageClass หลักของ cluster |
| `defaultReplicaCount` / `defaultClassReplicaCount` | `2` | ข้อมูลอยู่ 2 node ประหยัด disk กว่า 3 และยังทนได้เมื่อ node ล่ม 1 ตัว |
| `defaultDataPath` | `/var/lib/longhorn` | ไม่มี data disk แยก จึงใช้ directory บน `/` |
| `storageReservedPercentageForDefaultDisk` | `70` | กันพื้นที่ 70% ของ `/` ไว้ให้ OS, container image และ SeaweedFS ทำให้ Longhorn ใช้ได้ประมาณ 80 GB ต่อ node |
| `storageMinimalAvailablePercentage` | `25` | หยุดสร้าง replica ใหม่ถ้า disk เหลือน้อยกว่า 25% |
| `replicaSoftAntiAffinity` | `false` | บังคับให้ replica อยู่คนละ node |
| `nodeDownPodDeletionPolicy` | `delete-both-statefulset-and-deployment-pod` | ถ้า node ล่ม ให้ลบ pod ที่ค้างอยู่ เพื่อให้ไปสร้างใหม่บน node อื่นได้ |
| `csi.*ReplicaCount`, `longhornUI.replicas` | `1` | PoC มี RAM น้อย จึงลด replica ของ component ลง |

---

## ขั้นที่ 0: เตรียม node (ทำครั้งเดียว)

**0.1 เอา taint ออกจาก master** เพื่อให้ master รับ workload และเป็น storage node ด้วย (รันบน master)
```bash
kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule-
kubectl describe node master | grep Taints        # ต้องได้ <none>
```

**0.2 ติดตั้ง package ที่ Longhorn ต้องใช้** (รันบนทุก node)
```bash
sudo dnf install -y iscsi-initiator-utils nfs-utils cryptsetup device-mapper
sudo systemctl enable --now iscsid
echo iscsi_tcp | sudo tee /etc/modules-load.d/iscsi_tcp.conf && sudo modprobe iscsi_tcp
```

**0.3 เช็กความพร้อม** (รันบนทุก node)
```bash
rpm -q iscsi-initiator-utils nfs-utils       # ต้องติดตั้งแล้ว
systemctl is-active iscsid                   # ต้องเป็น active
systemctl is-active multipathd               # ควรเป็น inactive
swapon --show                                # ต้องไม่แสดงผล (swap ปิดอยู่)
df -h /                                      # ต้องเหลือพื้นที่ว่างอย่างน้อย ~200 GB
```

ถ้า `multipathd` เป็น `active` ให้เพิ่ม blacklist ในไฟล์ `/etc/multipath.conf` แล้ว restart ไม่อย่างนั้น multipathd จะแย่งจับ device ของ Longhorn
```
blacklist {
    devnode "^sd[a-z0-9]+"
}
```
```bash
sudo systemctl restart multipathd
```

**0.4 ตั้ง SSH key จาก master ไป worker** เพื่อให้ `prepull-images.sh` ส่งไฟล์ได้โดยไม่ต้องใส่รหัสผ่าน (รันบน master)
```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
ssh-copy-id root@172.19.10.63
ssh-copy-id root@172.19.10.64
ssh root@172.19.10.63 hostname && ssh root@172.19.10.64 hostname   # ต้องไม่ถามรหัสผ่าน
```

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master

รันบนเครื่อง local ที่ root ของ repo
```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/longhorn /root/K8S-Stackable/scripts'
scp platform/longhorn/values.yaml   root@172.19.10.62:/root/K8S-Stackable/longhorn/values.yaml
scp scripts/prepull-images.sh       root@172.19.10.62:/root/K8S-Stackable/scripts/
ssh root@172.19.10.62 'chmod +x /root/K8S-Stackable/scripts/prepull-images.sh'
```

---

## ขั้นที่ 2: ดึง image ล่วงหน้า (ประมาณ 1 ชั่วโมง)

**2.1 ดาวน์โหลดรายชื่อ image** (รันบน master)

ใช้รายชื่อทางการที่ Longhorn แนบมากับ release **ห้ามใช้ `helm template | grep image:`** เพราะ Longhorn ส่งชื่อ image ของ engine, instance-manager และ CSI ผ่าน argument และ environment variable ไม่ได้อยู่ในบรรทัด `image:` ทำให้ได้รายชื่อไม่ครบ
```bash
cd /root/K8S-Stackable/longhorn
curl -fsSL https://github.com/longhorn/longhorn/releases/download/v1.12.1/longhorn-images.txt -o images.txt
cat images.txt
grep -c . images.txt                          # ต้องได้ 14
```

**2.2 ดึง image บน master แล้วส่งไป worker**

รันด้วย `nohup` เพื่อให้ทำงานต่อได้แม้ SSH หลุด
```bash
cd /root/K8S-Stackable/longhorn
nohup ../scripts/prepull-images.sh images.txt > prepull.log 2>&1 &
tail -f prepull.log                           # กด Ctrl+C เพื่อออก (script ยังทำงานต่อเบื้องหลัง)
```

ความหมายของข้อความใน log
| ข้อความ | ความหมาย |
|---|---|
| `HAVE  <image>` | มี image นี้บน master อยู่แล้ว ข้าม |
| `OK    <image>` | ดึงสำเร็จ |
| `RETRY n <image>` | connection หลุด กำลังลองใหม่ (สูงสุด 15 ครั้ง) |
| `FAILED <image>` | ลองครบ 15 ครั้งแล้วยังไม่สำเร็จ script จะหยุดและไม่ส่งไฟล์ไป worker |
| `=== ส่งไป <ip>` + `imported` | ส่งไฟล์และ import บน worker สำเร็จ |
| `=== เสร็จ` | เสร็จทุกขั้น |

ระหว่างรอ ดูว่ากำลังดาวน์โหลดอยู่จริงไหมด้วยคำสั่งนี้ (ตัวเลข byte ต้องเพิ่มขึ้นเรื่อยๆ)
```bash
watch -n 10 'ctr -n k8s.io content active'
```

**2.3 ตรวจว่าทุก node มี image ครบ**
```bash
for h in 172.19.10.62 172.19.10.63 172.19.10.64; do
  echo "$h: $(ssh root@$h 'crictl images | grep -c longhornio') / 14"
done
```

---

## ขั้นที่ 3: ติดตั้ง Longhorn (รันบน master)

```bash
cd /root/K8S-Stackable/longhorn
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn \
  -n longhorn-system --create-namespace \
  --version 1.12.1 \
  -f values.yaml

kubectl -n longhorn-system get pods -w        # รอให้ทุก pod เป็น Running แล้วกด Ctrl+C
```

เมื่อ image ครบทุก node แล้ว ทุก pod ควรเป็น `Running` ภายในประมาณ 2–3 นาที โดย `longhorn-manager` จะขึ้นก่อน แล้วค่อยสร้าง `instance-manager`, `engine-image`, `csi-*` และ `longhorn-csi-plugin` ตามมา

---

## ขั้นที่ 4: ตรวจผล

```bash
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get nodes.longhorn.io
kubectl get sc
```

ผลที่ถูกต้อง
```
NAME      READY   ALLOWSCHEDULING   SCHEDULABLE
master    True    true              True
worker1   True    true              True
worker2   True    true              True

NAME                 PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE
longhorn (default)   driver.longhorn.io   Delete          Immediate
longhorn-static      driver.longhorn.io   Delete          Immediate
```

`longhorn-static` เป็น StorageClass ที่ Longhorn สร้างเองไว้ใช้กับ volume ที่สร้างผ่าน UI ไม่ต้องลบ

---

## ขั้นที่ 5: ทดสอบสร้าง volume

paste ทั้งก้อนได้ เพราะมีคำสั่ง `wait` รอแต่ละขั้นให้เสร็จก่อน
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lh-test }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: lh-test }
spec:
  containers:
    - name: t
      image: busybox:1.36
      command: ["sh", "-c", "echo ok > /data/f && cat /data/f && sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: lh-test } }]
EOF

kubectl wait pvc/lh-test --for=jsonpath='{.status.phase}'=Bound --timeout=120s
kubectl wait pod/lh-test --for=condition=Ready --timeout=300s
kubectl logs lh-test                          # ต้องได้: ok
```

ผ่านแล้วลบทิ้ง
```bash
kubectl delete pod lh-test && kubectl delete pvc lh-test
```

---

## ขั้นที่ 6: เปิดหน้า UI

ยังไม่มี Ingress จึงเข้าผ่าน SSH tunnel + port-forward (รันบนเครื่อง local)
```bash
ssh -L 8080:localhost:8080 root@172.19.10.62 \
  'kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80'
```
เปิด http://localhost:8080 แล้ว Dashboard ควรแสดงพื้นที่ที่จัดสรรได้ประมาณ 80 GB ต่อ node

> ⚠️ **UI ของ Longhorn ไม่มีระบบ login** ใครเข้าถึง URL ได้ก็ลบ volume ได้ ห้ามเปิดผ่าน Service ประเภท `LoadBalancer` หรือ Ingress ที่ไม่มี auth
> หลังติดตั้ง Traefik ให้เปิดผ่าน Ingress + Basic Auth และหลังติดตั้ง Keycloak ให้เปลี่ยนเป็น SSO ผ่าน oauth2-proxy

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| Pod ค้าง `ContainerCreating` และ event เป็น `Pulling image` นานมาก | Node ยังไม่มี image และกำลังดึงจาก internet | ทำขั้นที่ 2 ให้ครบ แล้วตรวจตามขั้นที่ 2.3 |
| Event: `failed to copy: ... connection reset by peer` | Connection ไป Docker Hub ถูกตัดกลางทาง | ใช้ `prepull-images.sh` ซึ่ง retry ให้เอง |
| Pod ยังค้าง `ImagePullBackOff` ทั้งที่ import image แล้ว | kubelet ยังรอรอบ retry ถัดไป (นานสุด 5 นาที) | `kubectl -n longhorn-system delete pod --field-selector=status.phase=Pending` |
| Event: `MountVolume.SetUp failed ... failed to sync configmap cache` ตอนเพิ่งสร้าง pod | เกิดชั่วคราวตอนเริ่มต้น | ไม่ต้องทำอะไร หายไปเอง |
| `nodes.longhorn.io` ไม่ขึ้นครบ 3 node | ติด taint บน master หรือ `longhorn-manager` บน node นั้นไม่ Running | ทำขั้น 0.1 และดู `kubectl -n longhorn-system describe pod -l app=longhorn-manager` |
| PVC ค้าง `Pending` หรือ volume ไม่ attach | `iscsid` ไม่ได้รัน หรือ `multipathd` แย่ง device | ทำขั้น 0.2–0.3 |
| `crictl rmi --prune` ขึ้น `DeadlineExceeded` | Timeout ค่าเริ่มต้นของ crictl แค่ 2 วินาที ลบ image ใหญ่ไม่ทัน | `crictl --timeout 10m rmi --prune` |

---

## ถอนการติดตั้ง

ต้องลบ PVC ที่ใช้ Longhorn ทั้งหมดก่อน แล้วค่อยถอน Longhorn
```bash
kubectl get pvc -A | grep longhorn            # ต้องไม่เหลือ
kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
  --type merge -p '{"value":"true"}'
helm uninstall longhorn -n longhorn-system --wait --timeout 10m
kubectl delete ns longhorn-system

# บนทุก node: ลบข้อมูลที่เหลืออยู่
sudo rm -rf /var/lib/longhorn/*
```
