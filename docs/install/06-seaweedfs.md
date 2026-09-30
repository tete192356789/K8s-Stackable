# 06 — ติดตั้ง SeaweedFS 4.47 (PoC)

Object storage (S3) ของ data platform — เก็บตาราง Iceberg (Trino / Hive), log ของ Loki, log ของ Airflow และ backup

| รายการ | ค่า |
|---|---|
| SeaweedFS | 4.47 (Helm chart `seaweedfs/seaweedfs` 4.47.0) — ตอนเขียนเอกสารมี 4.48 แล้ว แต่ values ตรวจกับ 4.47 |
| Component | master ×1, volume ×3 (node ละ 1 ตัว), filer ×1 พร้อม S3 gateway ในตัว |
| Replication | `001` — เก็บ 2 ชุดบนคนละ volume server (node ล่ม 1 ตัวข้อมูลไม่หาย) |
| ข้อมูล object | `/data/seaweedfs` บน root filesystem ของทุก node (hostPath) สูงสุด ~90 GB ต่อ node |
| Metadata | master 1 GB + filer 5 GB บน Longhorn |
| S3 endpoint | ใน cluster: `http://seaweedfs-s3.seaweedfs.svc:8333` / นอก cluster: `https://s3.172.19.10.62.sslip.io` |
| Bucket | `warehouse`, `loki`, `airflow-logs`, `backups` (สร้างตอนติดตั้ง) |
| ไฟล์ใน repo | `platform/seaweedfs/values.yaml`, `platform/seaweedfs/s3-ingress.yaml` |
| ไฟล์บน master | `/root/K8S-Stackable/seaweedfs/` |
| ต้องติดตั้งก่อน | [01-longhorn.md](01-longhorn.md), [03-traefik.md](03-traefik.md), [04-crds-cert-manager.md](04-crds-cert-manager.md) |

**ทำไมข้อมูล object ไม่เก็บบน Longhorn** — SeaweedFS replicate ข้อมูลเองอยู่แล้ว (2 ชุด) ถ้าวางบน Longhorn (อีก 2 ชุด) ข้อมูล 1 GB จะกิน disk 4 GB จึงให้ volume server เขียนลง disk ของ node ตรง ๆ ส่วน metadata ของ master/filer มีขนาดเล็กและต้องย้าย node ได้ จึงไว้บน Longhorn

**การแบ่ง disk ต่อ node (~270 GB)**
```
/var/lib/longhorn   → Longhorn สูงสุด ~80 GB   (01-longhorn)
/data/seaweedfs     → SeaweedFS สูงสุด ~90 GB  (maxVolumes 90 × 1 GB)
ที่เหลือ             → OS, container image, log
```

---

## ค่าที่ตั้งใน `values.yaml`

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `global.replicationPlacement`, `master.defaultReplication`, `filer.defaultReplicaPlacement` | `"001"` | 2 ชุดบนคนละ server |
| `master.volumeSizeLimitMB` | `1024` | volume ไฟล์ละ 1 GB (ค่าเริ่มต้นของ SeaweedFS คือ 30 GB ใหญ่เกินไปสำหรับ disk ขนาดนี้) |
| `volume.replicas` | `3` | node ละ 1 ตัว (chart ตั้ง podAntiAffinity ให้แล้ว) |
| `volume.dataDirs[0].maxVolumes` | `90` | จำกัดพื้นที่ไม่เกิน ~90 GB ต่อ node |
| `volume.minFreeSpacePercent` | `10` | หยุดเขียนถ้า disk ว่างเหลือต่ำกว่า 10% กัน node เต็ม |
| `master.data`, `filer.data` | PVC บน `longhorn` | metadata ย้าย node ได้ |
| `*.logs.type` | `emptyDir` | ไม่สร้าง directory log บน node |
| `filer.s3.enabled` | `true` | รัน S3 gateway ในตัว filer ประหยัด RAM กว่าแยก deployment |
| `filer.s3.enableAuth` | `true` | chart สร้าง secret `seaweedfs-s3-secret` (key ของ admin และ read-only) ให้อัตโนมัติ |
| `filer.s3.createBuckets` | 4 bucket | สร้าง bucket ที่ service อื่นต้องใช้ตั้งแต่ติดตั้ง |
| `resources` | master 256Mi, volume 512Mi ×3, filer 512Mi (limit) | รวม limit ~2.3 GB |

---

## ขั้นที่ 0: เตรียม directory บนทุก node (รันบน master)

Rocky Linux เปิด SELinux ไว้ ถ้าเป็น `Enforcing` container จะเขียน hostPath ไม่ได้ ต้องติด label `container_file_t` ให้ directory ก่อน

```bash
for h in 172.19.10.62 172.19.10.63 172.19.10.64; do
  echo "== $h"
  ssh root@$h '
    getenforce
    mkdir -p /data/seaweedfs
    if [ "$(getenforce)" != "Disabled" ]; then
      dnf install -y -q policycoreutils-python-utils
      semanage fcontext -a -t container_file_t "/data/seaweedfs(/.*)?" 2>/dev/null || true
      restorecon -Rv /data/seaweedfs
    fi
    ls -Zd /data/seaweedfs; df -h /data/seaweedfs | tail -1'
done
```

ถ้ายังไม่ได้ทำ `ssh-copy-id root@172.19.10.62` คำสั่งนี้จะถามรหัสผ่านของ master ครั้งหนึ่ง

---

## ขั้นที่ 1: Copy ไฟล์ขึ้น master (รันบนเครื่อง local ที่ root ของ repo)

```bash
ssh root@172.19.10.62 'mkdir -p /root/K8S-Stackable/seaweedfs'
scp platform/seaweedfs/values.yaml platform/seaweedfs/s3-ingress.yaml root@172.19.10.62:/root/K8S-Stackable/seaweedfs/
```

---

## ขั้นที่ 2: ตรวจ values และดึง image ล่วงหน้า (รันบน master)

```bash
cd /root/K8S-Stackable/seaweedfs
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update seaweedfs

helm template seaweedfs seaweedfs/seaweedfs -n seaweedfs --version 4.47.0 -f values.yaml > rendered.yaml
grep -E '^kind: (StatefulSet|Deployment|Job)' rendered.yaml | sort | uniq -c   # ต้องมี StatefulSet 3 ตัว (master, volume, filer)
grep -E 'defaultReplication|replication=|volumeSizeLimitMB|-max=' rendered.yaml | head
grep -oE 'image: *"?[^" ]+' rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > images.txt
cat images.txt                     # ควรมีแค่ chrislusf/seaweedfs:4.47

../scripts/prepull-images.sh images.txt 2>&1 | tee prepull.log
```

---

## ขั้นที่ 3: ติดตั้ง (รันบน master)

```bash
cd /root/K8S-Stackable/seaweedfs
helm install seaweedfs seaweedfs/seaweedfs \
  -n seaweedfs --create-namespace \
  --version 4.47.0 \
  -f values.yaml

kubectl -n seaweedfs get pods -o wide -w     # รอให้ทุก pod Running แล้ว Ctrl+C
```

ผลที่ถูกต้อง: `seaweedfs-master-0`, `seaweedfs-filer-0` และ `seaweedfs-volume-0/1/2` เป็น `Running` โดย volume อยู่คนละ node กัน, Job สร้าง bucket เป็น `Completed`

ตรวจสถานะภายใน

```bash
kubectl -n seaweedfs get svc,pvc
kubectl -n seaweedfs exec seaweedfs-master-0 -- sh -c 'echo "volume.list" | weed shell -master=localhost:9333' | head -20
kubectl -n seaweedfs exec seaweedfs-master-0 -- sh -c 'echo "s3.bucket.list" | weed shell -master=localhost:9333'
```

ต้องเห็น volume server 3 ตัว และ bucket ครบ 4 ตัว

---

## ขั้นที่ 4: เปิด S3 ผ่าน Traefik (รันบน master)

```bash
kubectl apply -f /root/K8S-Stackable/seaweedfs/s3-ingress.yaml
curl -s -o /dev/null -w '%{http_code}\n' --cacert /root/K8S-Stackable/platform-ca.crt https://s3.172.19.10.62.sslip.io/
```

ต้องได้ `403` (S3 ตอบกลับว่าไม่ได้ส่ง key มา — แปลว่า routing และ certificate ถูกต้อง)

---

## ขั้นที่ 5: ดู S3 access key (รันบน master)

```bash
kubectl -n seaweedfs get secret seaweedfs-s3-secret -o json \
  | jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"'
```

| Key | ใช้กับ |
|---|---|
| `admin_access_key_id` / `admin_secret_access_key` | อ่าน/เขียนทุก bucket — Trino, Hive, Loki, Airflow, Barman |
| `read_access_key_id` / `read_secret_access_key` | อ่านอย่างเดียว |

> Secret นี้มี annotation `helm.sh/resource-policy: keep` — ไม่ถูกลบตอน `helm uninstall` และ key จะไม่เปลี่ยนตอน `helm upgrade`
> ภายหลังจะย้าย key ไปเก็บใน OpenBao แล้วให้ External Secrets ส่งให้ service อื่น

---

## ขั้นที่ 6: ทดสอบ S3 จากเครื่อง local

ใช้ AWS CLI (ถ้ายังไม่มี: `pip install awscli`) — ต้องตั้ง `AWS_CA_BUNDLE` เพราะ AWS CLI ไม่อ่าน Keychain ของ macOS

```bash
scp root@172.19.10.62:/root/K8S-Stackable/platform-ca.crt .      # ถ้ายังไม่มีไฟล์นี้ในเครื่อง

export AWS_ACCESS_KEY_ID='<admin_access_key_id>'
export AWS_SECRET_ACCESS_KEY='<admin_secret_access_key>'
export AWS_DEFAULT_REGION=us-east-1
export AWS_CA_BUNDLE="$PWD/platform-ca.crt"
aws configure set default.s3.addressing_style path                  # SeaweedFS ใช้ path-style

S3=https://s3.172.19.10.62.sslip.io
aws --endpoint-url $S3 s3 ls                                        # ต้องเห็น 4 bucket
echo "hello seaweedfs" > /tmp/sw-test.txt
aws --endpoint-url $S3 s3 cp /tmp/sw-test.txt s3://warehouse/_test/sw-test.txt
aws --endpoint-url $S3 s3 ls s3://warehouse/_test/
aws --endpoint-url $S3 s3 cp s3://warehouse/_test/sw-test.txt -     # ต้องได้: hello seaweedfs
aws --endpoint-url $S3 s3 rm s3://warehouse/_test/sw-test.txt
```

---

## ค่าที่ service อื่นใช้เชื่อมต่อ (อ้างอิง)

| ค่า | ใน cluster | นอก cluster |
|---|---|---|
| Endpoint | `http://seaweedfs-s3.seaweedfs.svc:8333` | `https://s3.172.19.10.62.sslip.io` |
| Region | `us-east-1` (SeaweedFS ไม่สนใจค่านี้ แต่ client บางตัวบังคับให้ใส่) | เหมือนกัน |
| Addressing | **path-style** (Stackable `S3Connection`: `accessStyle: Path`) | เหมือนกัน |
| TLS | ไม่ใช้ (HTTP ภายใน cluster) | HTTPS ผ่าน Traefik + internal CA |

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| `seaweedfs-volume-*` CrashLoop / log `permission denied` ที่ `/data` | SELinux ไม่ให้ container เขียน hostPath | ทำขั้นที่ 0 แล้ว `kubectl -n seaweedfs delete pod -l app.kubernetes.io/component=volume` |
| volume ขึ้นแค่ 2 ตัว อีกตัว `Pending` | podAntiAffinity ต้องการ node ละ 1 ตัว แต่ node หนึ่งรับไม่ได้ (taint / RAM ไม่พอ) | `kubectl -n seaweedfs describe pod seaweedfs-volume-2` ดู Events |
| เขียนไฟล์ไม่ได้ error `no free volumes` / `replication 001 not satisfiable` | volume server ทำงานไม่ถึง 2 ตัว | ตรวจว่า volume pod `Running` อย่างน้อย 2 ตัว |
| S3 ได้ `SignatureDoesNotMatch` | ใช้ virtual-hosted style หรือ key ผิด | ตั้ง `addressing_style path` และตรวจ key จากขั้นที่ 5 |
| AWS CLI `SSL validation failed` | ไม่ได้ตั้ง `AWS_CA_BUNDLE` | ขั้นที่ 6 |
| Job สร้าง bucket ไม่ `Completed` | filer ยังไม่พร้อมตอน Job รัน | `kubectl -n seaweedfs logs job/<ชื่อ job>` แล้วสร้างเอง: `echo "s3.bucket.create -name warehouse" \| weed shell -master=localhost:9333` (exec ใน master pod) |

ดู log

```bash
kubectl -n seaweedfs logs seaweedfs-master-0 --tail=30
kubectl -n seaweedfs logs seaweedfs-filer-0 --tail=30
kubectl -n seaweedfs logs seaweedfs-volume-0 --tail=30
```

---

## ถอนการติดตั้ง

```bash
kubectl delete -f /root/K8S-Stackable/seaweedfs/s3-ingress.yaml
helm uninstall seaweedfs -n seaweedfs
kubectl -n seaweedfs delete pvc --all
kubectl -n seaweedfs delete secret seaweedfs-s3-secret     # secret นี้ไม่ถูกลบโดย helm
kubectl delete ns seaweedfs

# บนทุก node: ลบข้อมูล object (ลบแล้วกู้คืนไม่ได้)
sudo rm -rf /data/seaweedfs/*
```
