# SRA metadata 数据分析

本文档说明 SRA metadata 原始数据能提供什么信息，以及为什么项目中需要同时使用 `SRA_Accessions` 和 XML metadata 两条数据链路。

主要参考：

```text
D:/桌面/SRA可筛选文件信息.md
sra_accession 详细统计数据.md
sra_accession 详细统计数据可视化版.md
```

## 1. 两类 SRA metadata 的分工

| 数据来源 | 主要作用 | 适合回答的问题 |
|---|---|---|
| `SRA_Accessions` | 全库 accession 统一索引，字段少但全、快、适合硬过滤 | 这个 RUN 是否 live/public？Spots/Bases 是否大于 0？对应 BioSample/BioProject 是什么？ |
| XML metadata | 每个 accession 文件夹内的 XML 结构，字段多、语义强 | 这个 RUN 的 library strategy 是什么？样本物种是什么？有哪些 sample attributes？RUN/EXPERIMENT/SAMPLE/STUDY 如何连接？ |

结论：`SRA_Accessions` 用于可下载性和粗筛，XML metadata 用于实验设计、样本语义和回源验证。

## 2. SRA_Accessions 能提供什么

`SRA_Accessions` 是 SRA 全库的统一 accession 索引表，包含 20 个字段。

| 字段 | 含义 | 使用建议 |
|---|---|---|
| `Accession` | 唯一 accession ID | 主查询键 |
| `Submission` | accession 属于哪个 submission | 辅助追踪提交记录 |
| `Status` | 当前状态 | 默认只保留 `live` |
| `Updated` | 最近更新时间 | 审计字段 |
| `Published` | 公开发布时间 | 审计字段 |
| `Received` | 接收时间 | 审计字段 |
| `Type` | accession 层级实体 | 必须使用，不要只靠前缀推断 |
| `Center` | 提交机构 | 辅助筛选 |
| `Visibility` | 可见性 | 默认只保留 `public` |
| `Alias` | 提交者自定义名称 | 通常不作为主键 |
| `Experiment` | 对应 experiment accession | RUN -> EXPERIMENT 关系 |
| `Sample` | 对应 sample accession | RUN/EXPERIMENT -> SAMPLE 关系 |
| `Study` | 对应 study accession | 项目级关系 |
| `Loaded` | 进入 SRA 系统时间 | 审计字段 |
| `Spots` | reads/spot 数 | 下载候选必须大于 0 |
| `Bases` | 总碱基数 | 下载候选必须大于 0 |
| `Md5sum` | 校验信息 | 当前主流程不依赖 |
| `BioSample` | 标准化 BioSample accession | RefSeq-SRA 关联优先主键 |
| `BioProject` | 项目级 accession | 辅助关联，不替代 BioSample |
| `ReplacedBy` | 被哪个 accession 替代 | 替代关系审计 |

## 3. accession 层级和前缀

常见前缀含义：

| 前缀家族 | 来源 | Submission | Study | Sample | Experiment | Run |
|---|---|---|---|---|---|---|
| `SR*` | NCBI SRA | SRA | SRP | SRS | SRX | SRR |
| `ER*` | ENA/EBI | ERA | ERP | ERS | ERX | ERR |
| `DR*` | DDBJ | DRA | DRP | DRS | DRX | DRR |

注意：前缀只能辅助理解，正式分析应使用 `Type` 字段。

## 4. Sample/BioSample 与 Study/BioProject 的区别

| SRA 内部对象 | NCBI 跨库对象 | 区别 |
|---|---|---|
| `Sample` | `BioSample` | `Sample` 是 SRA 内部样本对象；`BioSample` 是 NCBI 跨数据库标准样本 ID，可连接 RefSeq 等数据 |
| `Study` | `BioProject` | `Study` 是 SRA 内部项目对象；`BioProject` 是 NCBI 全库统一项目 ID |

后续 RefSeq-SRA 关联应优先使用 `BioSample`，`BioProject` 只能作为项目级辅助字段。

## 5. SRA_Accessions 当前统计结论

关键规模：

| 指标 | 数量 |
|---|---:|
| 总记录数 | 148,211,048 |
| RUN | 50,013,612 |
| EXPERIMENT | 44,607,471 |
| SAMPLE | 44,540,766 |
| STUDY | 807,530 |
| SUBMISSION | 7,897,148 |
| ANALYSIS | 344,521 |
| RUN live + public + Spots/Bases > 0 | 40,437,905 |

推荐下载候选过滤：

```sql
Type = 'RUN'
AND Status = 'live'
AND Visibility = 'public'
AND TRY_CAST(Spots AS BIGINT) > 0
AND TRY_CAST(Bases AS BIGINT) > 0
```

完整统计见：

```text
sra_accession 详细统计数据.md
sra_accession 详细统计数据可视化版.md
```

## 6. XML metadata 能提供什么

XML metadata 来自每个 accession 文件夹中的 XML 文件。每类 XML 关注的信息不同。

### 6.1 RUN.xml

主要信息：

- 主标识符：如 `SRR...`
- 提交者标识符：如 `SUB...`
- 实验引用：RUN 指向 `SRX...`
- 原始文件名或提交文件名线索

用途：

- 确认 RUN -> EXPERIMENT 关系。
- 回源审计 RUN 层级字段。

### 6.2 EXPERIMENT.xml

主要信息：

- 主标识符：如 `SRX...`
- STUDY 标识：如 `SRP...`
- 外部 Study/BioProject：如 `PRJNA...`
- SAMPLE 描述符：如 `SRS...`
- 外部 BioSample：如 `SAMN...`
- library strategy：如 `RNA-Seq`、`WGS`、`WES`
- library source：如 `TRANSCRIPTOMIC`、`GENOMIC`
- library selection：如 `cDNA`、`RANDOM`、`PCR`
- library layout：`SINGLE` 或 `PAIRED`
- platform 和 instrument model：如 Illumina、NextSeq 500

用途：

- 判断是不是转录组/RNA-seq 数据。
- 确认 EXPERIMENT -> SAMPLE、EXPERIMENT -> STUDY。
- 提取平台和文库设计字段。

### 6.3 SAMPLE.xml

主要信息：

- 主标识符：如 `SRS...`
- 外部 BioSample：如 `SAMN...`
- Taxon ID
- 物种拉丁名
- 样本标题
- 交叉引用链接
- sample attributes 键值对，例如 isolate、tissue、host、strain、isolation_source

用途：

- 与 RefSeq 通过 BioSample/TaxID 关联。
- 解析样本语义和生物学条件。
- 提取后续筛选需要的 sample attributes。

### 6.4 STUDY.xml

主要信息：

- 主标识符：如 `SRP...`
- 外部 BioProject：如 `PRJNA...`
- 研究标题
- 研究类型
- 研究摘要
- center project name

用途：

- 提供项目级背景。
- 辅助解释 BioProject 和研究目的。

### 6.5 SUBMISSION.xml

主要信息：

- submission accession：如 `SRA...`
- 提交者标识：如 `SUB...`
- 实验室名称
- 中心名称

用途：

- 提交记录审计。
- 当前第一版 XML full 索引不把 submission core 作为主输出。

## 7. XML metadata 与 SRA_Accessions 的互补

| 问题 | 优先使用 |
|---|---|
| RUN 是否可下载？ | `SRA_Accessions` |
| RUN 是否 live/public？ | `SRA_Accessions` |
| Spots/Bases 是否有效？ | `SRA_Accessions` |
| RUN 属于哪个 Experiment/Sample/Study？ | 两者交叉校验 |
| library strategy/source/selection 是什么？ | XML `experiment_core` |
| 平台和测序型号是什么？ | XML `run_core` / `experiment_core` |
| 样本物种、TaxID、BioSample 是什么？ | XML `sample_core`，并与 `SRA_Accessions` 校验 |
| tissue/host/strain/isolation_source 等样本属性？ | XML `sample_attribute_core` |
| 与 RefSeq 关联用什么字段？ | 优先 BioSample，其次 BioProject/TaxID 辅助 |

## 8. 当前项目的实际处理路线

```text
原始 SRA metadata
├── SRA_Accessions
│   ├── 转 Parquet
│   ├── 按 Type 分区
│   ├── 生成 live/public/nonzero RUN 派生表
│   └── 输出可下载性和关系统计
└── XML full snapshot
    ├── 生成 directory_manifest 和 chunk_manifest
    ├── chunk parser 解析 XML
    ├── streaming finalizer 合并全局表
    ├── 生成 core/relation/entity/sample_attribute/xml_path_inventory
    ├── schema validation
    └── XML back-check
```

当前推荐先用 `SRA_Accessions` 做硬过滤，再用 XML full 索引补充实验设计和样本语义。
