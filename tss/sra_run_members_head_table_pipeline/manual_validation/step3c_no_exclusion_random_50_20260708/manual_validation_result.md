# Step 3c no-exclusion 随机 50 条官网人工校验结果

## 1. 校验对象

```text
sample_records.tsv
sample_records.csv
```

抽样总体：

```text
Step 3c no-exclusion final Run table
population_rows = 471,792
sample_size = 50
seed = 20260708
```

## 2. 校验目标

人工到官方网页核验每条 Run 是否支持：

```text
1. RNA-seq / TRANSCRIPTOMIC
2. wildtype 相关证据
```

## 3. 校验结论

用户反馈：

```text
没有发现问题
```

因此本次 50 条随机抽样未发现与 Step 3c 筛选口径冲突的记录。

## 4. 对当前流程的含义

当前 Step 3c no-exclusion 头表可以作为后续阶段的主候选 Run 表继续使用。

后续主表：

```text
wildtype_ab_no_exclusion_transcriptomic_rnaseq_runs_for_download.tsv.gz
```

当前阶段可以视为完成：

```text
SRA_Run_Members hard filter
-> SRA_Accessions public visibility
-> XML semantic no-exclusion RNA-seq / wildtype A/B filter
-> 50 条官网人工抽查
```

下一阶段建议进入：

```text
FASTQ 下载策略
或 RefSeq / taxon / assembly 对接策略
```
