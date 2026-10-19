#!/usr/bin/env bash
# สร้าง registry endpoint + project แบบ proxy cache ใน Harbor (รันครั้งเดียวบน master — รันซ้ำได้ ตัวที่มีแล้วจะข้าม)
#
#   project (public)  →  upstream
#   dockerhub         →  docker.io            (type docker-hub)
#   quay              →  quay.io              (type docker-registry — chart ไม่อนุญาต type quay)
#   ghcr              →  ghcr.io              (type github-ghcr)
#   k8s               →  registry.k8s.io      (type docker-registry)
#   stackable         →  oci.stackable.tech   (type docker-registry)
#
# ใช้: HARBOR_ADMIN_PASSWORD=... ./harbor-proxy-cache.sh
#      (password: bao kv get -field=admin_password secret/harbor/core)
set -euo pipefail

HARBOR=${HARBOR:-https://harbor.172.19.10.62.sslip.io}
CA=${CA:-/root/K8S-Stackable/platform-ca.crt}
: "${HARBOR_ADMIN_PASSWORD:?ตั้ง HARBOR_ADMIN_PASSWORD ก่อน}"

api() {   # api METHOD PATH [JSON]
  curl -sS --cacert "$CA" -u "admin:${HARBOR_ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
       -X "$1" "${HARBOR}/api/v2.0$2" ${3:+-d "$3"} -w '\n%{http_code}'
}

curl -sf --cacert "$CA" "${HARBOR}/api/v2.0/ping" >/dev/null || { echo "เข้า ${HARBOR} ไม่ได้"; exit 1; }

while read -r name type url; do
  [ -z "$name" ] && continue
  echo "== $name ($url)"

  reg_id=$(api GET "/registries?q=name%3D${name}" | head -n -1 | jq -r '.[0].id // empty')
  if [ -z "$reg_id" ]; then
    out=$(api POST /registries "{\"name\":\"${name}\",\"type\":\"${type}\",\"url\":\"${url}\",\"insecure\":false}")
    [ "$(tail -n1 <<<"$out")" = 201 ] || { echo "  สร้าง endpoint ไม่ได้: $out"; exit 1; }
    reg_id=$(api GET "/registries?q=name%3D${name}" | head -n -1 | jq -r '.[0].id')
    echo "  endpoint id=${reg_id} สร้างแล้ว"
  else
    echo "  endpoint id=${reg_id} มีอยู่แล้ว"
  fi

  # ใช้ GET (HEAD ทำให้ curl รอ body ที่ไม่มาแล้วล้ม — error 18)
  exists=$(api GET "/projects?name=${name}" | head -n -1 | jq -r --arg n "$name" '[.[]? | select(.name == $n)] | length')
  if [ "$exists" = 0 ]; then
    out=$(api POST /projects "{\"project_name\":\"${name}\",\"registry_id\":${reg_id},\"metadata\":{\"public\":\"true\"}}")
    [ "$(tail -n1 <<<"$out")" = 201 ] || { echo "  สร้าง project ไม่ได้: $out"; exit 1; }
    echo "  project ${name} (proxy cache, public) สร้างแล้ว"
  else
    echo "  project ${name} มีอยู่แล้ว"
  fi
done <<'EOF'
dockerhub docker-hub https://hub.docker.com
quay docker-registry https://quay.io
ghcr github-ghcr https://ghcr.io
k8s docker-registry https://registry.k8s.io
stackable docker-registry https://oci.stackable.tech
EOF

echo "=== เสร็จ — ดูใน UI: Administration → Registries / Projects"
