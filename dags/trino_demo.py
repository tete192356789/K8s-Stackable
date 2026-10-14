"""DAG ตัวอย่าง: Airflow → Trino (Iceberg) — ทดสอบ connection, สิทธิ์ (OPA) และ task log บน S3

รันเองจาก UI (schedule=None) — ทุก task รันเป็น pod ใหม่ (KubernetesExecutor)
connection "trino_default" มาจาก env AIRFLOW_CONN_TRINO_DEFAULT (secret airflow-env)
Trino ตรวจสิทธิ์ของ user "airflow" ด้วย OPA: อ่าน/เขียนได้เฉพาะ catalog iceberg
"""

from datetime import datetime

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.trino.hooks.trino import TrinoHook
from airflow.sdk import dag, task


@dag(
    dag_id="trino_demo",
    schedule=None,
    start_date=datetime(2026, 1, 1),
    catchup=False,
    is_paused_upon_creation=False,  # DAG ใหม่ถูก pause ไว้ก่อนเป็นค่าเริ่มต้น — ตัวอย่างนี้เปิดเลย
    tags=["poc", "trino"],
)
def trino_demo():
    create_table = SQLExecuteQueryOperator(
        task_id="create_table",
        conn_id="trino_default",
        sql="""
            CREATE TABLE IF NOT EXISTS iceberg.demo.airflow_runs (
                run_id VARCHAR,
                nation_count BIGINT,
                loaded_at TIMESTAMP(6) WITH TIME ZONE
            )
        """,
    )

    @task
    def load(run_id: str | None = None) -> int:
        hook = TrinoHook(trino_conn_id="trino_default")
        print("Trino user:", hook.get_first("SELECT current_user")[0])
        count = hook.get_first("SELECT count(*) FROM iceberg.demo.nation")[0]
        hook.run(
            "INSERT INTO iceberg.demo.airflow_runs VALUES (?, ?, current_timestamp)",
            parameters=(run_id, count),
        )
        print(f"inserted run_id={run_id} nation_count={count}")
        return count

    create_table >> load(run_id="{{ run_id }}")


trino_demo()
