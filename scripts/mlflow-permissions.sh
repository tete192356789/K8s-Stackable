#!/usr/bin/env bash
# ตั้งสิทธิ์ราย group ใน MLflow (ปลั๊กอิน mlflow-oidc-auth) — รันครั้งเดียวหลังติดตั้ง (รันซ้ำได้ ตัวที่มีแล้วจะข้าม)
#
#   data-engineers  EDIT ทุก experiment / registered model (regex .*) → สร้างได้ (RESTRICT_RESOURCE_CREATION)
#   analysts        READ ทุก experiment / registered model
#   platform-admins admin อยู่แล้ว (OIDC_ADMIN_GROUP_NAME) — ไม่ต้องตั้ง
#   priority ต่างกัน: ปลั๊กอิน 10.0.0 ตัดสิน grant ที่ priority เท่ากันไม่แน่นอน (แก้ใน 10.1.2)
#
# ต้องมี access token ของ user ใน platform-admins:
#   login https://mlflow.172.19.10.62.sslip.io → มุมขวาบน → Tokens (หน้า /user) → สร้าง token
# ใช้: MLFLOW_ADMIN_USER=platform-admin MLFLOW_ADMIN_TOKEN=mlf_... ./mlflow-permissions.sh
set -euo pipefail

M=${MLFLOW:-https://mlflow.172.19.10.62.sslip.io}
CA=${CA:-/root/K8S-Stackable/platform-ca.crt}
: "${MLFLOW_ADMIN_USER:?ตั้ง MLFLOW_ADMIN_USER}" "${MLFLOW_ADMIN_TOKEN:?ตั้ง MLFLOW_ADMIN_TOKEN}"

api() {   # api METHOD PATH [JSON] → body + บรรทัดสุดท้ายเป็น HTTP code
  curl -sS --cacert "$CA" -u "${MLFLOW_ADMIN_USER}:${MLFLOW_ADMIN_TOKEN}" -H 'Content-Type: application/json' \
       -X "$1" "${M}$2" ${3:+-d "$3"} -w '\n%{http_code}'
}

for g in platform-admins data-engineers analysts; do
  code=$(api POST /api/2.0/mlflow/permissions/groups "{\"group_name\":\"$g\"}" | tail -n1)
  echo "group $g → HTTP $code"
done

grant() {   # grant GROUP KIND PERMISSION PRIORITY
  local g=$1 kind=$2 perm=$3 prio=$4 out code
  out=$(api GET "/api/2.0/mlflow/permissions/groups/$g/$kind")
  code=$(tail -n1 <<<"$out")
  if [ "$code" = 404 ]; then echo "  $g $kind: endpoint ไม่มีในเวอร์ชันนี้ — ข้าม"; return; fi
  if head -n -1 <<<"$out" | jq -e '.. | objects | select(.regex? == ".*")' >/dev/null 2>&1; then
    echo "  $g $kind: มี .* อยู่แล้ว — ข้าม"; return
  fi
  out=$(api POST "/api/2.0/mlflow/permissions/groups/$g/$kind" "{\"regex\":\".*\",\"priority\":$prio,\"permission\":\"$perm\"}")
  code=$(tail -n1 <<<"$out")
  [[ "$code" == 2* ]] || { echo "  $g $kind: ล้มเหลว HTTP $code — $(head -n -1 <<<"$out")"; exit 1; }
  echo "  $g $kind: .* = $perm (priority $prio)"
}

for kind in experiment-patterns registered-models-patterns; do
  grant data-engineers "$kind" EDIT 1
  grant analysts       "$kind" READ 10
done
echo "=== เสร็จ — ตรวจใน UI: มุมขวาบน → Admin → Groups"
