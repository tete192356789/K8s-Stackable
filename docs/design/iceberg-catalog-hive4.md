# Iceberg catalog: ปัญหา Hive Metastore 4 กับ Spark / PyIceberg และทางเลือก

> สถานะ: **รอตัดสินใจ / รอทดสอบ** — ติดตั้ง Hive 4.2.0 ได้ตามแผน; ถ้า PoC ใช้ Spark หรือ PyIceberg ต้องทดสอบทางเลือก E (REST API ในตัว HMS) ก่อน
> ข้อมูล ณ 2026-09-30: Stackable SDP 26.7.0, Trino 481, Iceberg 1.10.1 / 1.11.0

## สรุป

- **Trino 481 ใช้ Hive Metastore 4.2.0 ได้ปกติ**
- **Spark, PyIceberg (และ engine อื่นที่ใช้ Iceberg `HiveCatalog`) ใช้กับ Hive Metastore 4.0.1 ขึ้นไปไม่ได้** — error `Invalid method name: 'get_table'`
- Hive Metastore **4.0.0** ยังใช้ได้กับทุก engine แต่ **deprecated ใน SDP 26.7** (SDP รุ่นถัดไปอาจเลิกรองรับ)
- ทางออกคือให้ Spark / PyIceberg คุยผ่าน **Iceberg REST catalog** แทน Thrift
- **Hive Metastore 4.1+ (รวม 4.2.0) มี Iceberg REST Catalog API ในตัว** (HIVE-28059) — HMS ตัวเดียวให้ Trino ใช้ Thrift และให้ Spark / PyIceberg ใช้ REST กับตารางชุดเดียวกันได้ **(ทางเลือก E — ต้องทดสอบว่า image ของ Stackable เปิดใช้ได้)**
- ถ้าจะใช้ REST catalog ตัวอื่น (เช่น Lakekeeper) ฝั่ง Trino ต้องตั้งเองด้วย TrinoCatalog แบบ `generic` เพราะแบบ `iceberg` ของ Stackable รองรับแค่ Hive Metastore

| ถ้า PoC… | ใช้ |
|---|---|
| ใช้ Trino อย่างเดียว | Hive Metastore **4.2.0** (แผนเดิม) — ทางเลือก D |
| ใช้ Spark / PyIceberg ด้วย | **ทดสอบทางเลือก E ก่อน** (Hive 4.2.0 + REST API ในตัว) ถ้าใช้ไม่ได้ → ทางเลือก A (Hive 4.0.0 แบบเดียวกับ demo ของ Stackable) |
| วางแผน production ระยะยาว | ทางเลือก E ถ้าผลทดสอบผ่าน หรือ REST catalog แยก (Lakekeeper) — ทางเลือก C |

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

| | A. Hive 4.0.0 | B. Hive 2 ตัว | C. REST catalog แยก | D. ไม่ใช้ Spark | **E. Hive 4.2.0 + REST ในตัว** |
|---|---|---|---|---|---|
| คำอธิบาย | ใช้ Hive Metastore 4.0.0 ตัวเดียวทั้ง Trino และ Spark | 4.2.0 สำหรับตาราง Hive + 4.0.0 สำหรับตาราง Iceberg | ย้าย catalog ของ Iceberg ไป REST catalog อีกตัว (เช่น Lakekeeper) | Trino อย่างเดียว ใช้ 4.2.0 ตามแผน | HMS 4.2.0 ตัวเดียว: Trino ใช้ Thrift, Spark / PyIceberg ใช้ REST API ของ HMS |
| Spark / PyIceberg ใช้ได้ | ✅ | ✅ | ✅ | ❌ | ✅ (ถ้า image ของ Stackable เปิดใช้ได้) |
| Stackable รองรับตรง ๆ | ✅ (แต่ deprecated) | ✅ (แต่ deprecated) | ⚠️ Trino ต้องใช้ `generic` connector, catalog ติดตั้งเอง | ✅ | ⚠️ Trino ใช้แบบ `iceberg` ได้ตามเดิม แต่การเปิด REST ของ HMS ต้องตั้งเอง (`configOverrides` + Service เพิ่ม) |
| ความเสี่ยงระยะยาว | สูง — 4.0.0 อาจหายใน SDP รุ่นถัดไป | สูง (ส่วน Iceberg) | ต่ำ — ทิศทางหลักของ Iceberg | ต่ำ | ต่ำ — ใช้ LTS และ API มาตรฐาน |
| RAM เพิ่ม (PoC) | 0 | ~1.5 GB (Hive ตัวที่ 2) — **PoC แทบไม่เหลือ** | catalog (Lakekeeper ~100–200 MB) — ตัด Hive ออกได้ถ้าไม่มีตาราง Hive แบบเดิม | 0 | 0 |
| ความยาก | ต่ำ | ปานกลาง | ปานกลาง | ต่ำ | ปานกลาง (ยังไม่ได้ทดสอบกับ Stackable) |

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

**ไม่แนะนำให้ใช้ `configOverrides` บนแบบ `iceberg` แทน** — แบบ `iceberg` บังคับต้องมี `metastore` ทำให้ operator ใส่ `hive.metastore.uri` เสมอ ถ้าเปลี่ยนเป็น `iceberg.catalog.type=rest` property นั้นจะไม่ถูกใช้ ซึ่ง Trino มักไม่ยอม start (`Configuration property ... was not used`) ทีม Stackable เคยเสนอวิธี "ใส่ metastore หลอก + `configOverrides`" ใน [discussion #41](https://github.com/orgs/stackabletech/discussions/41) แต่วันถัดมาแนะนำแบบ `generic` แทน และผู้ถามยืนยันว่าแบบ `generic` ใช้ได้ — ยังไม่ได้ทดสอบวิธี `configOverrides` เอง

> ⚠️ config ข้างบนตรวจกับเอกสาร Stackable 26.7 แล้ว แต่ **ยังไม่ได้ทดสอบกับ Trino 481 จริง** — ต้องทดสอบใน PoC ก่อนใช้

### E. Hive Metastore 4.2.0 + Iceberg REST Catalog API ในตัว

ตั้งแต่ Hive 4.1 (HIVE-28059) Hive Metastore เปิด **Iceberg REST Catalog API** ได้ในตัว — HMS ตัวเดียวให้บริการ 2 ช่องทางกับตารางชุดเดียวกัน

```
Trino ──Thrift :9083──┐   (Stackable TrinoCatalog แบบ iceberg ตามเดิม)
                      ├──▶ Hive Metastore 4.2.0 ──▶ PostgreSQL (CNPG)
Spark ──REST :9001────┤   (ไม่ใช้ Thrift → ไม่เจอปัญหา get_table)
PyIceberg ──REST──────┘
```

| เรื่อง | ค่า (จากเอกสาร Hive) |
|---|---|
| เปิดใช้ | `metastore.catalog.servlet.port` (ค่าเริ่มต้น `-1` = ปิด; image ทางการของ Hive ใช้ 9001) |
| Endpoint | `http://<hms>:<port>/iceberg/v1/...` เช่น `/iceberg/v1/config`, `/iceberg/v1/namespaces/default/tables` |
| Auth (`metastore.catalog.servlet.auth`) | `jwt` (ค่าเริ่มต้น, ตรวจ token ด้วย JWKS), `oauth2` (ต่อ Keycloak ได้), `simple` / `none` (ทดสอบเท่านั้น) |

**ร่าง config (ยังไม่ได้ทดสอบ)** — เปิด REST ผ่าน `configOverrides` ของ HiveCluster แล้วสร้าง Service เพิ่ม เพราะ Service ของ Stackable เปิดแค่ 9083

```yaml
apiVersion: hive.stackable.tech/v1alpha1
kind: HiveCluster
metadata:
  name: hive
spec:
  image:
    productVersion: 4.2.0
  metastore:
    configOverrides:
      hive-site.xml:
        metastore.catalog.servlet.port: "9001"
        metastore.catalog.servlet.auth: "none"          # PoC ภายใน cluster เท่านั้น — production ใช้ oauth2 กับ Keycloak
  # ... ส่วนอื่นเหมือนเดิม
---
apiVersion: v1
kind: Service
metadata:
  name: hive-iceberg-rest
spec:
  selector:
    app.kubernetes.io/name: hive              # ตรวจ label จริงของ pod metastore ก่อน: kubectl get pods --show-labels
    app.kubernetes.io/instance: hive
  ports:
    - { name: iceberg-rest, port: 9001, targetPort: 9001 }
```

Spark / PyIceberg ชี้ไปที่ `http://hive-iceberg-rest.<namespace>.svc:9001/iceberg` (ดูหัวข้อ 5)

**ต้องทดสอบใน PoC ก่อนเลือกทางนี้**

1. image Hive 4.2.0 ของ Stackable มีส่วน REST catalog (module `metastore-rest-catalog`) หรือไม่ — เอกสาร Stackable ไม่ได้พูดถึง
2. `configOverrides` ของ `hive-site.xml` ถูกนำไปใช้ และ HMS log แสดงว่าเปิด servlet ที่ port 9001
3. `curl http://hive-iceberg-rest.<namespace>.svc:9001/iceberg/v1/config` ได้ JSON กลับมา
4. Trino (Thrift) สร้างตาราง → Spark / PyIceberg (REST) อ่านตารางเดียวกันได้ และกลับกัน
5. RAM ของ HMS หลังเปิด REST ยังอยู่ในงบของ PoC

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

**แบบ REST catalog** — เปลี่ยนเฉพาะ `type` และ `uri`

```properties
spark.sql.catalog.lakehouse.type=rest
# ทางเลือก E (REST API ของ Hive Metastore):
spark.sql.catalog.lakehouse.uri=http://hive-iceberg-rest.<namespace>.svc:9001/iceberg
# ทางเลือก C (Lakekeeper):
# spark.sql.catalog.lakehouse.uri=http://lakekeeper.lakekeeper.svc:8181/catalog
# spark.sql.catalog.lakehouse.warehouse=warehouse
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

1. **ติดตั้ง Hive Metastore 4.2.0** (ตามแผนเดิม) + TrinoCatalog แบบ `iceberg` — ใช้ได้ทันทีสำหรับ Trino
2. **ถ้า PoC ใช้ Spark / PyIceberg:** ทดสอบ **E** (เปิด REST API ของ HMS) ตามรายการทดสอบในหัวข้อ E
   - ผ่าน → ใช้ E (Hive LTS ตัวเดียว ไม่ต้องมี service เพิ่ม)
   - ไม่ผ่าน (เช่น image ของ Stackable ไม่มีส่วน REST) → เปลี่ยน `productVersion` เป็น **4.0.0 (A)** หรือทดลอง **C** (Lakekeeper)
3. **Production:** เลือก E หรือ C ตามผล PoC — ทั้งคู่ใช้ REST ซึ่งเป็นมาตรฐานของ Iceberg และไม่ต้องพึ่ง Hive version ที่ deprecated

---

## แหล่งอ้างอิง

- Iceberg [#12878](https://github.com/apache/iceberg/issues/12878) — `Invalid method name: 'get_table'`
- Iceberg [#13572](https://github.com/apache/iceberg/issues/13572) — Iceberg Spark runtime 4.0 can't support Hive 4
- PyIceberg [#1222](https://github.com/apache/iceberg-python/issues/1222) — Hive metastore 4.0.1 removed deprecated Thrift APIs
- Stackable demo [data-lakehouse-iceberg-trino-spark](https://docs.stackable.tech/home/stable/demos/data-lakehouse-iceberg-trino-spark/) และ [hive-metastores.yaml](https://github.com/stackabletech/demos/blob/main/stacks/data-lakehouse-iceberg-trino-spark/hive-metastores.yaml)
- Stackable [Hive operator — supported versions](https://docs.stackable.tech/home/stable/hive/)
- Hive: [Iceberg REST Catalog API backed by Hive Metastore](https://hive.apache.org/docs/latest/admin/iceberg-rest-catalog/), [Hive 4.2.0 REST Catalog quickstart](https://hive.apache.org/docs/latest/quickstart-rest-catalog/), [HIVE-28059](https://issues.apache.org/jira/browse/HIVE-28059)
- Stackable [discussion #41 — Trino กับ Iceberg REST catalog](https://github.com/orgs/stackabletech/discussions/41)
- Stackable Trino catalogs: [Iceberg](https://docs.stackable.tech/home/stable/trino/usage-guide/catalogs/iceberg/), [Generic](https://docs.stackable.tech/home/stable/trino/usage-guide/catalogs/generic/), [configOverrides](https://docs.stackable.tech/home/stable/trino/usage-guide/catalogs/)
- [Iceberg Spark configuration](https://iceberg.apache.org/docs/latest/spark-configuration/)
