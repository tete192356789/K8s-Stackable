# 08 — ติดตั้ง Argo CD 3.5.3 (PoC)

ตัวสุดท้ายของ **ชั้น 0 (bootstrap)** ที่ติดตั้งด้วย `helm` เอง — ตั้งแต่ขั้น 09 เป็นต้นไป service ทั้งหมดติดตั้งผ่าน GitOps (Argo CD อ่าน repo บน GitHub แล้ว sync เข้า cluster)

| รายการ | ค่า |
|---|---|
| Argo CD | v3.5.3 (Helm chart `argo/argo-cd` 10.9.4) — รองรับ Kubernetes 1.33–1.36 |
| รูปแบบ | minimal: ไม่มี HA, ปิด dex / notifications / ApplicationSet controller |
| UI | `https://argocd.172.19.10.62.sslip.io` (TLS จบที่ Traefik, `server.insecure: true`) |
| Git repo ที่ Argo CD อ่าน | `https://github.com/tete192356789/K8s-Stackable.git` (public — ไม่ต้องตั้ง credential) |
| Helm repo เพิ่มเติม | `oci.stackable.tech/sdp-charts` (OCI) สำหรับ Stackable operators |
| ไฟล์ใน repo | `platform/argocd/values.yaml`, `platform/argocd/ingress.yaml` |
| ต้องติดตั้งก่อน | [03-traefik.md](03-traefik.md), [04-crds-cert-manager.md](04-crds-cert-manager.md) |

```
ชั้น 0 (helm เอง):  Longhorn, MetalLB, Traefik, cert-manager, CNPG operator, SeaweedFS, OpenBao, ESO, Argo CD
ชั้น 1 (GitOps):    PostgreSQL (CNPG Cluster), Stackable operators, Hive, Trino, ...   ← Argo CD sync จาก gitops/
```

> ชั้น 0 ยังไม่ย้ายเข้า Argo CD เพราะ Argo CD เองพึ่งของเหล่านี้ และบาง chart เสียหายถ้าให้ Argo CD render ใหม่
> (เช่น SeaweedFS สุ่ม S3 key ด้วย `lookup` + Helm hook — Argo CD ไม่รองรับ `lookup` จะสร้าง key ใหม่ทับของเดิม)

---

## ค่าที่ตั้งใน `values.yaml`

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| `configs.params.server.insecure` | `true` | TLS จบที่ Traefik |
| `configs.cm.resource.customizations.health.argoproj.io_Application` | Lua health check | ให้ Application มีสถานะ health → app-of-apps รอ wave ก่อนหน้า `Healthy` ก่อน sync wave ถัดไป (Argo CD ไม่เปิดให้โดยค่าเริ่มต้น) |
| `configs.repositories.stackable-oci` | `oci.stackable.tech/sdp-charts`, `enableOCI: "true"` | ให้ Argo CD ดึง Helm chart ของ Stackable จาก OCI registry |
| `dex.enabled`, `notifications.enabled` | `false` | ไม่ใช้ใน PoC (ภายหลังต่อ Keycloak ด้วย OIDC โดยตรง) |
| `applicationSet.replicas` | `0` | ไม่ใช้ ApplicationSet ประหยัด RAM |
| `resources` | controller 512Mi, repo-server 512Mi, server 256Mi, redis 128Mi (limit) | PoC มี RAM น้อย |

---

## ขั้นที่ 1: เอา repo ขึ้น master (รันบน master)

ตั้งแต่ขั้นนี้ใช้ `git` แทน `scp` — clone ไว้ directory แยกจาก `/root/K8S-Stackable` (ที่มี `init-keys.json` และไฟล์ที่สร้างระหว่างติดตั้ง)

```bash
git clone https://github.com/tete192356789/K8s-Stackable.git /root/K8s-Stackable-repo
cd /root/K8s-Stackable-repo && git log --oneline -3
# ครั้งถัดไป: cd /root/K8s-Stackable-repo && git pull
```

> Argo CD อ่าน repo จาก **GitHub** — ไฟล์ที่แก้บน Mac ต้อง `git push` ก่อน Argo CD ถึงจะเห็น

---

## ขั้นที่ 2: ดึง image ล่วงหน้า (รันบน master)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

cd /root/K8s-Stackable-repo/platform/argocd
helm template argocd argo/argo-cd -n argocd --version 10.9.4 -f values.yaml > /tmp/argocd-rendered.yaml
grep -E '^kind: (Deployment|StatefulSet)' /tmp/argocd-rendered.yaml | sort | uniq -c     # ไม่ควรมี dex / notifications
grep -oE 'image: *"?[^" ]+' /tmp/argocd-rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u > /tmp/argocd-images.txt
cat /tmp/argocd-images.txt                                                                # argocd v3.5.3 + redis
/root/K8S-Stackable/scripts/prepull-images.sh /tmp/argocd-images.txt 2>&1 | tee /tmp/argocd-prepull.log
```

> ใช้ `scripts/prepull-images.sh` ตัวล่าสุดจาก repo ก็ได้: `/root/K8s-Stackable-repo/scripts/prepull-images.sh`

---

## ขั้นที่ 3: ติดตั้ง (รันบน master)

```bash
cd /root/K8s-Stackable-repo/platform/argocd
helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.9.4 -f values.yaml
kubectl -n argocd wait pod --all --for=condition=Ready --timeout=300s
kubectl -n argocd get pods
kubectl apply -f ingress.yaml
```

ต้องมี pod: `argocd-application-controller-0`, `argocd-repo-server`, `argocd-server`, `argocd-redis` เป็น `Running`

---

## ขั้นที่ 4: Login

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

เปิด `https://argocd.172.19.10.62.sslip.io` → user `admin` + รหัสจากคำสั่งข้างบน
หลัง login: **User Info → Update Password** เปลี่ยนรหัส แล้วลบ secret รหัสเริ่มต้น

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

> เก็บรหัส admin ใหม่ไว้ใน OpenBao ได้: `bao kv put secret/argocd/admin password='...'` (ใช้เป็น break-glass หลังต่อ Keycloak)

---

## ขั้นที่ 5: ตรวจ repository ของ Stackable (รันบน master)

```bash
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository \
  -o custom-columns='NAME:.metadata.name,URL:.data.url' | while read n u; do echo "$n $(echo "$u" | base64 -d 2>/dev/null)"; done
```

ต้องเห็น `oci.stackable.tech/sdp-charts` — หรือดูใน UI: **Settings → Repositories** (สถานะ `Successful`)

---

## ปัญหาที่พบบ่อย

| อาการ | สาเหตุ | วิธีแก้ |
|---|---|---|
| UI ขึ้น redirect loop / `ERR_TOO_MANY_REDIRECTS` | `server.insecure` ไม่ถูกใช้ (argocd-server พยายาม redirect ไป HTTPS) | `kubectl -n argocd get cm argocd-cmd-params-cm -o yaml \| grep insecure` ต้องเป็น `"true"` แล้ว `kubectl -n argocd rollout restart deploy argocd-server` |
| Repository ของ Stackable `Failed` | oci.stackable.tech ตอบช้า / timeout | กด Connection → Refresh ใน UI หรือรอ Argo CD retry |
| `helm install` error ว่ามี CRD / ClusterRole ของ Argo อยู่แล้ว | Argo CD / Argo Workflows ตัวเก่าจาก stack เดิมทิ้งไว้ | `kubectl get crd,clusterrole,clusterrolebinding -o name \| grep -i argo` แล้วลบของเก่า |

ดู log

```bash
kubectl -n argocd logs deploy/argocd-server --tail=50
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
kubectl -n argocd logs statefulset/argocd-application-controller --tail=50
```

---

## ถอนการติดตั้ง

ลบ Application ทั้งหมดก่อน (Application ใน repo นี้ไม่มี finalizer → resource ของ service **ไม่ถูกลบ** ตาม)

```bash
kubectl -n argocd delete applications --all
kubectl delete -f /root/K8s-Stackable-repo/platform/argocd/ingress.yaml
helm uninstall argocd -n argocd
kubectl delete ns argocd
```
