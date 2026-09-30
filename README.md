# K8s-Stackable

PoC ของ data platform บน Kubernetes โดยใช้ [Stackable Data Platform](https://stackable.tech) — เก็บ Helm values, manifest, script และเอกสารติดตั้งทีละขั้น

**Stack เป้าหมาย:** SeaweedFS (S3) · CloudNativePG · Hive Metastore · Trino (+ Iceberg) · Airflow · Superset · Keycloak · Open Policy Agent · OpenBao + External Secrets · Prometheus / Grafana / Loki / Vector · Longhorn · Traefik

## สภาพแวดล้อม PoC

| รายการ | ค่า |
|---|---|
| Kubernetes | kubeadm 1.33 บน Rocky Linux 9.6, containerd 2.1, Calico |
| Node | 3 VM (control-plane 1 + worker 2, master รับ workload ด้วย) — 4 vCPU / 15 GB ต่อ node |
| Disk | disk เดียวต่อ node (~270 GB root) ไม่มี data disk แยก |
| IP | มีแค่ IP ของ node — MetalLB ใช้ IP ของ node เป็น LoadBalancer IP (ไม่มี failover) |
| Domain | `*.<node-ip>.sslip.io` จนกว่าจะมี DNS จริง |
| TLS | Internal CA จาก cert-manager |
| Internet | ช้า → ดึง image ครั้งเดียวบน master แล้วกระจายไป worker ด้วย `scripts/prepull-images.sh` |

> PoC นี้ออกแบบให้ใช้ resource น้อยที่สุด (1 replica, ไม่มี HA) — production ควรใช้ Kubernetes 1.36 แบบ control-plane 3 ตัว + VIP, IP ว่างสำหรับ MetalLB และ data disk แยก

## ลำดับการติดตั้ง

| # | Service | Version | เอกสาร | สถานะ |
|---|---|---|---|---|
| 1 | Longhorn | 1.12.1 | [01-longhorn.md](docs/install/01-longhorn.md) | ✅ |
| 2 | MetalLB | 0.16.1 (chart) | [02-metallb.md](docs/install/02-metallb.md) | ✅ |
| 3 | Traefik | 3.7.13 | [03-traefik.md](docs/install/03-traefik.md) | ✅ |
| 4 | Prometheus Operator CRDs + cert-manager + Internal CA | 32.0.1 / 1.21.2 | [04-crds-cert-manager.md](docs/install/04-crds-cert-manager.md) | ✅ |
| 5 | CloudNativePG Operator | 1.30.1 | [05-cnpg-operator.md](docs/install/05-cnpg-operator.md) | ✅ |
| 6 | SeaweedFS | 4.47 | [06-seaweedfs.md](docs/install/06-seaweedfs.md) | ✅ |
| 7 | OpenBao + External Secrets | 2.7.0 / 2.11.0 | [07-openbao-eso.md](docs/install/07-openbao-eso.md) | 🔄 |
| 8 | CNPG Cluster (PostgreSQL 17) | 17.11 | — | |
| 9 | Keycloak | 26.7 | — | |
| 10 | ArgoCD | 3.5 | — | |
| 11 | Prometheus + Alertmanager + Grafana, Loki, Vector | — | — | |
| 12 | Stackable operators (commons, secret, listener + products) | 26.7.0 | — | |
| 13 | OPA, Hive Metastore, Trino, Superset, Airflow | 26.7.0 | — | |

## โครงสร้าง repo

```
platform/<service>/   Helm values และ manifest ของแต่ละ service
scripts/              prepull-images.sh (ดึง image + กระจายไป worker), clean-k8s.sh (ล้าง cluster เดิม)
docs/install/         เอกสารติดตั้งทีละขั้น (ภาษาไทย)
```

บน master ใช้โครงสร้าง `/root/K8S-Stackable/<service>/` — แต่ละเอกสารบอกว่าต้อง copy ไฟล์ไหนขึ้นไปและคำสั่งไหนรันบนเครื่องใด

## สิ่งที่ไม่อยู่ใน repo

ดู `.gitignore` — unseal key / root token ของ OpenBao (`init-keys.json`), CA certificate, ผลรันจาก cluster เดิม และไฟล์ที่สร้างระหว่างติดตั้ง
Secret ทั้งหมดเก็บใน OpenBao และส่งให้ service ผ่าน External Secrets — ใน repo มีแค่ `ExternalSecret` ที่อ้างถึง path
