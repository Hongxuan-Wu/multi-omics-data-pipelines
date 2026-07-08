# SRA_Run_Members 头表构建与 RNA-seq 筛选流程

本文档记录当前 SRA 侧可下载转录组 Run 头表的实际构建流程。它从 `SRA_Run_Members` 出发，先得到可下载、public、关系字段完整的 member-level 头表，再用 SRA XML full index 判断普通转录组和 wildtype A/B 证据，最终输出可用于后续下载的 Run 列表。

本阶段对应代码包：

```text
tss/sra_run_members_head_table_pipeline/
```

当前阶段的目标不是直接下载 FASTQ，也不是直接下载转录本序列，而是生成一个可靠的 Run 头表：

```text
SRA_Run_Members
  -> hard filtered member-level head
  -> public member-level head
  -> XML semantic no-exclusion RNA-seq / wildtype A/B Run list
```

## 1. SRA_Run_Members 的情况及可用性

`SRA_Run_Members` 是 NCBI SRA metadata full snapshot 中的 RUN-member 关系表。它不是单纯的一行一个 Run 的表，而是以 Run 为核心，同时保留 member/sample 层级信息。

原始文件位置：

```text
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516/SRA_Run_Members
```

它对本流程有用，是因为它直接提供后续筛选需要的基本关系链：

```text
Run
Member_Name
Experiment
Sample
BioSample
Study
Spots
Bases
Status
```

其中最关键的是：

```text
Run -> Experiment -> Sample/BioSample
```

这个链路正好对应后续 XML 语义筛选：

```text
Experiment 用于查 library_strategy / library_source / library_selection
Sample/BioSample 用于查 TAXON_ID 和 sample attributes
Run 是最终下载单位
```

因此，`SRA_Run_Members` 可以作为 SRA 侧头表入口。相比直接从 `SRA_Accessions` 出发，它更适合保留 member 粒度和复杂样本关系。

需要注意的是，`SRA_Run_Members` 不能一开始就 `distinct Run`。少量 Run 可能有多个 member/sample。如果提前去重，会丢掉真实 biological sample set 的组成，后续 wildtype 判定会变得不可靠。

本流程采用的原则是：

```text
member-level 表用于审计和样本语义判断
Run-level 下载表只保留所有 member 都通过的 Run
```

## 2. Step 1：SRA_Run_Members 自身硬筛选

### 2.1 目的

第一步只处理 `SRA_Run_Members` 自己，不 join `SRA_Accessions`，也不查询 XML。目的很明确：

```text
先从 SRA_Run_Members 中拿到字段完整、测序量非零、状态为 live 的 Run-member 头表。
```

这样可以把“关系字段是否可用”和“public 可见性”分开处理，避免一开始混用多个官方来源导致问题难以解释。

### 2.2 筛选逻辑

硬筛选条件：

```text
Status = live
Spots > 0
Bases > 0
Run 非空
Experiment 非空
Sample 非空
BioSample 非空
```

其中 `Run 非空` 是安全条件。原始 profile 中 Run 缺失数为 0，但输出头表不能允许空主键进入后续流程。

保留字段：

```text
Run
Member_Name
Experiment
Sample
BioSample
Study
Spots
Bases
Status
```

这里仍然保持 member-level，不做 `distinct Run`。

### 2.3 输出路径

H100 输出目录：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_hard_filtered_20260703
```

主表：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_hard_filtered_20260703/tables/sra_run_members_hard_filtered_member_level.parquet
```

如果导出压缩 TSV：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_hard_filtered_20260703/tables/sra_run_members_hard_filtered_member_level.tsv.gz
```

### 2.4 结果

Step 1 得到的硬筛后头表规模为：

```text
member rows = 42,122,369
distinct Run = 42,112,506
```

这个结果表示：在 `SRA_Run_Members` 自身范围内，约 4,211 万个 Run 同时满足 live、非零测序量和 Experiment/Sample/BioSample 关系字段完整。

## 3. Step 2：join SRA_Accessions Visibility

### 3.1 目的

Step 1 已经解决了：

```text
SRA_Run_Members 中这个 Run 是否 live、Spots/Bases 是否大于 0、Experiment/Sample/BioSample 是否完整。
```

Step 2 只补一个问题：

```text
这个 Run 在 SRA_Accessions Type=RUN 中是否 public。
```

因此本阶段不重新用 `SRA_Accessions.Status/Spots/Bases` 做 hard gate。那些字段只作为审计和 mismatch QC。

### 3.2 join 逻辑

输入：

```text
Step 1 member-level head
SRA_Accessions Type=RUN parquet
```

join 条件：

```text
SRA_Run_Members.Run = SRA_Accessions.Accession
SRA_Accessions.Type = RUN
```

新增 hard gate：

```text
SRA_Accessions.Visibility = public
```

Accessions 中的以下字段用于补充审计：

```text
Status
Visibility
BioProject
BioSample
Spots
Bases
Experiment
Sample
Study
```

如果两个官方来源字段不一致，记录到 QC，不直接覆盖 Step 1 的关系链。

### 3.3 输出路径

H100 输出目录：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703
```

member-level 主表：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703/tables/sra_run_members_live_nonzero_public_member_level.parquet
```

run-level 聚合表：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703/tables/sra_run_members_live_nonzero_public_run_level.parquet
```

如果导出压缩 TSV：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703/tables/sra_run_members_live_nonzero_public_member_level.tsv.gz
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703/tables/sra_run_members_live_nonzero_public_run_level.tsv.gz
```

### 3.4 结果

Step 2 public 后的后续主输入为：

```text
member rows = 40,418,069
distinct Run = 40,408,206
```

这个表是后续 XML 语义筛选的正式入口。

为什么继续使用 member-level 表，而不是 run-level 表：

```text
wildtype 不是 Run 自己的属性，而是 Run 关联到的 biological sample set 的聚合标签。
如果一个 Run 有多个 member，必须逐个 member 判断后再聚合到 Run。
```

## 4. Step 3c：no-exclusion XML semantic filtering

### 4.1 目的

Step 3c 的目标是在 Step 2 public member-level 头表基础上，筛出普通 transcriptomic RNA-seq 且有 A/B 级强 wildtype 证据的 Run。

它使用已经构建好的 SRA XML full streaming v1 索引，而不是逐条打开原始 XML 文件。

XML 索引入口：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/core
```

核心表：

```text
run_core.parquet
experiment_core.parquet
sample_core.parquet
sample_attribute_core.parquet
```

### 4.2 为什么使用 XML full index

早期测试过直接拼接 XML 路径并现场解析 `run.xml / experiment.xml / sample.xml`。这个方法最接近原文，但在大规模数据上受随机 I/O 和 XML parse 成本限制，无法作为 4,000 万 Run 级别的主流程。

后续用 pilot 验证了：

```text
generic XML index 路线与 direct XML 解析在随机样本、transcriptome 富集样本和 multi-member 样本上结果一致。
```

因此正式流程采用：

```text
generic XML index = 主流程
direct XML 解析 = 抽样审计和异常复核
```

### 4.3 筛选逻辑

Experiment 级别普通转录组 gate：

```text
LIBRARY_STRATEGY = RNA-Seq
LIBRARY_SOURCE = TRANSCRIPTOMIC
LIBRARY_SELECTION in PCR, RANDOM, cDNA, RT-PCR, PolyA, RANDOM PCR, Oligo-dT, cDNA_oligo_dT
```

Sample 级别基础 gate：

```text
TAXON_ID 非空
```

Sample attribute 级别 wildtype A/B 强证据：

```text
A 级字段：genotype / phenotype / host_genotype / donor_genotype / strain/genotype 等
B 级字段：strain / isolate / cultivar / ecotype / breed / genetic_mod
```

这些字段的 value 必须是短而明确的 wildtype 表达，例如：

```text
WT
wild type
wild-type
wildtype
wt/wt
```

Step 3c 不再把排除词作为 hard gate。也就是说：

```text
mutant / treated / disease / transgenic / perturbation / reporter 等信号只进入 QC，不再排除。
```

这样做是为了得到“强 wildtype A/B 证据后、排除词过滤前”的宽松候选表。

### 4.4 all-members-pass

member-level 表会记录通过的 member 行，但真正下载时使用的是 Run accession。一个 Run 如果有多个 member，不能只下载其中一个 member 的 reads。因此 Run 下载表仍然要求：

```text
run_totals[Run] == run_passed[Run]
并且 run_passed[Run] > 0
```

含义是：

```text
一个 Run 的所有 member 都通过，Run 才能进入下载表。
```

### 4.5 输出路径

H100 正式输出目录：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707
```

最终 Run 下载表：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707/merged/tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
```

member-level 审计表：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707/merged/tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707/merged/tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.tsv.gz
```

### 4.6 结果

Step 3c 全量 404 shard 运行结果：

```text
input_member_rows = 40,418,069
input_run_count = 40,408,206
no-exclusion member pass = 471,792
no-exclusion Run pass = 471,792
```

合并验证：

```text
merged_run_download_rows = 471,792
merged_run_download_distinct_runs = 471,792
run_download_has_duplicate_runs = false
shard_manifest_identity_consistent = true
```

这说明最终下载表中一行就是一个唯一 Run，没有重复 Run。

## 5. 471,792 的结果解读

`471,792` 是当前 no-exclusion 规则下可进入后续下载候选表的 Run 数。

它代表：

```text
这些 Run 是 live/public/nonzero；
有 Experiment / Sample / BioSample 关系；
Experiment 语义符合普通 transcriptomic RNA-seq；
Sample 有 TAXON_ID；
Sample attributes 中有 A/B 级强 wildtype 证据；
整个 Run 的所有 member 都通过。
```

它不代表：

```text
这些 Run 一定没有 treatment / disease / transgenic / perturbation 等信号。
```

因为 Step 3c 已经把排除词从 hard gate 改成 QC。

完整漏斗如下：

```text
Step 2 public input                         40,408,206 Run
library_strategy = RNA-Seq                   7,869,554 Run
library_source = TRANSCRIPTOMIC              6,473,555 Run
library_selection allowlist                  6,183,817 Run
TAXON_ID 非空                                6,183,817 Run
A/B 级强 wildtype 证据                         471,792 Run
Step 3c no-exclusion final                    471,792 Run
如果继续要求 no_exclusion_terms                254,589 Run
```

因此：

```text
Step 3b strict-with-exclusion = 254,589 Run
Step 3c no-exclusion = 471,792 Run
差值 = 217,203 Run
```

这个差值对应：

```text
wildtype_ab_with_exclusion_terms_runs = 217,203
```

也就是：这些 Run 有 A/B 级 wildtype 强证据，但同时出现了排除词信号。Step 3c 保留它们，后续可以按研究目标决定是否二次筛掉。

按 Run accession 来源前缀统计：

| 来源 | Run 前缀 | 数量 |
|---|---:|---:|
| NCBI SRA | `SRR` | 397,585 |
| ENA/EBI | `ERR` | 71,335 |
| DDBJ/DRA | `DRR` | 2,872 |

这些前缀代表 accession 最初由哪个国际归档中心分配。三家会同步公共数据，但同步时不会把 `ERR/DRR` 改名成 `SRR`。

Run 级冗余检查：

```text
总行数 = 471,792
distinct Run = 471,792
重复 Run 行 = 0
```

所以按 Run accession 下载不会重复下载同一个 Run。

## 6. 当前输出的使用方式

后续如果要按当前宽松规则下载，使用：

```text
wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
```

如果要回看样本证据、排除词信号、Sample/Experiment 关系，使用：

```text
wildtype_ab_no_exclusion_transcriptomic_rnaseq_member_level.parquet
```

如果目标是更严格的“无处理、无疾病、无转基因、无扰动”的纯 wildtype control，则不应使用 Step 3c 结果直接下载，而应回到 Step 3b strict-with-exclusion 的 `254,589` Run，或在 Step 3c 表上继续按 QC 字段做二次筛选。

## 7. 代码和审核材料

本流程的代码快照、fixture 测试和正式运行记录保存在：

```text
tss/sra_run_members_head_table_pipeline/
```

主要入口：

```text
scripts/step1_hard_filter_run_members/build_sra_run_members_hard_filter.py
scripts/step2_join_accessions_visibility/build_sra_run_members_public_head.py
scripts/step3c_xml_semantic_no_exclusion_filtering/build_wildtype_ab_no_exclusion_from_generic_xml_index.py
scripts/step3c_xml_semantic_no_exclusion_filtering/run_generic_index_shards.py
scripts/step3c_xml_semantic_no_exclusion_filtering/merge_generic_index_shards.py
```

测试入口：

```text
tests/
```

本地测试命令：

```powershell
conda run -n ai python -m pytest E:\TSS_doc\tss\sra_run_members_head_table_pipeline\tests -q
```
