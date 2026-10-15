# ทดสอบระบบครบลูป (End-to-End)

สถานการณ์: **ทีมข้อมูลทำรายงานยอดขายรายวัน** — ใช้ข้อมูลตัวอย่าง `tpch.sf1.orders` (1.5 ล้านแถว) ที่มีใน Trino อยู่แล้ว
ใช้ซ้ำได้หลังอัปเกรด / เพิ่ม service — กรอกคอลัมน์ "ผล" ทุกครั้ง

```
① DAG ใน Git ──git-sync──▶ Airflow ──(KubernetesExecutor)──▶ task pod
② task pod ──Trino (user airflow) ──OPA──▶ Iceberg: iceberg.sales.orders_daily
       metadata ──▶ Hive Metastore (pg-platform)        ไฟล์ ──▶ SeaweedFS s3://warehouse (TLS ผ่าน Traefik)
③ Iceberg REST (Hive) เห็นตารางเดียวกัน
④ poc-engineer: Superset dataset / chart / dashboard
⑤ poc-analyst: ดู dashboard ✅  เขียนข้อมูล ⛔ (OPA ตาม group ใน Keycloak)
⑥ Grafana: metrics (Prometheus) + log (Loki) ของทุกขั้น
```

| User (realm `platform`) | Group | ใช้ทดสอบ |
|---|---|---|
| `admin` | `platform-admins` | ดูทุกอย่าง (Trino UI, Grafana) |
| `poc-engineer` | `data-engineers` | trigger DAG, สร้าง dashboard |
| `poc-analyst` | `analysts` | ดู dashboard, ลองเขียนข้อมูล (ต้องถูกปฏิเสธ) |

## Checklist

| # | ทดสอบ | ผ่านเมื่อ | Component | ผล |
|---|---|---|---|---|
| 1 | user `poc-analyst` | login Keycloak ได้ | Keycloak | |
| 2 | DAG `sales_pipeline` โผล่ใน Airflow | ภายใน ~5 นาทีหลัง push | GitHub, git-sync, Airflow | |
| 3 | trigger DAG | 3 task สีเขียว, `quality_check` ผ่าน | Airflow, Trino, OPA, Iceberg, Hive, SeaweedFS | |
| 4 | log ของ task | อ่านได้หลัง pod ถูกลบ | remote logging (S3) | |
| 5 | Iceberg REST เห็นตาราง | `total-records` ตรงกับ Trino | Hive 4 REST catalog | |
| 6 | dashboard ใน Superset | chart แสดงยอดขายรายวัน | Superset, impersonation | |
| 7 | analyst: ดู dashboard / SELECT | ✅ | role mapping, OPA | |
| 8 | analyst: INSERT / CREATE | ⛔ `Access Denied` | OPA | |
| 9 | Trino UI | คอลัมน์ User = ชื่อคนจริง | audit | |
| 10 | Grafana | เห็น CPU ของ Trino ตอนรัน + log ของ DAG ใน Loki | Prometheus, Loki, Vector | |
| 11 | แก้ DAG แล้ว push | Airflow ใช้โค้ดใหม่ (Dag Version เพิ่ม) | GitOps loop | |

---

## ขั้นที่ 1: สร้าง `poc-analyst` (Keycloak UI)

`https://keycloak.172.19.10.62.sslip.io/admin/` (login `kcadmin`) → realm **platform** → **Users → Add user**
- Username `poc-analyst`, Email `poc-analyst@example.local`, **Email verified: On** → Create
- แท็บ **Groups → Join Group** → `analysts`
- แท็บ **Credentials → Set password** (Temporary: **Off**)

ทดสอบ: Private Window → `https://keycloak.172.19.10.62.sslip.io/realms/platform/account/` → login `poc-analyst`

## ขั้นที่ 2: DAG มาถึง Airflow

หลัง push (Mac) → รอ ~5 นาที (dag-processor หาไฟล์ใหม่ทุก 5 นาที) → `https://airflow.172.19.10.62.sslip.io` (login `poc-engineer`) → ต้องเห็น `sales_pipeline` (tag `e2e`)

ตรวจจาก master ถ้ายังไม่โผล่:
```bash
kubectl -n data-platform exec airflow-scheduler-default-0 -c airflow -- ls /stackable/app/git-0/current/dags/
kubectl -n data-platform exec airflow-scheduler-default-0 -c airflow -- airflow dags list-import-errors 2>/dev/null | tail -3
```

## ขั้นที่ 3: รัน pipeline

ใน Airflow (login `poc-engineer` — role Op) → `sales_pipeline` → **Trigger**

ระหว่างรัน (master) — ดู pod ของ task เกิดและหาย:
```bash
kubectl -n data-platform get pods -w | grep sales-pipeline
```

ผ่านเมื่อ: `create_schema` → `build_orders_daily` → `quality_check` เขียวทั้งหมด (build ใช้ ~10–60 วินาทีใน Trino)
log ของ `quality_check` ต้องมี:
```
Trino user: airflow
target: rows=... orders=1500000 revenue=...
source: orders=1500000 revenue=...
iceberg snapshot: [..., 'append']
```

## ขั้นที่ 4: log อยู่บน S3

หลัง task จบ pod ถูกลบแล้ว แต่ใน Airflow → task → **Logs** ยังเปิดได้ (บรรทัดแรกขึ้นต้นด้วย `s3://airflow-logs/dag_id=sales_pipeline/...`)

(Mac — ตั้ง `AWS_*` + `AWS_CA_BUNDLE` ตาม [06-seaweedfs.md](../install/06-seaweedfs.md) ขั้นที่ 6)
```bash
aws --endpoint-url https://s3.172.19.10.62.sslip.io s3 ls --recursive s3://airflow-logs/dag_id=sales_pipeline/ | tail -3
aws --endpoint-url https://s3.172.19.10.62.sslip.io s3 ls --recursive s3://warehouse/external/sales.db/ | head -5   # parquet + metadata ของตาราง
```

## ขั้นที่ 5: Iceberg REST เห็นตารางเดียวกัน (master)

```bash
kubectl -n data-platform run rest-test --rm -i --image=curlimages/curl --restart=Never -- \
  curl -s http://hive-iceberg-rest:9001/iceberg/v1/namespaces/sales/tables/orders_daily \
  | grep -o '"total-records":"[0-9]*"' | tail -1
```

ผ่านเมื่อ: ตัวเลขตรงกับ `rows` ใน log ของ `quality_check` — Trino (Thrift) กับ REST ใช้ Hive Metastore ตัวเดียวกัน

## ขั้นที่ 6: Dashboard (Superset — login `poc-engineer`)

1. **Datasets → + Dataset** → Database `Trino`, Schema `sales`, Table `orders_daily` → **Create dataset and create chart**
2. Chart type **Line Chart**:
   - X-axis `orderdate`, Time grain **Month**
   - Metrics `SUM(revenue)`
   - Dimensions `orderpriority`
   - **Update chart** → Save → ชื่อ `Revenue by month` → Add to new dashboard `Sales PoC`
3. เพิ่มอีก chart: **Big Number** → Metric `SUM(orders)` → Save → dashboard `Sales PoC`
4. เปิด dashboard `Sales PoC` → **Publish** (มุมขวาบน เปลี่ยนจาก Draft เป็น Published — ให้คนอื่นเห็น)

ผ่านเมื่อ: กราฟรายเดือน 1992–1998 แยกตาม priority + ตัวเลข 1,500,000

## ขั้นที่ 7–8: Analyst (Superset — Private Window, login `poc-analyst`)

> ต้องมี role `trino_access` ใน Superset แล้ว ([14-superset.md](../install/14-superset.md) ขั้นที่ 5.3)

**7. ดูได้**
- Settings → Info: role ต้องเป็น `Gamma`, `sql_lab`, `trino_access`
- **Dashboards → Sales PoC** → กราฟแสดงผล ✅
- **SQL Lab** → database `Trino` → `SELECT orderpriority, sum(orders) FROM iceberg.sales.orders_daily GROUP BY 1` ✅

**8. เขียนไม่ได้** — ใน SQL Lab (รันทีละบรรทัด):
```sql
INSERT INTO iceberg.sales.orders_daily SELECT * FROM iceberg.sales.orders_daily LIMIT 1
```
```sql
CREATE TABLE iceberg.sales.hack AS SELECT 1 AS x
```
ผ่านเมื่อ: ทั้งสองขึ้น `Access Denied` (Trino / OPA ปฏิเสธ — ไม่ใช่ Superset)

## ขั้นที่ 9: Trino UI (login `admin`)

`https://trino.172.19.10.62.sslip.io/ui/` → รายการ query ล่าสุด:
| query จาก | คอลัมน์ User ต้องเป็น |
|---|---|
| Airflow (`CREATE OR REPLACE TABLE ...`) | `airflow` |
| Superset ของ engineer | `poc-engineer` |
| Superset ของ analyst (รวม INSERT ที่ล้มเหลว) | `poc-analyst` |

## ขั้นที่ 10: Grafana (login `admin`)

**Metrics** — Explore → Prometheus:
```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="data-platform", pod=~"trino-.*", container="trino"}[2m]))
```
ช่วงเวลา **Last 1 hour** → ต้องเห็น CPU ของ `trino-worker` พุ่งตอน `build_orders_daily` รัน

**Logs** — Explore → Loki:
```logql
{namespace="data-platform", pod=~"sales-pipeline.*"}
```
ต้องเห็น log ของ task pod (แม้ pod ถูกลบไปแล้ว)

**Dashboard** — Dashboards → `Kubernetes / Compute Resources / Namespace (Pods)` → namespace `data-platform` → ดู memory ของ Trino worker เทียบกับ limit 5Gi

## ขั้นที่ 11: GitOps loop

แก้ `dags/sales_pipeline.py` เล็กน้อย (เช่น เพิ่ม tag `"v2"`) → commit + push → รอ git-sync (~30 วินาที) + parse (~30 วินาที)
ผ่านเมื่อ: หน้า DAG แสดง tag ใหม่ และ **Dag Version** เพิ่มเป็น v2 — ไม่ต้อง restart อะไร

---

## ถ้าไม่ผ่าน

| ขั้น | อาการ | ดูที่ |
|---|---|---|
| 3 | `Access Denied: Cannot access catalog tpch` | OPA ยังไม่ได้ rule ใหม่ — `kubectl -n data-platform get cm trino-opa-policies -o yaml \| grep tpch` (ต้องมี airflow + tpch) |
| 3 | `build_orders_daily` ช้ามาก / worker OOM | `kubectl -n data-platform describe pod trino-worker-default-0`; ลองใช้ `tpch.tiny` ก่อน |
| 3 | task ค้าง `No Status` | DAG ถูก pause — กด unpause ([15-airflow.md](../install/15-airflow.md)) |
| 5 | REST ตอบ 404 `NoSuchTableException` | Thrift / REST ไม่ได้ใช้ metastore เดียวกัน — แจ้งผล |
| 6 | Superset ไม่เห็น schema `sales` | Database → Edit → ตรวจ Impersonate + refresh schema list |
| 7 | analyst ไม่เห็น dashboard | dashboard ยังเป็น Draft หรือ analyst ไม่มี `trino_access` |
| 8 | analyst INSERT **ผ่าน** | ❗ OPA ไม่ทำงานตาม group — ตรวจ user-info-fetcher ([13-trino-sso-opa.md](../install/13-trino-sso-opa.md)) |
| 10 | Loki ไม่มี log ของ task pod | pod อยู่สั้นเกินกว่า Vector อ่านทัน — ใช้ log บน S3 (ขั้นที่ 4) แทนได้ |

## บันทึกผล

| วันที่ | ผู้ทดสอบ | ผ่าน | ไม่ผ่าน / หมายเหตุ |
|---|---|---|---|
| 2026-10-15 | ทีม PoC | 1–11 ทั้งหมด | — |
