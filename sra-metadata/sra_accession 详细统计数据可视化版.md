# SRA_Accessions 统计数据速览版

数据来源：`sra_accession 详细统计数据.md`

生成信息：

| 项目 | 值 |
|---|---:|
| Generated UTC | `2026-06-03T01:59:12.661147+00:00` |
| Parquet root | `/data/shared/sra_parquet/sra_accessions_by_type` |
| DuckDB version | `1.5.3` |
| Threads | `16` |
| Parquet elapsed | `51.894 s` |
| TSV baseline scan | `963.0 s` |
| Speedup | `18.56x` |
| Source audit comparison | `pass` |

## 1. 一眼结论

| 问题 | 结论 |
|---|---|
| 全库有多少 accession 记录？ | **148,211,048** 行，不含表头 |
| 最核心的三类实体有多少？ | RUN **50,013,612**，EXPERIMENT **44,607,471**，SAMPLE **44,540,766** |
| 可公开访问比例？ | public **139,153,756**，占 **93.89%** |
| 当前有效状态比例？ | live **131,929,435**，占 **89.01%** |
| 可直接作为下载候选的 RUN？ | live + public + Spots/Bases > 0：**40,437,905** |
| RUN live/public 中 Spots/Bases 缺失多少？ | **151,127**，占 RUN live/public 的 **0.37%** |
| RUN live/public 的主要关系孤儿？ | Experiment 孤儿 **172,622**，Sample 孤儿 **84,933**，Study 孤儿 **140,537** |
| Parquet 相比原始 TSV 审计快多少？ | **18.56x** |

## 2. 使用的过滤口径（还需要讨论）

如果目标是找“可下载的 RUN”，建议优先使用：

```sql
Type = 'RUN'
AND Status = 'live'
AND Visibility = 'public'
AND TRY_CAST(Spots AS BIGINT) > 0
AND TRY_CAST(Bases AS BIGINT) > 0
```

对应规模：

| 过滤步骤 | 剩余记录数 | 相对上一步保留率 | 说明 |
|---|---:|---:|---|
| RUN 总数 | 50,013,612 | 100.00% | 全部 RUN |
| RUN live | 42,295,745 | 84.57% | 当前有效 RUN |
| RUN live + public | 40,589,032 | 95.96% | 可公开访问 RUN |
| RUN live + public + Spots/Bases > 0 | **40,437,905** | **99.63%** | 推荐下载候选 |

## 3. 全库规模

| 指标 | 数值 |
|---|---:|
| column_count | 20 |
| data_lines | 148,211,048 |
| total_lines_including_header | 148,211,049 |

## 4. Type 分布

| Type | 数量 | 占全库比例 | 读法 |
|---|---:|---:|---|
| RUN | 50,013,612 | 33.74% | 一次测序运行，下载通常以 RUN 为单位 |
| EXPERIMENT | 44,607,471 | 30.10% | 实验设计，连接 RUN 与 SAMPLE/STUDY |
| SAMPLE | 44,540,766 | 30.05% | SRA 样本实体，可连接 BioSample |
| SUBMISSION | 7,897,148 | 5.33% | 提交记录 |
| STUDY | 807,530 | 0.54% | SRA 项目实体，可连接 BioProject |
| ANALYSIS | 344,521 | 0.23% | 分析对象，controlled_access 比例较高 |
| **合计** | **148,211,048** | **100.00%** |  |

## 5. Status 和 Visibility

### 5.1 Status

| Status | 数量 | 占全库比例 | 处理建议 |
|---|---:|---:|---|
| live | 131,929,435 | 89.01% | 默认保留 |
| unpublished | 11,084,693 | 7.48% | 默认排除，除非做库存审计 |
| suppressed | 5,194,233 | 3.50% | 默认排除 |
| withdrawn | 2,687 | 0.002% | 默认排除 |
| **合计** | **148,211,048** | **100.00%** |  |

### 5.2 Visibility

| Visibility | 数量 | 占全库比例 | 处理建议 |
|---|---:|---:|---|
| public | 139,153,756 | 93.89% | 默认保留 |
| controlled_access | 9,057,292 | 6.11% | 默认排除，除非有授权 |
| **合计** | **148,211,048** | **100.00%** |  |

## 6. Type × Status：每类实体当前状态

| Type | live | unpublished | suppressed | withdrawn | 合计 | live 占比 |
|---|---:|---:|---:|---:|---:|---:|
| RUN | 42,295,745 | 4,002,742 | 3,712,486 | 2,639 | 50,013,612 | 84.57% |
| EXPERIMENT | 39,756,685 | 3,732,452 | 1,118,302 | 32 | 44,607,471 | 89.13% |
| SAMPLE | 41,406,632 | 3,034,695 | 99,427 | 12 | 44,540,766 | 92.96% |
| SUBMISSION | 7,590,157 | 232,351 | 74,638 | 2 | 7,897,148 | 96.11% |
| STUDY | 719,757 | 79,043 | 8,728 | 2 | 807,530 | 89.13% |
| ANALYSIS | 160,459 | 3,410 | 180,652 | 0 | 344,521 | 46.57% |

重点：

- `SAMPLE` 的 live 占比最高，约 **92.96%**。
- `ANALYSIS` 的 live 占比只有 **46.57%**，suppressed 数量反而更多，后续不应把 ANALYSIS 当作主要下载入口。

## 7. Type × Visibility：每类实体是否公开

| Type | public | controlled_access | 合计 | public 占比 |
|---|---:|---:|---:|---:|
| RUN | 45,198,933 | 4,814,679 | 50,013,612 | 90.37% |
| EXPERIMENT | 42,288,919 | 2,318,552 | 44,607,471 | 94.80% |
| SAMPLE | 42,928,515 | 1,612,251 | 44,540,766 | 96.38% |
| SUBMISSION | 7,767,623 | 129,525 | 7,897,148 | 98.36% |
| STUDY | 805,482 | 2,048 | 807,530 | 99.75% |
| ANALYSIS | 164,284 | 180,237 | 344,521 | 47.69% |

重点：

- `RUN` public 占比 **90.37%**，仍有 **4,814,679** 个 RUN 是 controlled_access。
- `ANALYSIS` public 占比只有 **47.69%**，受控访问占比高。

## 8. 关键字段填充率

| 字段 | 非空记录数 | 占全库比例 | 主要用途 |
|---|---:|---:|---|
| BioSample | 123,423,527 | 83.28% | 与 RefSeq、BioSample 数据库关联的优先主键 |
| BioProject | 82,141,907 | 55.42% | 项目级辅助关联 |
| Study | 82,139,095 | 55.42% | SRA Study 关系 |
| Sample | 82,027,321 | 55.34% | SRA Sample 关系 |
| Loaded | 50,358,133 | 33.98% | 加载时间 |
| Experiment | 42,295,745 | 28.54% | RUN -> EXPERIMENT 关系 |

读法：

- `BioSample` 填充率最高，是后续 RefSeq-SRA 关联最重要的字段。
- `BioProject` 与 `Study` 接近，但它们是项目级关系，不能代替 BioSample 做精确样本 join。

## 9. RUN 数值字段质量

| 指标 | 数量 | 解读 |
|---|---:|---|
| run_spots_missing | 7,876,811 | RUN 中缺 Spots 的记录数 |
| run_bases_missing | 7,876,811 | RUN 中缺 Bases 的记录数 |
| run_spots_zero | 2,212 | Spots 为 0，默认排除 |
| run_bases_zero | 0 | Bases 没有 0 值 |
| run_spots_non_numeric | 0 | 无非数值异常 |
| run_bases_non_numeric | 0 | 无非数值异常 |

重点：

- `Spots`/`Bases` 没有非数值异常，但有大量 missing。
- 正式筛选下载 RUN 时应使用 `TRY_CAST(Spots AS BIGINT) > 0` 和 `TRY_CAST(Bases AS BIGINT) > 0`。

## 10. RUN live/public 质量细节

基线：`RUN live public total = 40,589,032`

| 检查项 | 数量 | 占 RUN live/public | 处理建议 |
|---|---:|---:|---|
| Experiment non-missing | 40,589,032 | 100.00% | 通过 |
| Sample non-missing | 40,563,940 | 99.94% | 少量缺失 |
| Study non-missing | 40,533,457 | 99.86% | 少量缺失 |
| BioSample non-missing | 40,558,831 | 99.93% | 适合做 RefSeq 关联 |
| BioProject non-missing | 40,174,329 | 98.98% | 项目级辅助字段 |
| Loaded non-missing | 40,589,032 | 100.00% | 通过 |
| Spots missing | 151,127 | 0.37% | 下载前排除 |
| Bases missing | 151,127 | 0.37% | 下载前排除 |
| Spots = 0 | 0 | 0.00% | 通过 |
| Bases = 0 | 0 | 0.00% | 通过 |
| Spots > 0 + Bases > 0 | **40,437,905** | **99.63%** | 推荐下载候选 |
| ReplacedBy non-missing | 0 | 0.00% | 无替代 accession |

## 11. 关系孤儿检查

这里的“孤儿”指 live/public 过滤后，当前实体指向的目标实体在对应 filtered 表中找不到。

| 来源 | 目标 | 孤儿数 | 占来源基线 | 优先级 |
|---|---|---:|---:|---|
| RUN live/public | EXPERIMENT | 172,622 | 0.43% | 高 |
| RUN live/public | SAMPLE | 84,933 | 0.21% | 中 |
| RUN live/public | STUDY | 140,537 | 0.35% | 高 |
| EXPERIMENT live/public | SAMPLE | 26,092 | 0.068% | 中 |
| EXPERIMENT live/public | STUDY | 78,957 | 0.207% | 中 |
| SAMPLE live/public | STUDY | 0 | 0.00% | 通过 |

处理建议：

- 做下载候选列表时，RUN 本身可下载性以 RUN 字段为准。
- 做样本级解释、RefSeq 关联或 Study 层级统计时，应对孤儿关系单独打 `qc_flags`。
- `SAMPLE -> STUDY` 在 live/public 过滤后无孤儿，是相对稳定的关系。

## 12. 前缀分布

| 前缀类别 | 数量 | 占全库比例 | 说明 |
|---|---:|---:|---|
| OTHER | 140,313,900 | 94.67% | 包含 ANALYSIS、EXPERIMENT、RUN、SAMPLE、STUDY |
| ERA | 5,542,197 | 3.74% | 全部是 SUBMISSION |
| SRA | 2,329,786 | 1.57% | 全部是 SUBMISSION |
| DRA | 25,165 | 0.02% | 全部是 SUBMISSION |
| **合计** | **148,211,048** | **100.00%** |  |

前缀 × Type：

| 前缀 | ANALYSIS | EXPERIMENT | RUN | SAMPLE | STUDY | SUBMISSION | 合计 |
|---|---:|---:|---:|---:|---:|---:|---:|
| OTHER | 344,521 | 44,607,471 | 50,013,612 | 44,540,766 | 807,530 | 0 | 140,313,900 |
| ERA | 0 | 0 | 0 | 0 | 0 | 5,542,197 | 5,542,197 |
| SRA | 0 | 0 | 0 | 0 | 0 | 2,329,786 | 2,329,786 |
| DRA | 0 | 0 | 0 | 0 | 0 | 25,165 | 25,165 |

## 13. 可复制的核心 SQL

### 13.1 统计 Type

```sql
SELECT Type, COUNT(*) AS n
FROM read_parquet('/data/shared/sra_parquet/sra_accessions_by_type/**/*.parquet', hive_partitioning=true)
GROUP BY Type
ORDER BY n DESC;
```

### 13.2 生成推荐下载候选 RUN

```sql
SELECT
  Accession AS run_accession,
  Experiment,
  Sample,
  Study,
  BioSample,
  BioProject,
  Spots,
  Bases
FROM read_parquet('/data/shared/sra_parquet/sra_accessions_by_type/Type=RUN/*.parquet')
WHERE Status = 'live'
  AND Visibility = 'public'
  AND TRY_CAST(Spots AS BIGINT) > 0
  AND TRY_CAST(Bases AS BIGINT) > 0;
```

### 13.3 按 BioSample 查询可下载 RUN

```sql
SELECT
  Accession AS run_accession,
  Experiment,
  Sample,
  Study,
  BioSample,
  BioProject,
  Spots,
  Bases
FROM read_parquet('/data/shared/sra_parquet/sra_accessions_by_type/Type=RUN/*.parquet')
WHERE BioSample = 'SAMN00000000'
  AND Status = 'live'
  AND Visibility = 'public'
  AND TRY_CAST(Spots AS BIGINT) > 0
  AND TRY_CAST(Bases AS BIGINT) > 0;
```

<details>
<summary>展开：Type × Status × Visibility 明细矩阵</summary>

### RUN

| Status | public | controlled_access | 合计 |
|---|---:|---:|---:|
| live | 40,589,032 | 1,706,713 | 42,295,745 |
| unpublished | 3,915,168 | 87,574 | 4,002,742 |
| suppressed | 694,619 | 3,017,867 | 3,712,486 |
| withdrawn | 114 | 2,525 | 2,639 |

### EXPERIMENT

| Status | public | controlled_access | 合计 |
|---|---:|---:|---:|
| live | 38,094,445 | 1,662,240 | 39,756,685 |
| unpublished | 3,617,802 | 114,650 | 3,732,452 |
| suppressed | 576,640 | 541,662 | 1,118,302 |
| withdrawn | 32 | 0 | 32 |

### SAMPLE

| Status | public | controlled_access | 合计 |
|---|---:|---:|---:|
| live | 39,950,652 | 1,455,980 | 41,406,632 |
| unpublished | 2,924,380 | 110,315 | 3,034,695 |
| suppressed | 53,471 | 45,956 | 99,427 |
| withdrawn | 12 | 0 | 12 |

### STUDY

| Status | public | controlled_access | 合计 |
|---|---:|---:|---:|
| live | 717,870 | 1,887 | 719,757 |
| unpublished | 78,884 | 159 | 79,043 |
| suppressed | 8,726 | 2 | 8,728 |
| withdrawn | 2 | 0 | 2 |

### SUBMISSION

| Status | public | controlled_access | 合计 |
|---|---:|---:|---:|
| live | 7,482,916 | 107,241 | 7,590,157 |
| unpublished | 216,253 | 16,098 | 232,351 |
| suppressed | 68,452 | 6,186 | 74,638 |
| withdrawn | 2 | 0 | 2 |

### ANALYSIS

| Status | public | controlled_access | 合计 |
|---|---:|---:|---:|
| live | 160,459 | 0 | 160,459 |
| unpublished | 3,317 | 93 | 3,410 |
| suppressed | 508 | 180,144 | 180,652 |

</details>

## 14. 校验状态

| 校验项 | 结果 |
|---|---|
| 前缀合计 = data_lines | 通过 |
| Type 合计 = data_lines | 通过 |
| Status 合计 = data_lines | 通过 |
| Visibility 合计 = data_lines | 通过 |
| total_lines_including_header - 1 = data_lines | 通过 |
| Source audit comparison status | `pass` |
