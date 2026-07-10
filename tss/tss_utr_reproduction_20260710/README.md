# S1 TSS/UTR 注释复现

## 当前方案

公司于 2026-07-10 指定使用 [zxgsy520/pegs](https://github.com/zxgsy520/pegs) 生成前期注释阶段的 transcript 和 PASA alignment 数据。现行方案固定 PEGS commit `043a69d6ad272affda6efdc40990ad3140899c63`，实现安全的 PEGS-compatible runner，不直接执行其中硬编码 `/Work/...` 路径的原始调度器。

- [现行设计](design.md)
- [现行实施计划](implementation_plan.md)
- [旧版设计归档](archive/design_pre_pegs_20260710.md)
- [旧版实施计划归档](archive/implementation_plan_pre_pegs_20260710.md)

主数据链：

```text
9 paired FASTQ
-> fastp
-> STAR
-> 9 x guided StringTie
-> StringTie merge
-> gffread
-> CD-HIT-EST
-> PEGS rename_id.py
-> SeqClean + UniVec
-> PASA/minimap2 alignment SQLite
-> PASA annotation update
-> AGAT keep longest isoform
-> structured comparison
```

## 执行状态

正式运行仍被阻断：

```text
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
```

9 个样本的 R1 第 9 位均为 100% `N`。公司与 PEGS 指定的 `-n 0` 会使审核子集输出 0 对 reads；未经用户明确批准，不得改为 `-n 1`，也不得启动九样本 STAR 及下游阶段。

当前已完成配置/样本表、运行隔离和初版 preflight。初版 preflight 尚有 5 个独立审查问题待修复；旧计划 Task 4-14 已停止，由新版实施计划取代。

## 已安装主工具

| 工具 | 版本 | 绝对 prefix |
| --- | --- | --- |
| fastp | 0.23.1 | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/fastp/env` |
| STAR | 2.7.9a | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/STAR/env` |
| StringTie | 2.2.0 | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/stringtie/env` |
| PASA | 2.5.2 | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env` |
| AGAT | 0.8.0 | `/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/agat/env` |

新版计划还需锁定 PEGS，并安装 gffread 0.12.7、CD-HIT 4.8.1、blast-legacy 2.2.26 和 NCBI UniVec 快照。PASA prefix 已包含 minimap2 2.31、samtools 1.23.1、SQLite 3.53.3 和 TransDecoder 6.0.0。

## 当前测试

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
bash tss/tss_utr_reproduction_20260710/tests/test_common.sh
bash tss/tss_utr_reproduction_20260710/tests/test_preflight.sh
```

这些测试只覆盖当前已实现基础，不表示 PEGS 新版完整流程已经完成。

## 文件隔离

每次运行只写 `work/$RUN_ID`、`logs/$RUN_ID`、`results/$RUN_ID` 和 `trash/$RUN_ID`。`reports/$RUN_ID` 仅保存小型 Markdown/TSV；第三方工具、UniVec、FASTQ、BAM、GTF、FASTA、SQLite 和生成 GFF3 均由 `tss/.gitignore` 屏蔽。

原始 FASTQ/FASTA/GFF 和公司 `S1.genome_new.gff3` 保持只读。公司结果只在最终 compare 阶段使用，不参与参数选择或 PASA 更新。
