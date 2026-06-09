# SRA、RefSeq 与 TSS 数据处理旧版综合草案

## 0. 页面目标

本页用于统一整理 TSS 数据构建中的 RefSeq 元数据与 SRA 元数据处理方案。

核心目标是：

```
RefSeq assembly_summary_refseq.txt
    → 处理成 RefSeq linkage 表
    → 提供 genome / annotation 信息和 biosample 关联键

SRA_Accessions.tab + SRA XML 文件组
    → 处理成 SRA RUN metadata 表
    → 提供可下载 RUN、BioSample、Experiment、Library 信息

最终通过：
    RefSeq biosample ↔ SRA BioSample

关联得到：
    带 RefSeq genome / annotation 信息的可下载 transcriptomic RUN accession
```

本页的重点不是单独解释某一个文件，而是明确：

```
RefSeq 元数据最后应该处理成什么形态；
SRA 元数据最后应该处理成什么形态；
两者如何通过 BioSample 关联；
哪些 RUN 可以进入普通转录组 / TSS 相关数据集合。
```

---

## 1. 数据目录与当前数据来源

SRA 元数据目录：

```bash
/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_20260516/
```

当前 SRA 侧可用数据主要包括：

```
SRA_Accessions.tab
study.xml
sample.xml
experiment.xml
run.xml
submission.xml
*.annotated.xml
```

RefSeq 侧预期输入文件：

```
assembly_summary_refseq.txt
```

其中：

```
RefSeq assembly_summary_refseq.txt：提供 assembly / genome / annotation / biosample 信息
SRA_Accessions.tab：提供 SRA accession、Type、BioSample、BioProject、Experiment、Sample、Study、Spots、Bases 等索引信息
run.xml：提供 RUN → Experiment 映射
experiment.xml：提供 Experiment → Sample 以及 LibraryStrategy / LibrarySource / LibrarySelection / LibraryLayout
sample.xml：提供 Sample → BioSample / TaxID / ScientificName / 样本属性
study.xml：提供 Study / BioProject / 项目标题 / 项目类型
submission.xml：提供 submission / center / lab / 提交信息
```

---

## 2. 总体数据关系

SRA 的数据库结构是四级层级：

```
STUDY（研究项目）
  └── SAMPLE（生物样本）← 对应 BioSample（SAMN* / SAME* / SAMD* 等）
        └── EXPERIMENT（实验设计）← 建库方式：RNA-seq、CAGE、TSS-seq、WGS 等
              └── RUN（测序运行）← 对应 Run（SRR* / ERR* / DRR*），实际下机数据文件
```

RefSeq 与 SRA 的关联关系是：

```
RefSeq assembly_summary_refseq.txt
    └── biosample
          ↓ join
SRA sample.xml / SRA_Accessions.tab
    └── BioSample
          ↓
SRA Sample
          ↓
SRA Experiment
          ↓
SRA Run
          ↓
可下载 FASTQ / SRA 原始 reads
```

关键判断：

```
BioSample / biosample 是 RefSeq–SRA 的主关联键。
RUN 是最终下载单位。
Experiment 是判断测序类型和文库类型的关键层级。
```

---

## 3. Type 字段与下载单位

`SRA_Accessions.tab` 中的 `Type` 字段必须正确理解。

| Type | 含义 | 是否含实际测序数据 | 在本流程中的作用 |
| --- | --- | --- | --- |
| RUN | 一次测序运行（SRR */ ERR* / DRR*） | ✅ 有 | 最终下载单位 |
| EXPERIMENT | 实验设计（SRX */ ERX* / DRX*） | ❌ 只是元数据 | 判断 LibraryStrategy / LibrarySource 的层级 |
| SAMPLE | 样本（SRS */ ERS* / DRS*） | ❌ 只是元数据 | 连接 BioSample 与 Experiment |
| STUDY | 研究项目（SRP */ ERP* / DRP*） | ❌ 只是元数据 | 项目背景与 BioProject 辅助信息 |
| SUBMISSION | 提交记录 | ❌ 无实际 reads | 提交者、center、lab 信息 |
| ANALYSIS | 分析结果 | ❌ 不是原始测序数据 | 通常不进入原始 reads 下载流程 |

因此：

```
只有 Type = RUN 的 Accession 才能作为下载 accession。
Type = SAMPLE / STUDY / SUBMISSION 不能直接下载 reads。
```

---

## 4. RefSeq 元数据处理方案

### 4.1 原始输入

RefSeq 原始元数据是：

```
assembly_summary_refseq.txt
```

这是 RefSeq assembly summary 文本文件，通常是 tab 分隔格式。

### 4.2 RefSeq 侧需要保留的字段

RefSeq 侧的任务是提供 genome / annotation 信息，并给出可以和 SRA 关联的 `biosample` 字段。

推荐保留字段：

```python
keep_cols_refseq = [
    "assembly_accession",      # RefSeq assembly accession，例如 GCF_*
    "bioproject",              # RefSeq 侧 BioProject，辅助校验
    "biosample",               # 与 SRA BioSample 关联的主键
    "wgs_master",
    "refseq_category",         # reference genome / representative genome / na
    "taxid",                   # assembly 对应 taxid
    "species_taxid",           # 物种级 taxid
    "organism_name",           # 物种名
    "infraspecific_name",      # strain / breed / cultivar 等
    "isolate",                 # isolate 信息
    "version_status",          # latest / replaced / suppressed
    "assembly_level",          # Complete Genome / Chromosome / Scaffold / Contig
    "release_type",            # Major / Minor / Patch
    "genome_rep",              # Full / Partial
    "seq_rel_date",            # 序列发布日期
    "asm_name",                # assembly 名称
    "asm_submitter",           # 提交者
    "gbrs_paired_asm",
    "paired_asm_comp",
    "ftp_path",                # RefSeq FTP 路径
    "excluded_from_refseq",
    "relation_to_type_material",
    "asm_not_live_date",
    "assembly_type",
    "group",
    "genome_size",
    "genome_size_ungapped",
    "gc_percent",
    "replicon_count",
    "scaffold_count",
    "contig_count",
    "annotation_provider",
    "annotation_name",
    "annotation_date",
    "total_gene_count",
    "protein_coding_gene_count",
    "non_coding_gene_count",
    "pubmed_id",
]
```

### 4.3 RefSeq 处理后的目标形态

RefSeq 原始 txt 应处理成：

```
refseq_assembly_linkage.tsv
```

该表的定位是：

```
每一行代表一个 RefSeq assembly。
每一行必须尽量保留 biosample、assembly_accession、taxid、organism_name、ftp_path、annotation 信息。
后续通过 biosample 与 SRA BioSample 关联。
```

基础过滤建议：

```python
refseq_linkage = refseq[
    (refseq["biosample"].notna()) &
    (refseq["biosample"] != "na") &
    (refseq["version_status"] == "latest") &
    (refseq["ftp_path"].notna()) &
    (refseq["ftp_path"] != "na")
].copy()
```

如果目标是优先使用高质量参考：

```python
assembly_level_priority = [
    "Complete Genome",
    "Chromosome",
    "Scaffold",
    "Contig",
]
```

如果一个 `biosample` 对多个 assembly，优先级建议：

```
version_status = latest
reference genome > representative genome > other
Complete Genome > Chromosome > Scaffold > Contig
annotation_date 较新
total_gene_count 非空
ftp_path 可用
```

### 4.4 RefSeq 输出表建议字段

```python
refseq_output_cols = [
    "biosample",
    "assembly_accession",
    "bioproject",
    "taxid",
    "species_taxid",
    "organism_name",
    "infraspecific_name",
    "isolate",
    "version_status",
    "assembly_level",
    "refseq_category",
    "genome_rep",
    "seq_rel_date",
    "asm_name",
    "ftp_path",
    "annotation_provider",
    "annotation_name",
    "annotation_date",
    "total_gene_count",
    "protein_coding_gene_count",
    "non_coding_gene_count",
]
```

---

## 5. SRA 元数据处理方案

SRA 侧最终要处理成一张以 RUN 为核心的表。

```
SRA_Accessions.tab + run.xml + experiment.xml + sample.xml
    → sra_run_metadata.tsv
```

该表的目标是：

```
每一行代表一个可下载 RUN。
每一行必须能追溯到 Experiment、Sample、BioSample。
每一行必须包含判断数据类型的 LibraryStrategy / LibrarySource。
```

---

## 6. SRA_[Accessions.tab](http://Accessions.tab) 处理

### 6.1 字段说明

`SRA_Accessions.tab` 常用字段如下：

| 序号 | 字段名 | 含义 | 在本流程中的作用 |
| --- | --- | --- | --- |
| 1 | Accession | 唯一标识符，如 SRR2401865 | 当 Type=RUN 时为下载 accession |
| 2 | Submission | 提交批次号 | 追踪提交来源 |
| 3 | Status | 状态，如 live / public / suppressed / withheld | 过滤可用记录 |
| 4 | Updated | 更新时间 | 版本追踪 |
| 5 | Published | 发布时间 | 版本追踪 |
| 6 | Received | 数据接收时间 | 版本追踪 |
| 7 | Type | RUN / EXPERIMENT / SAMPLE / STUDY 等 | 必须筛选 Type=RUN 作为下载单位 |
| 8 | Center | 提交机构 | 来源信息 |
| 9 | Visibility | public / private | 过滤 public 数据 |
| 10 | Alias | 别名 | 样本或实验别名 |
| 11 | Experiment | 实验编号，如 SRX* | 连接 experiment.xml |
| 12 | Sample | 样本编号，如 SRS* | 连接 sample.xml |
| 13 | Study | 研究编号，如 SRP* | 连接 study.xml |
| 14 | Loaded | 加载日期 | 版本追踪 |
| 15 | Spots | 测序 read / spot 数量 | 数据量 QC |
| 16 | Bases | 碱基总数 | 数据量 QC |
| 17 | Md5sum | 文件校验码 | 下载校验 |
| 18 | BioSample | 样本标识，如 SAMN* | 与 RefSeq biosample 关联 |
| 19 | BioProject | 项目标识，如 PRJNA* | 辅助校验，不做主 join |
| 20 | ReplacedBy | 被替换的记录 | 版本处理 |

### 6.2 处理后的目标形态

从 `SRA_Accessions.tab` 先得到：

```
sra_run_core.tsv
```

推荐保留字段：

```python
sra_accessions_keep = [
    "Accession",
    "Submission",
    "Status",
    "Updated",
    "Published",
    "Received",
    "Type",
    "Center",
    "Visibility",
    "Alias",
    "Experiment",
    "Sample",
    "Study",
    "Loaded",
    "Spots",
    "Bases",
    "Md5sum",
    "BioSample",
    "BioProject",
    "ReplacedBy",
]
```

过滤逻辑：

```python
sra_run_core = sra_accessions[
    (sra_accessions["Type"] == "RUN") &
    (sra_accessions["BioSample"].notna()) &
    (sra_accessions["BioSample"] != "na") &
    (sra_accessions["Visibility"] == "public")
].copy()

sra_run_core = sra_run_core.rename(columns={"Accession": "Run"})
```

如果 `Status` 使用 `live`：

```python
sra_run_core = sra_run_core[sra_run_core["Status"] == "live"]
```

如果 `Spots` / `Bases` 可用：

```python
sra_run_core = sra_run_core[
    (sra_run_core["Spots"] > 0) &
    (sra_run_core["Bases"] > 0)
]
```

---

## 7. SRA XML 文件组处理

### 7.1 run.xml：RUN 到 Experiment

`run.xml` 用于生成：

```
run_to_experiment.tsv
```

字段映射：

```
RUN@accession                    → Run
RUN@published                    → RunPublished，可选
RUN@total_spots                  → Spots，如存在
RUN@total_bases                  → Bases，如存在
RUN@size                         → SizeBytes，如存在
RUN/EXPERIMENT_REF@accession     → Experiment
```

目标表：

```python
run_to_experiment_cols = [
    "Run",
    "Experiment",
    "RunPublished",
    "Spots_xml",
    "Bases_xml",
    "SizeBytes",
]
```

### 7.2 experiment.xml：Experiment 到文库类型

`experiment.xml` 是判断是否为普通转录组或 TSS 相关数据的关键文件。

生成：

```
experiment_library.tsv
```

字段映射：

```
EXPERIMENT@accession                          → Experiment
EXPERIMENT/TITLE                              → ExperimentTitle
DESIGN/SAMPLE_DESCRIPTOR@accession            → Sample
DESIGN/LIBRARY_DESCRIPTOR/LIBRARY_NAME        → LibraryName
DESIGN/LIBRARY_DESCRIPTOR/LIBRARY_STRATEGY    → LibraryStrategy
DESIGN/LIBRARY_DESCRIPTOR/LIBRARY_SOURCE      → LibrarySource
DESIGN/LIBRARY_DESCRIPTOR/LIBRARY_SELECTION   → LibrarySelection
DESIGN/LIBRARY_DESCRIPTOR/LIBRARY_LAYOUT      → LibraryLayout
PLATFORM/*/INSTRUMENT_MODEL                   → Model
PLATFORM 的子节点名称                          → Platform
```

目标表：

```python
experiment_library_cols = [
    "Experiment",
    "ExperimentTitle",
    "Sample",
    "LibraryName",
    "LibraryStrategy",
    "LibrarySource",
    "LibrarySelection",
    "LibraryLayout",
    "Platform",
    "Model",
]
```

### 7.3 sample.xml：Sample 到 BioSample / TaxID

`sample.xml` 用于生成：

```
sample_biosample_taxon.tsv
```

字段映射：

```
SAMPLE@accession                                      → Sample
SAMPLE/IDENTIFIERS/EXTERNAL_ID namespace=BioSample   → BioSample
SAMPLE/SAMPLE_NAME/TAXON_ID                           → TaxID
SAMPLE/SAMPLE_NAME/SCIENTIFIC_NAME                    → ScientificName
SAMPLE/TITLE                                          → SampleTitle
SAMPLE_ATTRIBUTES/SAMPLE_ATTRIBUTE                    → strain / isolate / tissue / host / treatment 等
```

目标表：

```python
sample_biosample_taxon_cols = [
    "Sample",
    "BioSample",
    "TaxID",
    "ScientificName",
    "SampleTitle",
    "strain",
    "isolate",
    "tissue",
    "host",
    "treatment",
    "geo_loc_name",
    "collection_date",
]
```

### 7.4 study.xml：Study / BioProject 背景

`study.xml` 用于生成：

```
study_metadata.tsv
```

推荐字段：

```python
study_metadata_cols = [
    "Study",
    "BioProject",
    "StudyTitle",
    "StudyType",
    "StudyAbstract",
]
```

### 7.5 submission.xml：提交信息

`submission.xml` 用于生成：

```
submission_metadata.tsv
```

推荐字段：

```python
submission_metadata_cols = [
    "Submission",
    "Center",
    "LabName",
    "Submitter",
]
```

---

## 8. SRA 最终形态

SRA 侧最终建议形成两张核心表。

### 8.1 sra_run_core.tsv

来源：`SRA_Accessions.tab`

作用：判断哪些 accession 是可下载 RUN，保留基础状态、数据量和 BioSample。

核心字段：

```python
sra_run_core_cols = [
    "Run",
    "Type",
    "Status",
    "Visibility",
    "BioSample",
    "BioProject",
    "Experiment",
    "Sample",
    "Study",
    "Spots",
    "Bases",
    "Published",
    "Updated",
    "Center",
]
```

### 8.2 sra_run_metadata.tsv

来源：`sra_run_core.tsv + run.xml + experiment.xml + sample.xml`

作用：每一行代表一个 RUN，并包含判断是否转录组 / TSS 相关数据所需字段。

核心字段：

```python
sra_run_metadata_cols = [
    "Run",
    "Experiment",
    "Sample",
    "BioSample",
    "BioProject",
    "Study",

    "LibraryStrategy",
    "LibrarySource",
    "LibrarySelection",
    "LibraryLayout",
    "LibraryName",
    "Platform",
    "Model",

    "TaxID",
    "ScientificName",
    "SampleTitle",
    "strain",
    "isolate",
    "tissue",
    "host",
    "treatment",

    "Status",
    "Visibility",
    "Spots",
    "Bases",
    "Published",
    "Updated",
]
```

构建逻辑：

```python
xml_meta = run_to_experiment.merge(
    experiment_library,
    on="Experiment",
    how="left"
).merge(
    sample_biosample_taxon,
    on="Sample",
    how="left"
)

sra_run_metadata = sra_run_core.merge(
    xml_meta,
    on=["Run", "Experiment", "Sample"],
    how="left",
    suffixes=("_acc", "_xml")
)
```

---

## 9. 普通转录组与 TSS 相关数据判定

### 9.1 普通转录组 RNA-seq

普通转录组 RUN 的主筛选条件：

```python
is_regular_transcriptome = (
    (df["LibrarySource"] == "TRANSCRIPTOMIC") &
    (df["LibraryStrategy"] == "RNA-Seq")
)
```

### 9.2 TSS 相关数据

TSS 相关数据不能只看普通 RNA-seq。

更适合 TSS 的数据类型包括：

```python
tss_related_strategy = [
    "CAGE",
    "RAMPAGE",
    "TSS-Seq",
    "dRNA-Seq",
]
```

如果 SRA 中没有标准化写法，需要结合：

```
LibraryStrategy
LibrarySelection
ExperimentTitle
StudyTitle
Sample attributes
```

进行关键词识别。

建议分类：

```
普通转录组集合：RNA-Seq + TRANSCRIPTOMIC
TSS 高价值集合：CAGE / RAMPAGE / TSS-seq / dRNA-seq
特殊转录相关集合：Iso-Seq / miRNA-Seq / ncRNA-Seq
排除集合：WGS / WXS / ChIP-Seq / ATAC-seq / AMPLICON 等
```

### 9.3 排除示例

如果字段为：

```
LibraryStrategy = WGS
LibrarySource = GENOMIC
```

则该 RUN 可以下载，但不是转录组，也不是 TSS 直接相关数据。

---

## 10. RefSeq 与 SRA 的最终关联

关联主键：

```
RefSeq biosample ↔ SRA BioSample
```

不建议使用：

```
RefSeq bioproject ↔ SRA BioProject
```

原因：BioProject 是项目级容器，同一 BioProject 下可能包含多个样本、多个实验类型和多个物种。

关联代码：

```python
merged = refseq_linkage.merge(
    sra_run_metadata,
    left_on="biosample",
    right_on="BioSample",
    how="inner",
    suffixes=("_refseq", "_sra")
)
```

物种一致性检查：

```python
def taxid_match(row):
    sra_taxid = str(row.get("TaxID", ""))
    return sra_taxid in {
        str(row.get("taxid", "")),
        str(row.get("species_taxid", "")),
    }

merged["taxid_consistent"] = merged.apply(taxid_match, axis=1)
```

---

## 11. 最终输出表

最终建议形成：

```
refseq_sra_transcriptomic_runs.tsv
```

字段包括：

```python
final_output_cols = [
    # RefSeq side
    "assembly_accession",
    "biosample",
    "bioproject_refseq",
    "taxid",
    "species_taxid",
    "organism_name",
    "assembly_level",
    "refseq_category",
    "ftp_path",
    "annotation_provider",
    "annotation_name",
    "annotation_date",

    # SRA side
    "Run",
    "Experiment",
    "Sample",
    "BioSample",
    "BioProject_sra",
    "Study",

    # Library / assay decision
    "LibraryStrategy",
    "LibrarySource",
    "LibrarySelection",
    "LibraryLayout",
    "LibraryName",
    "Platform",
    "Model",

    # Sample / taxonomy
    "TaxID",
    "ScientificName",
    "strain",
    "isolate",
    "tissue",
    "host",
    "treatment",
    "taxid_consistent",

    # data size / status
    "Status",
    "Visibility",
    "Spots",
    "Bases",
    "Published",
    "Updated",
]
```

该表的每一行应代表：

```
一个 RefSeq assembly 对应的一个 SRA RUN。
这个 RUN 是可下载的。
这个 RUN 已经通过 LibraryStrategy / LibrarySource 进行了数据类型判定。
```

---

## 12. 下载方式

最终下载只使用 `Run` 字段。

示例：

```bash
prefetch SRRxxxxxxx
fasterq-dump --split-files SRRxxxxxxx
```

批量导出 RUN：

```python
final["Run"].drop_duplicates().to_csv(
    "download_runs.txt",
    index=False,
    header=False
)
```

批量下载：

```bash
while read run; do
    prefetch "$run"
    fasterq-dump --split-files "$run"
done < download_runs.txt
```

注意：下载阶段不再判断是否转录组；是否转录组应在 metadata 阶段由 `LibraryStrategy / LibrarySource` 判断完成。

---

## 13. 数据库统计

以下表格是在有 RUN 的前提下的数据统计：

| 数据库 | 记录数量 |
| --- | --- |
| SRR (NCBI SRA) | 38,659,225 |
| ERR (ENA) | 10,520,520 |
| DRR (DRA) | 831,405 |
| 合计 | 50,011,150 |

以下数据是直接统计 accession 开头前缀得到的结果：

```
SRA 前缀（提交元数据）: 2,329,730 条
ERA 前缀（提交元数据）: 5,542,197 条
DRA 前缀（提交元数据）: 25,165 条
```

说明：

```
以上是 Accession 前缀统计。
它与 SRR / ERR / DRR RUN 数量不是同一维度。
RUN 数量应以 Type=RUN 的记录为准。
```

---

## 14. QC 与风险点

### 14.1 BioSample 多对多

可能出现：

```
一个 BioSample → 多个 RUN
一个 BioSample → 多个 Experiment
一个 BioSample → 多个 RefSeq assembly
```

需要统计：

```python
runs_per_biosample = merged.groupby("biosample")["Run"].nunique()
experiments_per_biosample = merged.groupby("biosample")["Experiment"].nunique()
assemblies_per_biosample = merged.groupby("biosample")["assembly_accession"].nunique()
```

### 14.2 BioProject 不能作为主 join

BioProject 只做辅助校验，不做主关联键。

```
主 join：RefSeq biosample ↔ SRA BioSample
辅助 QC：RefSeq bioproject ↔ SRA BioProject
```

### 14.3 XML 与 SRA_[Accessions.tab](http://Accessions.tab) 需要互相校验

检查：

```
SRA_Accessions.tab 中 Type=RUN 的 Run 是否都能在 run.xml 中找到
run.xml 中的 Run 是否都能在 SRA_Accessions.tab 中找到
experiment.xml 中的 Experiment 是否能覆盖所有 Run 对应的 Experiment
sample.xml 中的 Sample 是否能覆盖所有 Experiment 对应的 Sample
```

### 14.4 TSS 数据不能只用普通 RNA-seq 代替

普通 RNA-seq 可以用于转录表达或转录本相关分析，但不一定能精确定位 TSS。

TSS 高价值数据应优先识别：

```
CAGE
RAMPAGE
TSS-seq
dRNA-seq
5′ end enriched RNA data
```

---

## 15. 最终结论

RefSeq 侧：

```
原始文件：assembly_summary_refseq.txt
处理结果：refseq_assembly_linkage.tsv
核心字段：biosample、assembly_accession、taxid、species_taxid、organism_name、ftp_path、annotation 信息
作用：提供 genome / annotation 信息和 BioSample 关联键
```

SRA 侧：

```
原始文件：SRA_Accessions.tab + run.xml + experiment.xml + sample.xml + study.xml + submission.xml
处理结果：sra_run_metadata.tsv
核心字段：Run、Experiment、Sample、BioSample、LibraryStrategy、LibrarySource、TaxID、ScientificName、Spots、Bases
作用：提供可下载 RUN，并判断 RUN 的数据类型
```

最终关联：

```
RefSeq biosample ↔ SRA BioSample
```

最终输出：

```
refseq_sra_transcriptomic_runs.tsv
```

最终下载：

```
只下载通过 metadata 判定的 RUN accession。
```
