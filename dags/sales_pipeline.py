"""E2E test: pipeline สรุปยอดขายรายวัน — tpch.sf1.orders (1.5 ล้านแถว) → iceberg.sales.orders_daily

ใช้ทดสอบระบบครบลูป (docs/test/e2e-test.md):
  Airflow (KubernetesExecutor) → Trino (user airflow, OPA) → Iceberg บน SeaweedFS + Hive Metastore
  → Superset dashboard → analyst ดูได้แต่เขียนไม่ได้ (OPA)
งานหนัก (aggregate) ทำใน Trino ทั้งหมด — pod ของ task แค่ส่ง SQL
"""

from datetime import datetime

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.trino.hooks.trino import TrinoHook
from airflow.sdk import dag, task

TARGET = "iceberg.sales.orders_daily"


@dag(
    dag_id="sales_pipeline",
    schedule=None,
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=False,
    tags=["poc", "e2e", "trino"],
)
def sales_pipeline():
    create_schema = SQLExecuteQueryOperator(
        task_id="create_schema",
        conn_id="trino_default",
        sql="CREATE SCHEMA IF NOT EXISTS iceberg.sales WITH (location = 's3a://warehouse/external/sales.db')",
    )

    build_daily = SQLExecuteQueryOperator(
        task_id="build_orders_daily",
        conn_id="trino_default",
        sql=f"""
            CREATE OR REPLACE TABLE {TARGET}
            WITH (format_version = 2, partitioning = ARRAY['year(orderdate)'])
            AS
            SELECT
                orderdate,
                orderpriority,
                count(*)                            AS orders,
                CAST(sum(totalprice) AS DECIMAL(18, 2)) AS revenue,
                CAST(avg(totalprice) AS DECIMAL(18, 2)) AS avg_order_value
            FROM tpch.sf1.orders
            GROUP BY orderdate, orderpriority
        """,
    )

    @task
    def quality_check() -> dict:
        hook = TrinoHook(trino_conn_id="trino_default")
        print("Trino user:", hook.get_first("SELECT current_user")[0])

        rows, total_orders, total_revenue = hook.get_first(
            f"SELECT count(*), sum(orders), sum(revenue) FROM {TARGET}"
        )
        src_orders, src_revenue = hook.get_first(
            "SELECT count(*), CAST(sum(totalprice) AS DECIMAL(18, 2)) FROM tpch.sf1.orders"
        )
        print(f"target: rows={rows} orders={total_orders} revenue={total_revenue}")
        print(f"source: orders={src_orders} revenue={src_revenue}")

        assert rows > 0, "ตารางว่าง"
        assert total_orders == src_orders, f"จำนวน order ไม่ตรง: {total_orders} != {src_orders}"
        # sum ของค่าที่ปัดทศนิยมรายกลุ่มต่างจากยอดรวมต้นทางได้เล็กน้อย
        assert abs(float(total_revenue) - float(src_revenue)) < 1000, "ยอดขายรวมไม่ตรง"

        snapshot = hook.get_first(
            f'SELECT snapshot_id, operation FROM iceberg.sales."orders_daily$snapshots" ORDER BY committed_at DESC LIMIT 1'
        )
        print(f"iceberg snapshot: {snapshot}")
        return {"rows": rows, "orders": total_orders, "snapshot_id": snapshot[0]}

    create_schema >> build_daily >> quality_check()


sales_pipeline()
