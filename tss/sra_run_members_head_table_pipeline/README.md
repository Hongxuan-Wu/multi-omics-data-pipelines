# SRA_Run_Members 头表构建代码包

本目录保存 `SRA_Run_Members -> public member-level head -> XML semantic no-exclusion Run list` 这一阶段的代码快照、测试和运行记录。它的用途是给项目成员审查流程和代码，不保存全量数据文件。

## 1. 目录结构

```text
sra_run_members_head_table_pipeline/
├── README.md
├── scripts/
│   ├── step1_hard_filter_run_members/
│   │   └── build_sra_run_members_hard_filter.py
│   ├── step2_join_accessions_visibility/
│   │   └── build_sra_run_members_public_head.py
│   └── step3c_xml_semantic_no_exclusion_filtering/
│       ├── build_wildtype_ab_no_exclusion_from_generic_xml_index.py
│       ├── run_generic_index_shards.py
│       ├── merge_generic_index_shards.py
│       └── xml_semantic_common.py
├── tests/
│   ├── step1_hard_filter_run_members/
│   ├── step2_join_accessions_visibility/
│   └── step3c_xml_semantic_no_exclusion_filtering/
└── docs/
    ├── PROCESS_LOG.md
    ├── 20260707_full_404_shard_no_exclusion_run.md
    └── 20260707_full_404_shard_strict_with_exclusion_run.md
```

## 2. 三个阶段的代码入口

### Step 1：SRA_Run_Members 自身硬筛选

脚本：

```text
scripts/step1_hard_filter_run_members/build_sra_run_members_hard_filter.py
```

作用：

```text
从 SRA_Run_Members 中筛出 Status=live、Spots/Bases>0、Run/Experiment/Sample/BioSample 非空的 member-level 头表。
```

正式输出：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_hard_filtered_20260703
```

### Step 2：join SRA_Accessions Visibility

脚本：

```text
scripts/step2_join_accessions_visibility/build_sra_run_members_public_head.py
```

作用：

```text
在 Step 1 member-level 头表基础上，join SRA_Accessions Type=RUN，仅把 Visibility=public 作为新增 gate。
```

正式输出：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703
```

后续主输入：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703/tables/sra_run_members_live_nonzero_public_member_level.parquet
```

### Step 3c：XML semantic no-exclusion 筛选

脚本：

```text
scripts/step3c_xml_semantic_no_exclusion_filtering/build_wildtype_ab_no_exclusion_from_generic_xml_index.py
scripts/step3c_xml_semantic_no_exclusion_filtering/run_generic_index_shards.py
scripts/step3c_xml_semantic_no_exclusion_filtering/merge_generic_index_shards.py
scripts/step3c_xml_semantic_no_exclusion_filtering/xml_semantic_common.py
```

作用：

```text
使用 SRA XML full index 判断普通 transcriptomic RNA-seq、TAXON_ID 非空、A/B 级 strong wildtype evidence。
排除词信号只进入 QC，不作为 hard gate。
```

正式输出：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707
```

最终 Run 下载表：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707/merged/tables/wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
```

## 3. 本地 fixture 测试

在本机有 `conda` 和 `ai` 环境时，可从本目录运行：

```powershell
conda run -n ai python -m pytest E:\TSS_doc\tss\sra_run_members_head_table_pipeline\tests -q
```

这些测试只使用小 fixture 或临时生成的 Parquet，不读取 H100 全量数据。

测试覆盖重点：

```text
Step 1:
  dry-run 不读取缺失输入
  Status/Spots/Bases/Experiment/Sample/BioSample 硬筛选
  输出 manifest、QC 和表

Step 2:
  Visibility=public gate
  Accessions duplicate 防 join 放大
  member-level 与 run-level 输出

Step 3c:
  treatment 等排除词不再阻止 A/B wildtype 行通过
  multi-member Run 仍要求 all-members-pass
  Run -> Experiment mismatch 和语义冲突仍拒绝
  shard runner / merge / 旧 shard identity 校验
```

## 4. 审查时应重点看什么

```text
1. Step 1 是否只依赖 SRA_Run_Members 自身字段。
2. Step 2 是否只把 Visibility=public 作为新增 gate，而不是混用 Accessions.Status。
3. Step 3c 是否真的移除了 exclusion hard gate，同时仍把 exclusion 记录到 QC。
4. Run 下载表是否一行一个 Run，且没有重复 Run。
5. multi-member Run 是否按 all-members-pass 进入下载表。
6. shard runner 是否能断点恢复，并阻止旧 shard 混入新结果。
```

## 5. 关键结果

```text
Step 2 public input Run = 40,408,206
Step 3b strict-with-exclusion Run = 254,589
Step 3c no-exclusion Run = 471,792
Step 3c 相比 Step 3b 多保留 = 217,203
```

`471,792` 的含义和结果解读见：

```text
../SRA_Run_Members头表构建与RNA-seq筛选流程.md
docs/20260707_full_404_shard_no_exclusion_run.md
```
