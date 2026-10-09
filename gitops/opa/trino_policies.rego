package trino_policies

# สิทธิ์ของ Trino — รูปแบบเดียวกับ file-based access control ของ Trino
# (https://trino.io/docs/current/security/file-system-access-control.html)
# แต่ละหมวด: ใช้ rule แรกที่ตรงกับ user/group (บนลงล่าง) — ไม่ตรงเลย = ไม่มีสิทธิ์
# ผู้ใช้ทุกคนดู / kill query ของตัวเองได้เสมอ (rule ของ Stackable)
#
# user จาก Keycloak: group มาจาก user-info-fetcher (path เช่น "/platform-admins")
# service user (static password ใน OpenBao secret/trino/users) ไม่อยู่ใน Keycloak → ใช้ rule ตามชื่อ user
#   trino-admin  admin สำหรับ CLI / script
#   superset     impersonate ผู้ใช้ที่ login Superset (ขั้นที่ 13)
#   airflow      งาน ETL — อ่าน/เขียน iceberg
#   cockpit      Stackable Cockpit — อ่านอย่างเดียว (ยังปิด impersonation เพราะ bug cockpit#371)

admins := `trino-admin`

policies := {
	"catalogs": [
		{"user": admins, "allow": "all"},
		{"group": "/platform-admins", "allow": "all"},
		{"group": "/data-engineers", "catalog": "iceberg", "allow": "all"},
		{"user": "airflow", "catalog": "iceberg", "allow": "all"},
		{"catalog": "system", "allow": "read-only"},
		{"group": "/data-engineers", "allow": "read-only"},
		{"group": "/analysts", "allow": "read-only"},
		{"user": "superset|cockpit", "allow": "read-only"},
	],
	"schemas": [
		{"user": admins, "owner": true},
		{"group": "/platform-admins", "owner": true},
		{"group": "/data-engineers", "catalog": "iceberg", "owner": true},
		{"user": "airflow", "catalog": "iceberg", "owner": true},
	],
	"tables": [
		{"user": admins, "privileges": ["SELECT", "INSERT", "DELETE", "UPDATE", "OWNERSHIP", "GRANT_SELECT"]},
		{"group": "/platform-admins", "privileges": ["SELECT", "INSERT", "DELETE", "UPDATE", "OWNERSHIP", "GRANT_SELECT"]},
		{"group": "/data-engineers", "catalog": "iceberg", "privileges": ["SELECT", "INSERT", "DELETE", "UPDATE", "OWNERSHIP"]},
		{"user": "airflow", "catalog": "iceberg", "privileges": ["SELECT", "INSERT", "DELETE", "UPDATE", "OWNERSHIP"]},
		{"privileges": ["SELECT"]},
	],
	"queries": [
		{"user": admins, "allow": ["execute", "kill", "view"]},
		{"group": "/platform-admins", "allow": ["execute", "kill", "view"]},
		{"allow": ["execute"]},
	],
	"system_information": [
		{"user": admins, "allow": ["read", "write"]},
		{"group": "/platform-admins", "allow": ["read", "write"]},
	],
	"impersonation": [
		{"original_user": "superset", "new_user": ".*", "allow": true},
		{"original_user": "cockpit", "new_user": ".*", "allow": true},
	],
}

# group จาก Keycloak ผ่าน user-info-fetcher (sidecar ใน pod OPA, port 9476)
# service user ไม่มีใน Keycloak → status ไม่ใช่ 200 → ไม่มี group (ค่าเริ่มต้น [])
# raise_error: false — UIF ล่ม / Keycloak ล่ม = ไม่มี group (rule ตามชื่อ user ยังใช้ได้) แทนที่จะ error ทั้ง query
extra_groups := groups if {
	response := http.send({
		"method": "POST",
		"url": "http://127.0.0.1:9476/user",
		"headers": {"Content-Type": "application/json"},
		"body": {"username": input.context.identity.user},
		"raise_error": false,
	})
	response.status_code == 200
	groups := response.body.groups
}
