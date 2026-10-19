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
SECTION='[plugins."io.containerd.cri.v1.images".registry]'
grep -qE '^[[:space:]]*version[[:space:]]*=[[:space:]]*3' "$CONFIG" || {
  echo "$CONFIG ไม่ใช่ config version 3 — script นี้รองรับแค่ version 3 (ส่ง head -5 $CONFIG มาตรวจ)"; exit 1; }
if grep -qE "^[[:space:]]*config_path[[:space:]]*=[[:space:]]*['\"]${CERTS_D}['\"]" "$CONFIG"; then
  echo "config_path ตั้งไว้แล้ว — ไม่ต้อง restart containerd"
  exit 0
fi
cp -a "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
if grep -qF "$SECTION" "$CONFIG"; then
  # มี section อยู่แล้ว: แก้ config_path บรรทัดแรกหลัง section (ถ้ามี) หรือเพิ่มต่อจากหัว section
  awk -v sec="$SECTION" -v path="$CERTS_D" '
    { t = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t) }
    t == sec { print; insec=1; next }
    insec && /^[[:space:]]*\[/ { if (!done) { print "      config_path = \"" path "\""; done=1 } insec=0 }
    insec && /^[[:space:]]*config_path[[:space:]]*=/ { sub(/=.*/, "= \"" path "\""); done=1 }
    { print }
    END { if (insec && !done) print "      config_path = \"" path "\"" }
  ' "$CONFIG" > "${CONFIG}.new" && mv "${CONFIG}.new" "$CONFIG"
else
  printf '\n%s\n  config_path = "%s"\n' "$SECTION" "$CERTS_D" >> "$CONFIG"
fi
# section หลักไม่มี (มีแค่ sub-section) → เพิ่ม section ใหม่ท้ายไฟล์
grep -qE "^[[:space:]]*config_path[[:space:]]*=[[:space:]]*\"${CERTS_D}\"" "$CONFIG" || \
  printf '\n%s\n  config_path = "%s"\n' "$SECTION" "$CERTS_D" >> "$CONFIG"
grep -n -A1 -F "$SECTION" "$CONFIG"
containerd config dump >/dev/null || { echo "config.toml ผิด — คืนค่าจาก ${CONFIG}.bak.*"; exit 1; }
systemctl restart containerd
sleep 3
systemctl is-active containerd
echo "=== เสร็จ — ทดสอบ: crictl pull docker.io/library/busybox:1.36"
