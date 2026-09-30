# Iceberg catalog: ปัญหา Hive Metastore 4 กับ Spark / PyIceberg และทางเลือก

> สถานะ: **รอตัดสินใจ** — ต้องตอบก่อนติดตั้ง Hive Metastore ว่า PoC จะใช้ Spark (หรือ PyIceberg) อ่าน/เขียนตาราง Iceberg หรือไม่
> ข้อมูล ณ 2026-09-30: Stackable SDP 26.7.0, Trino 481, Iceberg 1.10.1 / 1.11.0

## สรุป

- **Trino 481 ใช้ Hive Metastore 4.2.0 ได้ปกติ**
- **Spark, PyIceberg (และ engine อื่นที่ใช้ Iceberg `HiveCatalog`) ใช้กับ Hive Metastore 4.0.1 ขึ้นไปไม่ได้** — error `Invalid method name: 'get_table'`
- Hive Metastore **4.0.0** ยังใช้ได้กับทุก engine แต่ **deprecated ใน SDP 26.7** (SDP รุ่นถัดไปอาจเลิกรองรับ)
- ทางออกระยะยาวคือ **Iceberg REST catalog** — แต่ Stackable TrinoCatalog แบบ `iceberg` รองรับแค่ Hive Metastore ต้องตั้งเองด้วย connector แบบ `generic`

| ถ้า PoC… | ใช้ |
|---|---|
| ใช้ Trino อย่างเดียว | Hive Metastore **4.2.0** (แผนเดิม) — ทางเลือก D |
| ใช้ Spark / PyIceberg ด้วย | Hive Metastore **4.0.0** — ทางเลือก A (แบบเดียวกับ demo ของ Stackable) |
| วางแผน production ระยะยาว | ทดลอง **REST catalog (Lakekeeper)** — ทางเลือก C |

---

## 1. พื้นหลัง: Iceberg กับ catalog

Iceberg เป็น table format — ไฟล์ข้อมูล (Parquet) และไฟล์ metadata ของตารางอยู่ใน SeaweedFS (bucket `warehouse`)
**Catalog** เป็นตัวจำว่า "ตาราง `sales.orders` ตอนนี้ใช้ไฟล์ metadata ตัวไหน" และทำให้การ commit จากหลาย engine เกิดทีละครั้ง

```
Trino / Spark / PyIceberg
        │ ถาม catalog: ตาราง X อยู่ที่ metadata ไฟล์ไหน
        ▼
    Catalog  ──────────▶  (แผนเดิม) Hive Metastore ── PostgreSQL (CNPG)
        │
        ▼ อ่าน/เขียนไฟล์
    SeaweedFS (S3)
```

ทุก engine ที่ต้องใช้ตารางชุดเดียวกัน **ต้องใช้ catalog เดียวกัน** — ปัญหาใน catalog จึงกระทบทุก engine

---

## 2. ปัญหา

### อาการ

Spark (หรือ PyIceberg) ที่ตั้ง catalog เป็น `type=hive` แล้วชี้ไป Hive Metastore 4.0.1 / 4.1 / 4.2 จะ error ตอนอ่านหรือสร้างตาราง

```
org.apache.thrift.TApplicationException: Invalid method name: 'get_table'
    at org.apache.hadoop.hive.metastore.api.ThriftHiveMetastore$Client.recv_get_table(...)
    at org.apache.iceberg.hive.HiveTableOperations.doRefresh(...)
```

### สาเหตุ

| ฝั่ง | รายละเอียด |
|---|---|
| Client | Iceberg `HiveCatalog` (ใน `iceberg-spark-runtime`, PyIceberg) คุย Thrift แบบ **Hive 2.3** — Iceberg 1.10.1 ยัง compile กับ Hive 2.3.10 |
| Server | **Hive Metastore 4.0.1 ลบ Thrift API แบบเก่า** เช่น `get_table` (ให้ใช้ `get_table_req` ที่รับ `GetTableRequest` แทน) |
| ผล | client เรียก method ที่ server ไม่มีแล้ว → `Invalid method name` |

ตั้ง `spark.sql.hive.metastore.version` ให้เป็น 4.x **ไม่ช่วย** สำหรับ Iceberg (Iceberg issue #13572) เพราะ Iceberg ใช้ Hive client ของตัวเอง ไม่ใช่ของ Spark SQL

### ใครได้รับผลกระทบ

| Engine / เครื่องมือ | Hive Metastore 4.2.0 | Hive Metastore 4.0.0 |
|---|---|---|
| Trino 481 (Iceberg / Hive connector) | ✅ (มี Metastore client ของตัวเอง, Stackable ทดสอบกับ 4.2 LTS) | ✅ |
| Spark + Iceberg `HiveCatalog` | ❌ | ✅ |
| PyIceberg (`HiveCatalog`) — เช่น Python task ใน Airflow | ❌ | ✅ |
| Flink + Iceberg `HiveCatalog` | ❌ (ใช้ `HiveCatalog` ตัวเดียวกัน — ยังไม่ได้ทดสอบ) | ✅ |
| Engine ใดก็ได้ผ่าน **Iceberg REST catalog** | ไม่เกี่ยว (ไม่ใช้ Thrift) | ไม่เกี่ยว |

### หลักฐาน

- Iceberg issue [#12878](https://github.com/apache/iceberg/issues/12878) และ [#13572](https://github.com/apache/iceberg/issues/13572) (Spark 4.0 + Hive 4.0.1 + Iceberg 1.10) — ยังไม่แก้
- PyIceberg issue [#1222](https://github.com/apache/iceberg-python/issues/1222) — "Hive metastore 4.0.1 remove deprecated thrift APIs"
- Demo ของ Stackable [`data-lakehouse-iceberg-trino-spark`](https://docs.stackable.tech/home/stable/demos/data-lakehouse-iceberg-trino-spark/) (Spark 4.1.2 + Iceberg 1.11.0 + Trino 481) **ยัง pin Hive Metastore 4.0.0** ([hive-metastores.yaml](https://github.com/stackabletech/demos/blob/main/stacks/data-lakehouse-iceberg-trino-spark/hive-metastores.yaml))
- [Stackable Hive operator 26.7](https://docs.stackable.tech/home/stable/hive/) รองรับ: 4.2.0 (LTS), 4.0.1 (deprecated), 4.0.0 (deprecated), 3.1.3 (deprecated)

---

## 3. ทางเลือก

| | A. Hive 4.0.0 | B. Hive 2 ตัว | C. REST catalog | D. ไม่ใช้ Spark |
|---|---|---|---|---|
| คำอธิบาย | ใช้ Hive Metastore 4.0.0 ตัวเดียวทั้ง Trino และ Spark | 4.2.0 สำหรับตาราง Hive + 4.0.0 สำหรับตาราง Iceberg | ย้าย catalog ของ Iceberg ไป REST catalog (เช่น Lakekeeper) | Trino อย่างเดียว ใช้ 4.2.0 ตามแผน |
| Spark / PyIceberg ใช้ได้ | ✅ | ✅ | ✅ | ❌ |
| Stackable รองรับตรง ๆ | ✅ (แต่ deprecated) | ✅ (แต่ deprecated) | ⚠️ Trino ต้องใช้ `generic` connector, catalog ติดตั้งเอง | ✅ |
| ความเสี่ยงระยะยาว | สูง — 4.0.0 อาจหายใน SDP รุ่นถัดไป | สูง (ส่วน Iceberg) | ต่ำ — ทิศทางหลักของ Iceberg | ต่ำ |
| RAM เพิ่ม (PoC) | 0 | ~1.5 GB (Hive ตัวที่ 2) — **PoC แทบไม่เหลือ** | catalog (Lakekeeper ~100–200 MB) — ตัด Hive ออกได้ถ้าไม่มีตาราง Hive แบบเดิม | 0 |
| ความยาก | ต่ำ | ปานกลาง | ปานกลาง | ต่ำ |

---

## 4. รายละเอียดแต่ละทางเลือก

### A. Hive Metastore 4.0.0

เปลี่ยนแค่ `productVersion` ของ HiveCluster (ตอนติดตั้ง Hive)

```yaml
apiVersion: hive.stackable.tech/v1alpha1
kind: HiveCluster
metadata:
  name: hive
spec:
  image:
    productVersion: 4.0.0      # แทน 4.2.0 — ใช้ได้กับ Spark / PyIceberg HiveCatalog
  # ... ส่วนอื่นเหมือนเดิม
```

TrinoCatalog แบบ `iceberg` ใช้ได้ตามปกติ — ไม่ต้องเปลี่ยนอะไรฝั่ง Trino
**ก่อนอัปเกรด SDP ทุกครั้ง** ต้องเช็กว่ายังรองรับ 4.0.0 อยู่หรือไม่

### B. Hive Metastore 2 ตัว

แบบเดียวกับ demo ของ Stackable: `HiveCluster hive` (ตาราง Hive) และ `HiveCluster hive-iceberg` (ตาราง Iceberg) ใช้ database แยกกันใน CNPG
Trino มี 2 catalog (`hive` → `hive`, `iceberg` → `hive-iceberg`), Spark ชี้ไป `hive-iceberg` อย่างเดียว
เหมาะเมื่อมีตาราง Hive แบบเดิมจำนวนมากและต้องการให้ส่วนนั้นใช้ 4.2.0 — ใน PoC นี้ไม่คุ้ม RAM

### C. Iceberg REST catalog

**REST catalog** คือมาตรฐาน HTTP API ที่ Iceberg กำหนด — engine ไหนรองรับมาตรฐานนี้ใช้ catalog ตัวไหนก็ได้ ไม่มีปัญหา Thrift version

```
Trino ──HTTP──┐
Spark ──HTTP──┼──▶ REST catalog (Lakekeeper) ──▶ PostgreSQL (CNPG)
PyIceberg ────┘
```

| ตัวเลือก | จุดเด่น | ข้อควรรู้ |
|---|---|---|
| **Lakekeeper** (แนะนำให้ทดลอง) | Rust ใช้ resource น้อย, PostgreSQL, OIDC กับ Keycloak, ใช้ OPA ตรวจสิทธิ์ได้, มี UI | โปรเจกต์ค่อนข้างใหม่ |
| Apache Polaris | อยู่ใน Apache, ระบบสิทธิ์ละเอียด | Java ใช้ RAM มากกว่า |
| Project Nessie | จัดการข้อมูลแบบ Git (branch / merge) | ซับซ้อนเกินถ้าไม่ใช้ branch |
| REST catalog ในตัว SeaweedFS | ไม่ต้องติดตั้งเพิ่ม | ใหม่ ยังไม่ครบเท่าตัวอื่น |

ถ้าทุกตารางเป็น Iceberg → **ตัด Hive Metastore ออกได้**; ถ้ามีตาราง Hive แบบเดิม (CSV / Parquet ดิบผ่าน Hive connector) → ยังต้องมี Hive Metastore สำหรับส่วนนั้น

#### Trino: ต้องใช้ TrinoCatalog แบบ `generic`

TrinoCatalog แบบ `iceberg` ของ Stackable **รองรับแค่ Hive Metastore** ("Iceberg depends on a Hive metastore being present") จึงต้องเขียน config ของ Iceberg connector เองด้วยแบบ `generic`:

```yaml
apiVersion: trino.stackable.tech/v1alpha1
kind: TrinoCatalog
metadata:
  name: iceberg
  labels:
    trino: trino
spec:
  connector:
    generic:
      connectorName: iceberg
      properties:
        iceberg.catalog.type:
          value: rest
        iceberg.rest-catalog.uri:
          value: http://lakekeeper.lakekeeper.svc:8181/catalog
        iceberg.rest-catalog.warehouse:
          value: warehouse
        fs.native-s3.enabled:
          value: "true"
        s3.endpoint:
          value: http://seaweedfs-s3.seaweedfs.svc:8333
        s3.region:
          value: us-east-1
        s3.path-style-access:
          value: "true"
        s3.aws-access-key:
          valueFromSecret: { name: trino-s3-credentials, key: accessKey }   # Secret จาก ESO (OpenBao: secret/seaweedfs/s3-admin)
        s3.aws-secret-key:
          valueFromSecret: { name: trino-s3-credentials, key: secretKey }
```

| สิ่งที่ต้องทำเองเมื่อใช้ `generic` | แบบ `iceberg` | แบบ `generic` |
|---|---|---|
| ที่อยู่ catalog | operator หาจาก HiveCluster | เขียน URL เอง |
| S3 endpoint / path-style | operator ใส่จาก `S3Connection` | เขียน `s3.*` เอง — **ไม่มี S3 integration** |
| S3 key | operator mount จาก SecretClass | `valueFromSecret` อ้าง Secret เอง |
| TLS กับ internal CA | — | ต้อง mount CA เองด้วย `podOverrides` (PoC ใช้ HTTP ภายใน cluster จึงไม่ต้อง) |
| Trino อัปเกรดแล้วชื่อ property เปลี่ยน | operator จัดการ | แก้ YAML เอง |

**ใช้ `configOverrides` บนแบบ `iceberg` แทนไม่ได้** — แบบ `iceberg` บังคับต้องมี `metastore` ทำให้ operator ใส่ `hive.metastore.uri` เสมอ ถ้าเปลี่ยนเป็น `iceberg.catalog.type=rest` property นั้นจะไม่ถูกใช้ และ Trino ไม่ยอม start เมื่อมี property ที่ไม่ได้ใช้ (`Configuration property ... was not used`)

> ⚠️ config ข้างบนตรวจกับเอกสาร Stackable 26.7 แล้ว แต่ **ยังไม่ได้ทดสอบกับ Trino 481 จริง** — ต้องทดสอบใน PoC ก่อนใช้

---

## 5. ตั้งค่า Spark ให้ใช้ Iceberg บน SeaweedFS (อ้างอิง)

ใช้ Iceberg runtime ให้ตรงกับ version ของ Spark (เช่น Spark 4.1 → `iceberg-spark-runtime-4.1_2.13`) และเพิ่ม `iceberg-aws-bundle` สำหรับ `S3FileIO`

**แบบ Hive Metastore (ทางเลือก A / B — Hive ต้องเป็น 4.0.0)**

```properties
spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.lakehouse=org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.lakehouse.type=hive
spark.sql.catalog.lakehouse.uri=thrift://hive-metastore.<namespace>.svc:9083
spark.sql.catalog.lakehouse.io-impl=org.apache.iceberg.aws.s3.S3FileIO
spark.sql.catalog.lakehouse.s3.endpoint=http://seaweedfs-s3.seaweedfs.svc:8333
spark.sql.catalog.lakehouse.s3.path-style-access=true
spark.sql.catalog.lakehouse.client.region=us-east-1
# S3 key: ใส่ผ่าน environment AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY จาก Secret ของ ESO
```

**แบบ REST catalog (ทางเลือก C)** — เปลี่ยนเฉพาะ 3 บรรทัด

```properties
spark.sql.catalog.lakehouse.type=rest
spark.sql.catalog.lakehouse.uri=http://lakekeeper.lakekeeper.svc:8181/catalog
spark.sql.catalog.lakehouse.warehouse=warehouse
```

---

## 6. ข้อควรระวังอื่นเมื่อ Trino และ Spark ใช้ตารางเดียวกัน

| เรื่อง | แนะนำ |
|---|---|
| Iceberg format version | ใช้ `format-version = 2` (demo ของ Stackable ใช้ 2) — ทั้ง Trino 481 และ Spark อ่าน/เขียนได้แน่นอน |
| Iceberg library version | ให้ Spark ใช้ Iceberg ใกล้เคียงกับที่ Trino ใช้ — ฟีเจอร์ใหม่ที่ engine หนึ่งเขียนอาจอ่านไม่ได้จากอีก engine |
| S3 addressing | SeaweedFS ต้องใช้ **path-style** ทุก engine |
| Commit พร้อมกัน | Iceberg กัน commit ชนกันผ่าน catalog อยู่แล้ว — แต่ควรหลีกเลี่ยงให้ Trino และ Spark เขียนตารางเดียวกันพร้อมกันบ่อย ๆ (จะ retry / fail) |
| งานดูแลตาราง (compaction, expire snapshots) | ให้ทำจาก engine เดียว (เช่น Trino `ALTER TABLE ... EXECUTE optimize`) ตั้งเวลาด้วย Airflow |

---

## 7. คำแนะนำและสิ่งที่ต้องตัดสินใจ

1. **ตอบก่อนติดตั้ง Hive:** PoC จะใช้ Spark หรือ PyIceberg กับตาราง Iceberg หรือไม่
   - ไม่ใช้ → **D**: Hive 4.2.0 + TrinoCatalog แบบ `iceberg`
   - ใช้ → **A**: Hive 4.0.0 (ตั้งค่าเหมือนเดิมทุกอย่าง ยกเว้น `productVersion`)
2. **หลัง Trino + Hive ใช้งานได้แล้ว** (ถ้ามีเวลา / resource): ทดลอง **C** กับ Lakekeeper ใน namespace แยก — วัด RAM, ทดสอบ Trino `generic` + Spark + PyIceberg กับตารางชุดเดียวกัน
3. **Production:** ถ้าผลทดลอง C ผ่าน ให้ใช้ REST catalog ตั้งแต่ต้น (ไม่ต้องพึ่ง Hive version ที่ deprecated และ register ตารางเดิมเข้า catalog ใหม่ได้โดยไม่ต้องย้ายข้อมูล)

---

## แหล่งอ้างอิง

- Iceberg [#12878](https://github.com/apache/iceberg/issues/12878) — `Invalid method name: 'get_table'`
- Iceberg [#13572](https://github.com/apache/iceberg/issues/13572) — Iceberg Spark runtime 4.0 can't support Hive 4
- PyIceberg [#1222](https://github.com/apache/iceberg-python/issues/1222) — Hive metastore 4.0.1 removed deprecated Thrift APIs
- Stackable demo [data-lakehouse-iceberg-trino-spark](https://docs.stackable.tech/home/stable/demos/data-lakehouse-iceberg-trino-spark/) และ [hive-metastores.yaml](https://github.com/stackabletech/demos/blob/main/stacks/data-lakehouse-iceberg-trino-spark/hive-metastores.yaml)
- Stackable [Hive operator — supported versions](https://docs.stackable.tech/home/stable/hive/)
- Stackable Trino catalogs: [Iceberg](https://docs.stackable.tech/home/stable/trino/usage-guide/catalogs/iceberg/), [Generic](https://docs.stackable.tech/home/stable/trino/usage-guide/catalogs/generic/), [configOverrides](https://docs.stackable.tech/home/stable/trino/usage-guide/catalogs/)
- [Iceberg Spark configuration](https://iceberg.apache.org/docs/latest/spark-configuration/)
