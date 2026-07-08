# SRA Run Member 头表与 XML 语义筛选流程日志

本文件用于持续记录本阶段流程从想法、测试、失败、修正到当前方案的演变。

它回答三个问题：

```text
当时想做什么？
实际测试发现了什么？
为什么流程改成现在这样？
```

## 2026-07-03 至 2026-07-06：确定头表入口

### 初始目标

从已有数据出发：

```text
SRA_Accessions
SRA_Run_Members
run.xml / experiment.xml / sample.xml
```

建立一个可以继续筛选普通野生型转录组数据的 Run 头表。

### 核心判断

`SRA_Run_Members` 可以作为主入口，因为它直接给出：

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

它比单纯从 `SRA_Accessions` 出发更直接，因为后续筛选需要：

```text
Run -> Experiment -> Sample/BioSample
```

这个关系链在 `SRA_Run_Members` 中已经存在。

### 已完成的头表处理

第一步硬筛选：

```text
Status = live
Spots > 0
Bases > 0
Experiment 非空
Sample 非空
BioSample 非空
```

第二步 join `SRA_Accessions Type=RUN`：

```text
保留 Visibility = public
```

当前后续主输入：

```text
/data3/m252202014/SRA/filtered_tables/sra_run_members_live_nonzero_public_20260703/tables/sra_run_members_live_nonzero_public_member_level.parquet
```

### 关键决策

不使用 run-level 表作为 XML 筛选入口。

原因：

```text
野生型不是 Run 自己的属性，而是 Run 关联的 biological sample set 的聚合结果。
少量 Run 有多个 member，如果提前 distinct Run，会丢失 member/sample 层面的判断依据。
```

## 2026-07-06：第一版想法，直接拼 XML 路径并现场解析

### 当时的想法

因为 XML 文件都存在，而且 XML 原文是最终证据，所以最直观的方案是：

```text
Run 用 Run accession 的 Submission 找 run.xml
Experiment 用 Experiment accession 的 Submission 找 experiment.xml
Sample 用 Sample accession 的 Submission 找 sample.xml
```

然后直接解析真实 XML：

```text
experiment.xml:
  LIBRARY_STRATEGY
  LIBRARY_SOURCE
  LIBRARY_SELECTION

sample.xml:
  TAXON_ID
  SAMPLE_ATTRIBUTE TAG/VALUE
```

### 做了什么

写了 direct XML 解析脚本：

```text
step3_xml_semantic_filtering/scripts/build_strict_xml_semantic_filter.py
```

做了本地 fixture 测试和 H100 pilot。

### 观察结果

规则本身可以工作：

```text
顺序 1,000 行：
  三类 XML 都能定位
  strict pass = 0
  证明空结果和 QC 可写出

targeted 200 行：
  strict member pass = 195
  strict run pass = 195
  证明正向路径可用
```

更完整的分层测试显示：

```text
随机 10,000 行：76 个 strict Run pass
transcriptome 富集 10,000 行：429 个 strict Run pass
negative/exclusion targeted：0 个 strict Run pass
multi-member 小集合：0 个 strict Run pass
```

### 暴露的问题

性能不可接受。

关键证据：

```text
随机 100,000 行 direct XML 性能 pilot：
  运行 48 分钟仍未写出 QC，被终止
```

原因：

```text
逐个 member 现场打开 XML 文件会产生大量随机 I/O 和重复解析。
同一个 Experiment / Sample 可能被多个 member 重复访问。
```

### 决策变化

direct XML 解析不再作为主流程。

保留用途：

```text
抽样审计
异常复核
通用索引结果的对照验证
```

## 2026-07-06：转向两段式语义表

### 新想法

不再每个 member 现场解析 XML。

改成：

```text
先把 unique Run / Experiment / Sample 的 XML 语义整理成表
再把语义表 join 回 member-level 头表
```

### 做了什么

写了 Step 3b 两段式脚本：

```text
step3b_xml_semantic_indexing/scripts/build_xml_semantic_tables.py
step3b_xml_semantic_indexing/scripts/join_xml_semantic_tables.py
```

### 观察结果

顺序 10,000 行：

```text
build semantic tables: 约 3 分钟
join member table: 约 1 秒
strict pass = 0
```

随机 10,000 行：

```text
build semantic tables: 约 7-12 分钟
join member table: < 1 秒
strict Run pass = 76
```

### 结论

join 本身很快，慢点仍然在 XML 解析和随机 I/O。

因此两段式比逐行解析更清楚，但仍不适合直接全量。

## 2026-07-06：验证已有通用 XML 索引是否能替代直接 XML

### 新问题

既然最终还是要把 XML 变成可查询语义表，那么已经建立好的通用 XML 索引能否直接承担这件事？

通用索引 core：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1/core
```

使用表：

```text
run_core.parquet
experiment_core.parquet
sample_core.parquet
sample_attribute_core.parquet
```

### 做了什么

写了对照验证脚本：

```text
step3b_xml_semantic_indexing/scripts/compare_generic_index_to_direct_pilot.py
```

比较内容：

```text
direct XML route 的 Run 通过集合
generic XML index route 的 Run 通过集合
direct/generic 的 member key 集合
Run -> Experiment_REF 一致性
Experiment -> Sample_REF 一致性
value_truncated 是否影响通过样本
```

### 验证结果

随机 10,000 行：

```text
direct XML Run pass = 76
generic index Run pass = 76
差集 = 0
```

transcriptome 富集 10,000 行：

```text
direct XML Run pass = 429
generic index Run pass = 429
差集 = 0
```

multi-member 小样本：

```text
direct XML Run pass = 0
generic index Run pass = 0
差集 = 0
```

### 结论

三组验证都显示：

```text
generic XML index result == direct XML parsing result
```

因此主流程切换为：

```text
member-level head table
  -> generic XML index core
  -> strict XML semantic gate
```

direct XML 只保留为审计和异常复核。

## 2026-07-06：通用索引路线 100k pilot

### 做了什么

写了正式入口脚本：

```text
step3b_xml_semantic_indexing/scripts/build_strict_from_generic_xml_index.py
```

先跑 QC-only 100k pilot。

### 结果

前 100,000 Run 烟测：

```text
strict Run pass = 149
total_time = 15.73 s
```

hash 分片约 100k Run：

```text
input Run = 100,199
strict Run pass = 601
total_time = 16.35 s
```

### 结论

通用索引路线速度足够进入生产前验证。

但不能直接一个进程跑全量，因为当前脚本会把当前 scope 内的 member 和 sample attribute 拉入 Python 聚合。

因此全量必须分片。

## 2026-07-07：生产前代码审核与安全修正

### 为什么要做

通用 XML 索引路线已经证明和 direct XML 结果一致，下一步就会产生可用于下载的 Run 表。这个阶段的风险不再是“筛选规则能不能找到阳性”，而是：

```text
会不会把不完整的 Run 拆开？
会不会无边界全量导致内存风险？
会不会把 RUN -> EXPERIMENT 不一致的数据错误放行？
QC 漏斗能不能被人按顺序读懂？
通用索引里如果同一实体有冲突语义，会不会随机取一条通过？
```

### 做了什么

用 GPT-5.3-Codex-Spark 做生产前代码审核，然后只采纳和数据安全、生产稳定性直接相关的修改：

```text
禁用无边界全量单进程
限制 --limit-rows 只能用于 qc-only
Run -> Experiment mismatch 作为 hard reject
filter_funnel 改成顺序漏斗
通用索引语义冲突作为 reject reason
Spots/Bases 输出保持 BIGINT
```

详细审核和输出 pilot 记录：

```text
step3b_xml_semantic_indexing/pilot_summaries/20260707_spark_review_and_output_pilots.md
```

### 效果

这一步把脚本从“能跑 pilot”推进到“可以安全跑生产 shard”。

本地测试从审核前的 13 项扩展到后续 14 项，覆盖：

```text
limit-rows 不允许写正式表
qc-only 不写 tables
zero-pass 也能写空输出
Run -> Experiment mismatch 不通过
语义冲突不随机通过
shard runner + merge fixture 可用
```

## 2026-07-07：单 shard 输出验证

### 为什么要做

前面的验证主要证明“筛选集合正确”。但正式生产还需要证明：

```text
非 qc-only 模式能稳定写出结果文件
zero-pass 情况也不会崩
真实 hash shard 的输出结构可以被下游合并脚本消费
```

### 做了什么

跑了两个 H100 输出验证：

```text
10k 非 qc-only:
  input Run = 10,000
  strict Run pass = 0
  目的：验证 zero-pass 输出也完整

hash404 r0:
  input Run = 100,199
  strict Run pass = 601
  total_time = 16.07 s
  目的：验证真实约 100k Run shard 的输出规模和速度
```

### 效果

确认每个 shard 可以稳定产生统一结构：

```text
tables/
qc/
manifest.json
```

这一步说明 hash404 作为生产分片大小是可用的：单片约 10 万 Run，输出很小，速度在十几秒级。

## 2026-07-07：补 shard 生产运行层

### 为什么要做

正式输入是 4,000 万级 Run/member 规模，不能让一个 Python 进程一次性读完整个 scope。需要把“筛选逻辑”和“生产调度”分开：

```text
筛选脚本只处理一个 shard
runner 负责启动多个 shard
merge 脚本负责合并完成的 shard
失败 shard 单独重跑
```

### 做了什么

新增两个生产辅助脚本：

```text
step3b_xml_semantic_indexing/scripts/run_generic_index_shards.py
step3b_xml_semantic_indexing/scripts/merge_generic_index_shards.py
```

核心分片规则：

```text
hash(Run) % buckets = remainder
```

这样能保证同一个 Run 的所有 member 都在同一个 shard 内，不会破坏 all-members-pass。

详细 shard 目录结构、失败重跑和合并规则放在：

```text
step3b_xml_semantic_indexing/docs/SHARD_PRODUCTION_PLAN.md
```

### 效果

生产层职责变清楚了：

```text
build_strict_from_generic_xml_index.py 负责一个 shard 的生物学/语义筛选
run_generic_index_shards.py 负责并发调度和状态记录
merge_generic_index_shards.py 负责合并与一致性验证
```

这一步降低了失败恢复成本：如果某个 shard 失败，只需要重跑对应 remainder，不影响已经 DONE 的 shard。

## 2026-07-07：H100 shard 并发探索

### 为什么要做

`buckets=404` 决定“切成多少片”，但还需要决定“同时跑多少片”。并发太低会慢；并发太高会让多个进程同时扫描 parquet，可能造成 I/O 拥堵或失败。

因此需要用真实 H100 输出做小规模并发探索。

### 做了什么

分别测试：

```text
max_concurrent = 2, 4, 8, 12, 16
threads_per_shard = 8
buckets = 404
```

汇总结果：

```text
c2:  4 shard, 0 failed, wall 38.836 s
c4:  4 shard, 0 failed, wall 22.827 s
c8:  8 shard, 0 failed, wall 28.436 s
c12: 12 shard, 0 failed, wall 33.654 s
c16: 16 shard, 0 failed, wall 35.473 s
```

详细记录：

```text
step3b_xml_semantic_indexing/pilot_summaries/20260707_shard_concurrency_and_merge.md
```

### 这个结果说明什么

```text
1. shard 并发能明显提高总吞吐。
2. 并发越高，单个 shard 会变慢，说明 I/O/并发扫描压力在增加。
3. 但到 c16 为止没有 shard 失败，整体 wall time 仍然最好。
4. c16 合并验证通过，Run 下载表没有重复 Run，merged 计数和各 shard manifest 总和一致。
```

因此当前推荐正式参数：

```text
buckets = 404
max_concurrent = 16
threads_per_shard = 8
```

参数含义：

```text
buckets:
  把所有 Run 切成多少个 hash shard。404 表示 hash(Run)%404。

max_concurrent:
  同时运行多少个 shard 进程。16 表示最多同时跑 16 个 remainder。

threads_per_shard:
  每个 shard 内部 DuckDB 使用多少线程。8 表示 PRAGMA threads=8。
```

推荐理由：

```text
hash404 单片约 10 万 Run，已经验证可写出；
c16 没有失败，合并验证通过；
16 * 8 = 128 DuckDB threads，低于 H100 的 192 cores；
按当前结果粗略外推，全量约 15-20 分钟。
```

保守回退：

```text
如果正式运行时出现 I/O 拥堵、单 shard 时间异常拉长或失败，降到 max_concurrent = 12。
```

当前仍未启动全量 404 shard。

## 2026-07-07：Step 3b 全量 404 shard 正式运行

### 为什么要做

前面的工作已经完成了三件事：

```text
通用 XML 索引路线与 direct XML 解析结果一致
单 shard 输出结构可用
c16 并发和合并验证通过
```

因此可以进入全量实施，生成真正用于后续 FASTQ 下载的 Run download 表。

### 做了什么

在 H100 用户目录运行全量：

```text
buckets = 404
max_concurrent = 16
threads_per_shard = 8
remainders = 0-403
```

输出目录：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3b_xml_semantic_indexing/production_runs/strict_wildtype_transcriptomic_rnaseq_generic_index_20260707
```

### 结果

```text
404 shard 全部 DONE
FAILED = 0
shard wall time = 830.55845 s
input Run = 40,408,206
strict Run pass = 254,589
```

合并验证：

```text
merged_run_download_rows = 254,589
merged_run_download_distinct_runs = 254,589
run_download_has_duplicate_runs = false
所有 merged 计数均匹配 shard manifest 总和
```

详细正式运行记录：

```text
step3b_xml_semantic_indexing/production_summaries/20260707_full_404_shard_run.md
```

### 当前判断

Step 3b 全量筛选已经完成。

下一步可以进入：

```text
FASTQ 下载策略设计
或先对 254,589 个 Run 做少量人工/抽样复核
```

## 2026-07-07：新增 Step 3c no-exclusion 版本

### 为什么要做

Step 3b 的正式全量结果已经可用，但它把 mutant / treated / disease / transgenic 等排除词作为 hard gate，因此最终得到的是更严格的 `254,589` 个 Run。

现在需要一个更宽松的版本：只要求普通 RNA-seq / TRANSCRIPTOMIC / library_selection allowlist、TAXON_ID 非空、A/B 级强 wildtype 证据，不再因为排除词直接排除。这样可以拿到 Step 3b funnel 中“强 wildtype A/B 证据后”的那批候选 Run，再把排除词信号作为 QC 留给后续解释或人工复核。

### 做了什么

新建独立阶段目录：

```text
step3c_xml_semantic_no_exclusion_filtering/
```

保留 Step 3b 严格版本的归档记录：

```text
step3b_xml_semantic_indexing/archives/strict_with_exclusion_20260707/ARCHIVE_RECORD.md
```

Step 3c 代码改动：

```text
1. 新主脚本：scripts/build_wildtype_ab_no_exclusion_from_generic_xml_index.py
2. member_pass 删除 no_exclusion_terms hard gate
3. 排除词信号仍写入 generic_index_qc，不再写入 rejection_reason_counts
4. 输出前缀改为 wildtype_ab_no_exclusion_transcriptomic_rnaseq
5. shard runner 默认指向 Step 3c 主脚本
6. merge 脚本改为合并 Step 3c 输出文件名
7. manifest 增加 gating_mode/output_prefix，明确产物身份
8. runner 增加已有 DONE shard 的 manifest identity 校验，防止旧 shard 被静默跳过
9. merge 增加跨 shard manifest identity 一致性校验
10. 清理 Step 3c 目录中的旧 direct XML 过程脚本和旧测试，移动到 E:\codex_delete
```

新增说明文件：

```text
step3c_xml_semantic_no_exclusion_filtering/README.md
step3c_xml_semantic_no_exclusion_filtering/PRODUCTION_RUN_PLAN.md
```

### 当前验证

本地 fixture 测试已经通过：

```text
conda run -n ai python -m pytest E:\TSS\02_stage2_run_members_head_table\step3c_xml_semantic_no_exclusion_filtering\tests -q

10 passed
```

测试重点：

```text
SRR_NEGATIVE 有 WT 强证据和 treatment 信号，Step 3c 中通过；
SRR_MULTI 只有一个 member 通过，因此 member-level 有通过行，但 Run 下载表不包含该 Run；
Run -> Experiment mismatch 仍然拒绝；
语义冲突仍然拒绝；
shard runner 和 merge 输出文件名正确。
篡改旧 shard manifest 后，runner 会 BLOCKED_INCOMPATIBLE_DONE，merge 会拒绝不一致 shard。
```

下一步：

```text
使用 GPT-5.3-Codex-Spark 审核 Step 3c 修改；
审核无阻断问题后，同步到 H100 做 shard 小验证；
再启动 Step 3c 全量 404 shard。
```

## 2026-07-07：Step 3c no-exclusion 全量运行完成

### 为什么要做

用户决定保留带有排除词信号但仍有 A/B 级强 wildtype 证据的 Run，因此需要在 Step 3b strict-with-exclusion 之外，生成一个 no-exclusion 版本的下载头表。

### 运行前检查

```text
本地 fixture 测试：10 passed
GPT-5.3-Codex-Spark 复审：无阻断问题
H100 单 shard 验证：remainder 0 通过，重复运行 SKIPPED_DONE，单 shard merge 通过
```

### 全量运行

H100 输出目录：

```text
/home/m252202014/TSS/02_stage2_run_members_head_table/step3c_xml_semantic_no_exclusion_filtering/production_runs/wildtype_ab_no_exclusion_transcriptomic_rnaseq_generic_index_20260707
```

结果：

```text
404 shard DONE
0 failed / blocked
input Run = 40,408,206
no-exclusion Run pass = 471,792
duplicate Run = false
```

关键解释：

```text
Step 3b strict-with-exclusion Run = 254,589
Step 3c no-exclusion Run = 471,792
差值 = 217,203
```

差值对应：

```text
wildtype_ab_with_exclusion_terms_runs = 217,203
```

也就是这些 Run 有 A/B 级强 wildtype 证据，但也出现了 treatment / disease / transgenic / perturbation 等排除词信号；Step 3c 按新规则保留它们，只在 QC 中记录。

正式记录：

```text
step3c_xml_semantic_no_exclusion_filtering/production_summaries/20260707_full_404_shard_no_exclusion_run.md
```

## 当前状态

已经完成：

```text
1. 头表入口确定
2. direct XML 规则验证
3. direct XML 性能瓶颈确认
4. generic XML index 与 direct XML 等价验证
5. generic XML index 正式脚本
6. GPT-5.3-Codex-Spark 审核和修正
7. 单 shard 非 QC-only 输出验证
8. shard 生产运行方案
9. shard runner / merge 脚本和本地 fixture 验证
10. H100 c2/c4/c8/c12/c16 小规模并发探索
11. c8/c16 合并验证
12. 全量 404 shard 正式运行和合并验证
13. Step 3c no-exclusion 版本代码和本地 fixture 测试
14. Step 3c no-exclusion 全量 404 shard 正式运行和合并验证
```

尚未完成：

```text
1. FASTQ 下载
```

## 当前生产原则

```text
不再逐条直接解析 XML 作为主流程
不允许 unbounded 全量单进程
正式运行必须按 Run hash shard
member-level 表用于审计和解释复杂样本
run download 表用于真正下载，必须 all-members-pass
Experiment -> Sample mismatch 保留 QC，不作为 hard reject
Run -> Experiment mismatch 作为 hard reject
```
