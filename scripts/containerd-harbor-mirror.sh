#!/usr/bin/env bash
# ตั้งให้ containerd บน node นี้ดึง image ผ่าน Harbor (proxy cache) — รันบนทุก node (ทีละเครื่อง)
#
#   docker.io → harbor/dockerhub   quay.io → harbor/quay   ghcr.io → harbor/ghcr
#   registry.k8s.io → harbor/k8s   oci.stackable.tech → harbor/stackable
#
# - ถ้า Harbor ล่ม containerd ดึงจาก upstream ตรงเอง (server = ... ใน hosts.toml) → ไม่ทำให้ cluster ดึง image ไม่ได้
# - containerd 2.1 ไม่ได้ตั้ง config_path เป็นค่าเริ่มต้น (มาใน 2.2) → script ตั้งให้แล้ว restart containerd
#   (restart containerd ไม่ฆ่า container ที่รันอยู่)
# - ctr (prepull-images.sh) ไม่อ่าน hosts.toml — มีผลกับ kubelet / crictl เท่านั้น
#
# ใช้: sudo ./containerd-harbor-mirror.sh /path/to/platform-ca.crt
#      ถอน:  sudo ./containerd-harbor-mirror.sh --remove
set -euo pipefail

HARBOR=harbor.172.19.10.62.sslip.io
CERTS_D=/etc/containerd/certs.d
CONFIG=/etc/containerd/config.toml

declare -A MIRRORS=(
  [docker.io]="https://registry-1.docker.io dockerhub"
  [quay.io]="https://quay.io quay"
  [ghcr.io]="https://ghcr.io ghcr"
  [registry.k8s.io]="https://registry.k8s.io k8s"
  [oci.stackable.tech]="https://oci.stackable.tech stackable"
)

if [ "${1:-}" = "--remove" ]; then
  for reg in "${!MIRRORS[@]}"; do rm -f "${CERTS_D}/${reg}/hosts.toml"; done
  echo "ลบ hosts.toml แล้ว — containerd ดึงจาก upstream ตรง (ไม่ต้อง restart)"
  exit 0
fi

CA_SRC=${1:?ระบุไฟล์ CA เช่น /root/K8S-Stackable/platform-ca.crt}
[ -s "$CA_SRC" ] || { echo "ไม่พบ $CA_SRC"; exit 1; }

mkdir -p "$CERTS_D"
install -m 0644 "$CA_SRC" "${CERTS_D}/platform-ca.crt"

for reg in "${!MIRRORS[@]}"; do
  read -r upstream project <<<"${MIRRORS[$reg]}"
  mkdir -p "${CERTS_D}/${reg}"
  cat > "${CERTS_D}/${reg}/hosts.toml" <<EOF
# สร้างโดย containerd-harbor-mirror.sh — ดึงผ่าน Harbor ก่อน, ถ้าไม่ได้ใช้ upstream
server = "${upstream}"

[host."https://${HARBOR}/v2/${project}"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "${CERTS_D}/platform-ca.crt"
EOF
  echo "  ${reg} → https://${HARBOR}/v2/${project}"
done

# config_path ของ CRI (containerd 2.x, config version 3)
# containerd 2 เขียนชื่อ section ด้วย ' (เช่น [plugins.'io.containerd.cri.v1.images'.registry]) — รองรับทั้ง ' และ "
SECTION_RE="^[[:space:]]*\\[plugins\\.['\"]io\\.containerd\\.cri\\.v1\\.images['\"]\\.registry\\][[:space:]]*$"
grep -qE '^[[:space:]]*version[[:space:]]*=[[:space:]]*3' "$CONFIG" || {
  echo "$CONFIG ไม่ใช่ config version 3 — script นี้รองรับแค่ version 3 (ส่ง head -5 $CONFIG มาตรวจ)"; exit 1; }
if grep -A3 -E "$SECTION_RE" "$CONFIG" | grep -qE "^[[:space:]]*config_path[[:space:]]*=[[:space:]]*['\"]${CERTS_D}['\"]"; then
  echo "config_path ตั้งไว้แล้ว — ไม่ต้อง restart containerd"
  exit 0
fi
# ตรวจก่อน backup — ไม่ให้ไฟล์ที่เสียอยู่แล้วกลายเป็น backup ล่าสุด
if [ "$(grep -cE "$SECTION_RE" "$CONFIG")" -gt 1 ]; then
  echo "พบ section registry มากกว่า 1 อันใน $CONFIG — แก้ด้วยมือก่อน (ดู docs/install/17-harbor.md)"; exit 1
fi
containerd config dump >/dev/null || { echo "$CONFIG เสียอยู่แล้วก่อนแก้ — ไม่ทำต่อ"; exit 1; }
BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$CONFIG" "$BACKUP"
if grep -qE "$SECTION_RE" "$CONFIG"; then
  # มี section อยู่แล้ว: แทน config_path เดิม หรือเพิ่มบรรทัดใต้หัว section
  RE="$SECTION_RE" awk -v path="$CERTS_D" '
    $0 ~ ENVIRON["RE"] { print; insec=1; next }
    insec && /^[[:space:]]*\[/ { if (!done) { print "  config_path = \"" path "\""; done=1 } insec=0 }
    insec && /^[[:space:]]*config_path[[:space:]]*=/ { sub(/=.*/, "= \"" path "\""); done=1 }
    { print }
    END { if (insec && !done) print "  config_path = \"" path "\"" }
  ' "$CONFIG" > "${CONFIG}.new" && mv "${CONFIG}.new" "$CONFIG"
else
  printf '\n%s\n  config_path = "%s"\n' '[plugins."io.containerd.cri.v1.images".registry]' "$CERTS_D" >> "$CONFIG"
fi
grep -n -A2 -E "$SECTION_RE" "$CONFIG"
containerd config dump >/dev/null || { cp -a "$BACKUP" "$CONFIG"; echo "config.toml ผิด — คืนค่าจาก $BACKUP แล้ว (ไม่ได้ restart containerd)"; exit 1; }
systemctl restart containerd
sleep 3
systemctl is-active containerd
echo "=== เสร็จ — ทดสอบ: crictl pull docker.io/library/busybox:1.36"
