#!/usr/bin/env bash
# prepull-images.sh — ดึง image ครั้งเดียวบน master แล้วกระจายไป worker ผ่าน LAN
# (internet ของ server ช้า ~465 KB/s และ connection ไป registry หลุดบ่อย)
#
#   ./prepull-images.sh images.txt              ดึงบน master + ส่งไป worker
#   ./prepull-images.sh images.txt --no-dist    ดึงบน master อย่างเดียว
#
# images.txt: บรรทัดละ 1 image, ขึ้นต้นด้วย # = comment
#   ใส่ registry หรือไม่ใส่ก็ได้ เช่น quay.io/metallb/controller:v0.16.0, longhornio/longhorn-manager:v1.12.1, busybox:1.36
set -uo pipefail
LIST=${1:?usage: $0 images.txt [--no-dist]}
DIST=${2:-}
WORKERS=(172.19.10.63 172.19.10.64)
TAR=/root/prepull-$(basename "$LIST" .txt).tar

# แปลงชื่อ image ให้ตรงกับชื่อที่ containerd เก็บไว้ (ใช้ตอน export)
#   busybox:1.36               → docker.io/library/busybox:1.36
#   docker.io/traefik:v3.7.13  → docker.io/library/traefik:v3.7.13   (image ทางการของ Docker Hub)
#   longhornio/x:v1            → docker.io/longhornio/x:v1
#   quay.io/metallb/x:v1       → ไม่เปลี่ยน
normalize() {
  local img=$1 first=${1%%/*} ref rest
  if [[ $img != */* ]]; then ref="docker.io/library/$img"
  elif [[ $first == *.* || $first == *:* || $first == localhost ]]; then ref="$img"
  else ref="docker.io/$img"; fi
  if [[ $ref == docker.io/* ]]; then
    rest=${ref#docker.io/}
    [[ $rest != */* ]] && ref="docker.io/library/$rest"
  fi
  echo "$ref"
}

mapfile -t IMAGES < <(grep -vE '^\s*(#|$)' "$LIST" | while read -r i; do normalize "$i"; done | sort -u)
echo "จำนวน image: ${#IMAGES[@]}"

failed=()
for img in "${IMAGES[@]}"; do
  if crictl inspecti "$img" &>/dev/null; then echo "HAVE  $img"; continue; fi
  ok=0
  for i in $(seq 1 15); do
    if crictl --timeout 30m pull "$img" >/dev/null; then ok=1; echo "OK    $img"; break; fi
    echo "RETRY $i $img"; sleep 15
  done
  (( ok )) || failed+=("$img")
done
if (( ${#failed[@]} )); then
  printf 'FAILED %s\n' "${failed[@]}"
  exit 1
fi

[[ $DIST == --no-dist ]] && { echo "=== เสร็จ (ไม่ได้ส่งไป worker)"; exit 0; }

# containerd ข้ามการดาวน์โหลด layer ที่ unpack ไว้แล้วจาก image อื่น (base layer ที่ใช้ร่วมกัน)
# image รันได้ แต่ ctr export ต้องใช้ไฟล์ layer ต้นฉบับ → เติมส่วนที่ขาด (ดาวน์โหลดเฉพาะ blob ที่ยังไม่มี)
echo "=== เติม layer ที่ขาดก่อน export"
for img in "${IMAGES[@]}"; do
  ok=0
  for i in $(seq 1 5); do
    if ctr -n k8s.io content fetch --platform linux/amd64 "$img" >/dev/null 2>&1; then ok=1; break; fi
    echo "RETRY-FETCH $i $img"; sleep 10
  done
  (( ok )) || { echo "FETCH-FAILED $img"; exit 1; }
done

echo "=== export -> $TAR"
ctr -n k8s.io images export --platform linux/amd64 "$TAR" "${IMAGES[@]}" || exit 1
for w in "${WORKERS[@]}"; do
  echo "=== ส่งไป $w"
  scp -q "$TAR" "root@$w:$TAR" &&
    ssh "root@$w" "ctr -n k8s.io images import --platform linux/amd64 $TAR >/dev/null && rm -f $TAR && echo imported"
done
rm -f "$TAR"
echo "=== เสร็จ"
