# 2026-07-07 Step 3c no-exclusion 全量 404 shard 运行记录

## 1. 运行目标

生成不使用排除词作为 hard gate 的 wildtype A/B transcriptomic RNA-seq Run 下载候选表。

和 Step 3b 的区别：

```text
Step 3b:
  RNA-seq / TRANSCRIPTOMIC / library_selection allowlist
  + TAXON_ID 非空
  + A/B 级强 wildtype 证据
  + 无 mutant / treated / disease / transgenic 等排除词信号

Step 3c:
  RNA-seq / TRANSCRIPTOMIC / library_selection allowlist
  + TAXON_ID 非空
  + A/B 级强 wildtype 证据

排除词信号只进 QC，不再排除。
```

## 2. 运行位置

H100 用户目录：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering
```

正式输出目录：

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

## 3. 运行参数

```text
buckets = 404
remainders = 0-403
max_concurrent = 16
threads_per_shard = 8
```

## 4. 运行前验证

本地 fixture 测试：

```text
10 passed
```

GPT-5.3-Codex-Spark 代码审核结论：

```text
无阻断问题。
```

H100 单 shard 验证：

```text
buckets = 404
remainder = 0
input_run_count = 100,199
no-exclusion run pass = 1,167
重复运行 = SKIPPED_DONE
单 shard merge 校验通过
```

## 5. 全量结果

shard 状态：

```text
404 DONE
0 failed / blocked
```

合并计数：

```text
input_member_rows = 40,418,069
input_run_count = 40,408,206
strict_member_pass_rows = 471,792
strict_run_pass_rows = 471,792
```

这里的 `strict_*` 是兼容字段名。在 Step 3c 中，它表示：

```text
通过 no-exclusion gate 的 member 行数 / Run 数
```

## 6. 合并验证

```text
merged_member_parquet_rows = 471,792
merged_member_tsv_rows = 471,792
merged_run_download_rows = 471,792
merged_run_download_distinct_runs = 471,792
run_download_has_duplicate_runs = false
shard_manifest_identity_consistent = true
member_rows_match_manifest_sum = true
member_tsv_rows_match_manifest_sum = true
run_rows_match_manifest_sum = true
run_rows_match_distinct_runs = true
```

结论：

```text
最终 Run 下载表是一行一个 Run，没有重复 Run。
```

## 7. 关键 QC 解读

filter funnel：

```text
input_member_rows                    40,418,069
run_core_resolved                    40,418,069
run_core_experiment_ref_unambiguous  40,418,068
run_experiment_ref_matches           40,418,068
experiment_core_resolved             40,327,883
sample_core_resolved                 40,308,693
library_strategy_rnaseq               7,869,621
library_source_transcriptomic         6,473,555
library_selection_allowlist           6,183,817
taxon_id_nonempty                     6,183,817
wildtype_ab_strong                      471,792
strict_run_pass                         471,792
wildtype_ab_without_exclusion_terms_qc 254,589
```

这说明：

```text
普通 RNA-seq/transcriptomic/library_selection gate 后剩 6,183,817 个 Run。
A/B 级强 wildtype 证据后剩 471,792 个 Run。
如果继续要求无排除词，会回到 Step 3b 的 254,589 个 Run。
Step 3c 新增保留的，是带有排除词信号但仍有 A/B wildtype 强证据的 217,203 个 Run。
```

generic QC：

```text
wildtype_ab_with_exclusion_terms_rows = 217,203
wildtype_ab_with_exclusion_terms_runs = 217,203
experiment_sample_ref_mismatch_rows = 49,600
passed_samples_with_value_truncated_attributes = 31
```

member vs Run：

```text
all_members_pass = 471,792
partial_members_pass = 0
no_members_pass = 39,936,414
```

这说明本次通过的 no-exclusion Run 中没有 partial member pass；能进入下载表的 471,792 个 Run 都满足 all-members-pass。

## 8. 输出文件大小

```text
member_level.parquet      23M
member_level.tsv.gz       18M
runs_for_download.tsv.gz  15M
```

## 9. 当前结论

Step 3c no-exclusion 全量结果已经生成并通过合并校验。

后续如果按新规则下载，应该使用：

```text
wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
```

这个表的含义是：

```text
有普通 transcriptomic RNA-seq 语义、TAXON_ID 非空、A/B 级强 wildtype 证据，并且整个 Run 的所有 member 都通过的 Run 列表。
```

它不再保证：

```text
没有 treatment / disease / transgenic / perturbation 等排除词信号。
```

这些信号已经保留在 QC 中，后续可以作为解释字段或二次筛选依据。
