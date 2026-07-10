# S1 TSS/UTR 注释复现 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立并运行一条可审计、可恢复、严格隔离原始文件的九样本 RNA-seq 注释流程，产出 `S1.genome_reproduced.gff3`，并与公司版 `S1.genome_new.gff3` 做结构和候选 TSS/UTR 对比。

**Architecture:** 使用仓库现有的 Bash 风格实现一个阶段化驱动器，每个阶段只写入不可变 run ID 对应的 `work/`、`logs/`、`results/`，并在通过输出校验后写入完成标记。五个主工具通过绝对 conda prefix 调用；PASA 对齐数据库与注释更新数据库分离，AGAT 负责最终标准化与官方比较工具调用，少量 AWK/Perl 脚本只负责结构化 QC 和候选 TSS 表格。

**Tech Stack:** Bash 5、coreutils、awk、Perl `JSON::PP`、fastp 0.23.1、STAR 2.7.9a、StringTie 2.2.0、PASA 2.5.2（GMAP、BLAT、samtools、SQLite）、AGAT 0.8.0、Git。

## Global Constraints

- 原始目录 `tss/resources/` 和软件目录 `tss/tools/` 在所有执行脚本中视为只读；禁止任何输出路径解析到这两个目录。
- 大文件和过程文件只允许进入 `work/$RUN_ID/`、`logs/$RUN_ID/`、`results/$RUN_ID/` 或 `trash/$RUN_ID/`，这些目录必须由 `tss/.gitignore` 屏蔽。
- `reports/$RUN_ID/` 只允许 Markdown/TSV 小型报告，单文件不得超过 10 MiB；阶段程序不能把 FASTQ、BAM、GTF、SQLite 或 GFF3 过程文件写入 reports。
- 参考 FASTA/GFF 必须先复制或 reflink 到 `work/$RUN_ID/reference/`；STAR、StringTie、PASA 只读取副本。
- 原始 FASTQ 只允许被 fastp 读取；运行前后均验证 18 份官方 MD5，并比较原始文件清单、大小和 mtime。
- 五个主工具版本固定为 fastp 0.23.1、STAR 2.7.9a、StringTie 2.2.0、PASA 2.5.2、AGAT 0.8.0。
- 所有 conda prefix 使用绝对路径；PASA 启动器固定为 `$PASA_HOME/Launch_PASA_pipeline.pl`，不能依赖当前 shell 的 `PATH`。
- 流程图 fastp 参数 `-n 0 -q 20` 已证实会清空当前数据；正式运行必须等待用户明确批准参数偏差。当前推荐候选为 `-n 1 -q 20`。
- 不以公司版 GFF3 反向调参；公司版只作为只读审核与最终比较基准。
- PASA 不使用会覆盖数据库的 replace 操作；失败产物只移动到 `trash/`，不删除文件。
- 长任务使用 `nohup bash ... >...log 2>&1 &` 启动，记录 PID、开始时间、结束时间和退出码。
- 测试运行目录使用被忽略的 `work/tests/$TEST_ID/`；测试结束后保留证据或移动到 `trash/tests/`，不执行删除式清理。
- 默认 `THREADS=32`、`SAMPLE_PARALLELISM=1`、`MIN_FREE_GB=300`；输入、输出、线程可由命令行覆盖，算法参数不可由命令行静默覆盖。
- 普通 RNA-seq 只能产生候选 TSS；报告中不得将转录本 5' 端写成实验验证 TSS。

---

## 1. 已确认事实与停止边界

| 项目 | 当前事实 | 实施影响 |
| --- | --- | --- |
| 原始数据 | 9 个双端样本，18 个 BGZF FASTQ，约 53 GB | 九个样本独立 fastp、STAR、StringTie，之后合并 |
| fastp 阻断 | 9 个样本各抽检 10,000 条 R1，第 9 位 `N` 比例均为 100% | `-n 0` 不得进入正式运行；参数决策作为硬门禁 |
| 软件调用 | 五个工具及 PASA 的 GMAP/BLAT 已通过功能测试 | 不再安装软件，只实现固定入口和版本检查 |
| PASA 副文件 | PASA 会在 FASTA 旁写 `.fai`，并在当前目录写 checkpoint | PASA 只能在 run-local 工作目录运行 |
| PASA 入口 | conda 激活设置 `PASAHOME`，但不把它加入 `PATH` | 必须调用启动器完整路径 |
| 原始文件 | 4 个受控参考文件校验和已记录，原始测序目录仅有 FASTQ/MD5 | pre/post manifest 必须完全一致 |
| 可用磁盘 | 2026-07-10 检查约 1,564 GB | 300 GB 门禁当前可满足，正式运行时重新检查 |

**停止边界：** Task 1-11 可以在 `FASTP_POLICY_STATUS=blocked` 状态下完成实现和静态测试；Task 12 的九样本烟雾测试及 Task 13-14 的正式运行，必须等用户明确批准 fastp 策略后才能开始。

## 2. 实施文件结构

```text
tss/tss_utr_reproduction_20260710/
├── design.md
├── implementation_plan.md
├── README.md
├── config/
│   ├── pipeline.env
│   ├── samples.tsv
│   ├── alignAssembly.config.in
│   └── annotCompare.config.in
├── scripts/
│   ├── lib/common.sh
│   ├── preflight.sh
│   ├── snapshot_inputs.sh
│   ├── check_fastq_pairs.pl
│   ├── run_fastp.sh
│   ├── run_star.sh
│   ├── estimate_strandedness.pl
│   ├── run_stringtie.sh
│   ├── render_pasa_configs.sh
│   ├── run_pasa_align.sh
│   ├── run_pasa_update.sh
│   ├── run_agat_finalize.sh
│   ├── check_fastp_json.pl
│   ├── gff3_to_tables.awk
│   ├── compare_annotations.sh
│   ├── run_pipeline.sh
│   └── launch_pipeline.sh
├── tests/
│   ├── fixtures/
│   │   ├── reference.fa
│   │   ├── original.gff3
│   │   ├── reproduced.gff3
│   │   ├── fastp_zero.json
│   │   ├── fastp_pass.json
│   │   ├── strandedness.gff3
│   │   └── strandedness.sam
│   ├── test_config_contracts.sh
│   ├── test_common.sh
│   ├── test_preflight.sh
│   ├── test_fastp_gate.sh
│   ├── test_stage_commands.sh
│   ├── test_gff3_comparison.sh
│   └── test_orchestrator.sh
├── reports/
├── work/                  # Git ignored
├── logs/                  # Git ignored
├── results/               # Git ignored
└── trash/                 # Git ignored
```

## 3. 稳定接口

| 接口 | 输入 | 输出/保证 |
| --- | --- | --- |
| `scripts/preflight.sh --run-id ID --mode MODE` | `MODE=smoke|full`、配置、样本表 | 初始化 run 目录、校验工具/输入/磁盘、复制参考、写 before manifest |
| `scripts/run_fastp.sh --run-id ID --mode MODE --threads N` | 9 对原始 FASTQ | 9 对 clean FASTQ、JSON/HTML、`fastp_summary.tsv` |
| `scripts/run_star.sh --run-id ID --threads N` | clean FASTQ、参考副本 | STAR 索引、9 个排序 BAM、bedGraph、`star_summary.tsv` |
| `scripts/run_stringtie.sh --run-id ID --threads N` | 9 个 BAM、参考 GFF 副本 | 9 个 GTF、`mergelist.txt`、`merged.gtf` |
| `scripts/run_pasa_align.sh --run-id ID --threads N` | `merged.gtf`、参考 FASTA 副本 | transcript FASTA、alignment SQLite、PASA assembly 文件 |
| `scripts/run_pasa_update.sh --run-id ID --threads N` | alignment DB 副本、原始 GFF 副本 | PASA 更新版 GFF3 |
| `scripts/run_agat_finalize.sh --run-id ID` | PASA GFF3 | longest-isoform GFF3、标准化最终 GFF3 |
| `scripts/compare_annotations.sh --run-id ID` | 复现版和公司版 GFF3 | feature、ID、坐标、UTR、候选 TSS、融合/拆分比较报告 |
| `scripts/run_pipeline.sh` | run ID、mode、threads、stop-after、resume | 顺序执行阶段，仅跳过哈希验证通过的 `.done` 阶段 |
| `scripts/launch_pipeline.sh` | 与驱动器相同的参数 | nohup 会话、PID 文件、driver 日志 |

## 4. 任务计划

### Task 1: 建立配置、样本清单与忽略契约

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/README.md`
- Create: `tss/tss_utr_reproduction_20260710/config/pipeline.env`
- Create: `tss/tss_utr_reproduction_20260710/config/samples.tsv`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh`
- Modify: `tss/.gitignore`

**Interfaces:**
- Consumes: 已审核的 `design.md`、9 个样本真实路径、五个工具绝对 prefix。
- Produces: 后续所有脚本唯一读取的静态配置和五列样本表 `sample_id/r1/r2/r1_md5/r2_md5`。

- [ ] **Step 1: 写配置契约测试并确认失败**

测试必须断言：配置文件存在；样本表恰有 9 条数据；样本 ID 为 S1-S9 且不重复；每行 4 个输入文件存在；`pipeline.env` 初始为 blocked；`work/logs/results/trash` 均被 Git 忽略；原始 FASTA/GFF/公司版 GFF3/流程图仍被 Git 跟踪。

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
```

Expected: FAIL，首个失败原因是配置或样本表尚不存在。

- [ ] **Step 2: 写入固定配置**

`config/pipeline.env` 使用以下键和值：

```bash
PROJECT_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/tss_utr_reproduction_20260710
TSS_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss
RESOURCE_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources
RAW_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001
TOOL_ROOT=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools
CONDA_EXE=/opt/miniconda3/bin/conda
REFERENCE_FASTA=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/S1.genome.fasta
REFERENCE_GFF=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/S1.genome.gff
COMPANY_GFF=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/S1.genome_new.gff3
FLOW_IMAGE=/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/tss注释流程.png
FASTP_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/fastp/env
STAR_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/STAR/env
STRINGTIE_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/stringtie/env
PASA_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env
AGAT_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/agat/env
PASA_HOME=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env/opt/pasa-2.5.2
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
FASTP_QUAL=20
FASTP_MIN_PASS_FRACTION=0.50
SMOKE_READ_PAIRS=50000
STAR_GENOME_SA_INDEX_NBASES=11
PASA_MAX_INTRON_LENGTH=500000
PASA_TOP_ALIGNMENTS=1
DEFAULT_THREADS=32
SAMPLE_PARALLELISM=1
MIN_FREE_GB=300
```

- [ ] **Step 3: 写入精确样本表**

`samples.tsv` 使用以下精确内容，不得使用通配符在运行时猜测配对关系：

```text
sample_id	r1	r2	r1_md5	r2_md5
S1	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S1-BY2105/WH25005593-BY20250509-3-S1-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S1-BY2105/WH25005593-BY20250509-3-S1-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S1-BY2105/WH25005593-BY20250509-3-S1-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S1-BY2105/WH25005593-BY20250509-3-S1-BY2105_combined_R2.fastq.gz.md5
S2	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S2-BY2105/WH25005593-BY20250509-3-S2-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S2-BY2105/WH25005593-BY20250509-3-S2-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S2-BY2105/WH25005593-BY20250509-3-S2-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S2-BY2105/WH25005593-BY20250509-3-S2-BY2105_combined_R2.fastq.gz.md5
S3	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S3-BY2105/WH25005593-BY20250509-3-S3-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S3-BY2105/WH25005593-BY20250509-3-S3-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S3-BY2105/WH25005593-BY20250509-3-S3-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S3-BY2105/WH25005593-BY20250509-3-S3-BY2105_combined_R2.fastq.gz.md5
S4	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S4-BY2105/WH25005593-BY20250509-3-S4-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S4-BY2105/WH25005593-BY20250509-3-S4-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S4-BY2105/WH25005593-BY20250509-3-S4-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S4-BY2105/WH25005593-BY20250509-3-S4-BY2105_combined_R2.fastq.gz.md5
S5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S5-BY2105/WH25005593-BY20250509-3-S5-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S5-BY2105/WH25005593-BY20250509-3-S5-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S5-BY2105/WH25005593-BY20250509-3-S5-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S5-BY2105/WH25005593-BY20250509-3-S5-BY2105_combined_R2.fastq.gz.md5
S6	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S6-BY2105/WH25005593-BY20250509-3-S6-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S6-BY2105/WH25005593-BY20250509-3-S6-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S6-BY2105/WH25005593-BY20250509-3-S6-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S6-BY2105/WH25005593-BY20250509-3-S6-BY2105_combined_R2.fastq.gz.md5
S7	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S7-BY2105/WH25005593-BY20250509-3-S7-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S7-BY2105/WH25005593-BY20250509-3-S7-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S7-BY2105/WH25005593-BY20250509-3-S7-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S7-BY2105/WH25005593-BY20250509-3-S7-BY2105_combined_R2.fastq.gz.md5
S8	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S8-BY2105/WH25005593-BY20250509-3-S8-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S8-BY2105/WH25005593-BY20250509-3-S8-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S8-BY2105/WH25005593-BY20250509-3-S8-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S8-BY2105/WH25005593-BY20250509-3-S8-BY2105_combined_R2.fastq.gz.md5
S9	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S9-BY2105/WH25005593-BY20250509-3-S9-BY2105_combined_R1.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S9-BY2105/WH25005593-BY20250509-3-S9-BY2105_combined_R2.fastq.gz	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S9-BY2105/WH25005593-BY20250509-3-S9-BY2105_combined_R1.fastq.gz.md5	/data/p252701008/projects/multi-omics-data-pipelines/tss/resources/裂殖壶菌原始数据-BYT2025041001/Sample_WH25005593-BY20250509-3-S9-BY2105/WH25005593-BY20250509-3-S9-BY2105_combined_R2.fastq.gz.md5
```

- [ ] **Step 4: 扩展 Git 忽略规则并写 README 状态**

在 `tss/.gitignore` 增加：

```gitignore
/tss_utr_reproduction_20260710/trash/
```

README 必须列出快速测试命令、正式运行阻断状态、五个工具入口、输出目录和“公司版只读、不用于调参”的约束。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
git diff --check
```

Expected: `[PASS] config contracts`，`git diff --check` 无输出。

Commit:

```bash
git add tss/.gitignore tss/tss_utr_reproduction_20260710/README.md tss/tss_utr_reproduction_20260710/config tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
git commit -m "feat(tss): 建立复现流程配置与样本清单"
```

### Task 2: 实现公共运行库与路径隔离

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/lib/common.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_common.sh`

**Interfaces:**
- Consumes: `config/pipeline.env`。
- Produces: `die`、`log`、`assert_absolute`、`assert_safe_output_path`、`assert_process_output_path`、`assert_report_output_path`、`init_run_layout`、`move_to_trash`、`run_conda`、`mark_stage_done`、`stage_is_valid`。

- [ ] **Step 1: 写路径隔离和完成标记失败测试**

测试覆盖：相对 prefix 被拒绝；`resources/`、`tools/` 输出被拒绝；run-local `work/logs/results/reports/trash` 输出通过；已有 run ID 在非 resume 模式下被拒绝；完成标记只有在配置哈希和全部输出 SHA-256 一致时有效。

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_common.sh
```

Expected: FAIL，因为 `scripts/lib/common.sh` 尚不存在。

- [ ] **Step 2: 实现安全路径和 run 目录接口**

核心接口必须采用以下行为：

```bash
assert_safe_output_path() {
  local resolved
  resolved="$(realpath -m "$1")"
  case "${resolved}" in
    "${RESOURCE_ROOT}"|"${RESOURCE_ROOT}/"*|"${TOOL_ROOT}"|"${TOOL_ROOT}/"*)
      die "输出路径落入只读目录：${resolved}"
      ;;
  esac
  case "${resolved}" in
    "${PROJECT_ROOT}/work/"*|"${PROJECT_ROOT}/logs/"*|"${PROJECT_ROOT}/results/"*|"${PROJECT_ROOT}/reports/"*|"${PROJECT_ROOT}/trash/"*) ;;
    *) die "输出路径不在允许目录：${resolved}" ;;
  esac
}

run_conda() {
  local prefix="$1"
  shift
  assert_absolute "${prefix}"
  "${CONDA_EXE}" run --no-capture-output -p "${prefix}" "$@"
}
```

`assert_process_output_path` 在 `assert_safe_output_path` 基础上只接受 `work/logs/results/trash`；所有五工具命令的输出参数必须先通过该检查。`assert_report_output_path` 只接受 `reports/$RUN_ID/`，postflight 检查其单文件大小不超过 10 MiB。

`init_run_layout` 创建 `reference/fastp/star/stringtie/pasa_align/pasa_update/agat/validation/state`，并拒绝覆盖已有目录。`--resume` 只允许进入同一配置哈希的已有 run。

- [ ] **Step 3: 实现非删除式失败隔离与阶段标记**

`move_to_trash PATH REASON` 必须移动到 `trash/$RUN_ID/$REASON.<timestamp>.<basename>`；目标冲突时递增数字后缀。`mark_stage_done STAGE OUTPUT...` 写入配置哈希和每个输出 SHA-256；`stage_is_valid` 逐项复算，任一不一致返回失败。

- [ ] **Step 4: 运行测试和静态禁令扫描**

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_common.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/lib/common.sh
```

Expected: `[PASS] common isolation and state contracts`。

- [ ] **Step 5: 提交**

```bash
git add tss/tss_utr_reproduction_20260710/scripts/lib/common.sh tss/tss_utr_reproduction_20260710/tests/test_common.sh
git commit -m "feat(tss): 增加运行隔离与阶段状态管理"
```

### Task 3: 实现工具、输入和磁盘预检

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/snapshot_inputs.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/check_fastq_pairs.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/preflight.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_preflight.sh`

**Interfaces:**
- Consumes: 配置、样本表、原始输入、五个 conda prefix。
- Produces: `work/$RUN_ID/reference/`、`reports/$RUN_ID/input_manifest.before.tsv`、`reports/$RUN_ID/tool_versions.tsv`、`state/preflight.done`。

预检内部执行顺序固定为：参数与路径解析 → fastp 策略门禁 → 工具版本与磁盘 → MD5 与完整 FASTQ 配对扫描 → 参考副本与注释检查。blocked 状态必须在读取 53 GB FASTQ 前快速退出。

- [ ] **Step 1: 写预检失败测试**

覆盖缺失 FASTQ、错误 MD5、工具版本不匹配、磁盘低于阈值、FASTA/GFF 副本哈希不一致、`MODE=full` 且 fastp 状态 blocked 六种失败；任何失败都不能生成 `preflight.done`。

- [ ] **Step 2: 实现输入快照**

`snapshot_inputs.sh --run-id "$RUN_ID" --phase before|after` 输出固定列：

```text
kind	path	size_bytes	mtime_epoch	checksum_type	checksum
```

4 个受控资源使用 SHA-256；18 个 FASTQ 使用官方 MD5 文件中的值并实际执行 `md5sum -c`；18 个 MD5 文件自身使用 SHA-256。after 阶段必须与 before 逐行一致。

- [ ] **Step 3: 实现五工具固定入口检查**

预检逐一执行：

```bash
run_conda "${FASTP_PREFIX}" fastp --version
run_conda "${STAR_PREFIX}" STAR --version
run_conda "${STRINGTIE_PREFIX}" stringtie --version
run_conda "${PASA_PREFIX}" "${PASA_HOME}/Launch_PASA_pipeline.pl" --version
run_conda "${AGAT_PREFIX}" agat_sp_keep_longest_isoform.pl --help
```

版本必须精确匹配全局约束。另记录 PASA prefix 中 `gmap`、`blat`、`samtools`、`sqlite3` 的路径、包版本和二进制 SHA-256。

- [ ] **Step 4: 实现完整 FASTQ 配对检查**

`check_fastq_pairs.pl` 使用 PASA prefix 已安装的 `IO::Uncompress::Gunzip` 同时流式读取 R1/R2，不生成解压文件。逐条验证四行 FASTQ 结构、read name 去除 `/1`、`/2` 和空格后缀后相等、sequence/quality 等长、R1/R2 record 数一致；输出每样本 pair 数、最短/最长 read length 和错误记录号到 `reports/$RUN_ID/fastq_inventory.tsv`。九个样本全部读取，不以头部抽样代替完整检查。

- [ ] **Step 5: 实现磁盘、策略、参考副本和注释门禁**

检查可用空间不少于 300 GB。`MODE=full|smoke` 时要求 `FASTP_POLICY_STATUS=approved`；blocked 状态返回固定退出码 42。通过后以 `cp --reflink=auto --preserve=timestamps` 创建 FASTA/GFF 副本并用 `cmp` 和 SHA-256 双重验证。

在副本上运行 `agat_sp_statistics.pl --gff ... --gs ...`，要求原始注释 gene 数为 10,370；另外验证所有 GFF seqid 均存在于 FASTA、坐标不超 contig、gene/mRNA ID 唯一、Parent 可解析。所有 AGAT 和检查输出写入 `reports/$RUN_ID/input_annotation/`，原始 GFF 保持只读。

- [ ] **Step 6: 验证当前 blocked 行为**

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_preflight.sh
bash tss/tss_utr_reproduction_20260710/scripts/preflight.sh --run-id "preflight_block_test_$(date '+%Y%m%d_%H%M%S')" --mode full
/opt/miniconda3/bin/conda run --no-capture-output -p /data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env perl -c tss/tss_utr_reproduction_20260710/scripts/check_fastq_pairs.pl
```

Expected: 单元测试 PASS；真实 full 预检退出码 42，并明确打印 `fastp policy is blocked`，不启动 fastp。

- [ ] **Step 7: 提交**

```bash
git add tss/tss_utr_reproduction_20260710/scripts/preflight.sh tss/tss_utr_reproduction_20260710/scripts/snapshot_inputs.sh tss/tss_utr_reproduction_20260710/scripts/check_fastq_pairs.pl tss/tss_utr_reproduction_20260710/tests/test_preflight.sh
git commit -m "feat(tss): 增加工具与原始输入预检"
```

### Task 4: 实现 fastp 阶段和数据兼容性门禁

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/check_fastp_json.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/fastp_zero.json`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/fastp_pass.json`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_fastp_gate.sh`

**Interfaces:**
- Consumes: `samples.tsv`、已批准 fastp 策略、原始 FASTQ。
- Produces: `work/$RUN_ID/fastp/$SAMPLE/`、`reports/$RUN_ID/fastp_summary.tsv`、`state/fastp.done`。

- [ ] **Step 1: 写 JSON 门禁测试并确认失败**

`fastp_zero.json` 模拟 100,000 reads 输入、0 reads 输出；`fastp_pass.json` 模拟 100,000 reads 输入、99,874 reads 输出。测试要求前者失败，后者输出 pass fraction `0.998740`。

- [ ] **Step 2: 使用 JSON::PP 实现结构化解析器**

解析器调用接口固定为：

```bash
run_conda "${PASA_PREFIX}" perl scripts/check_fastp_json.pl \
  --json "$JSON" \
  --sample "$SAMPLE" \
  --min-pass-fraction "${FASTP_MIN_PASS_FRACTION}"
```

输出一行 TSV：`sample/input_reads/output_reads/input_pairs/output_pairs/pass_fraction/q20_rate/q30_rate/gc_content/too_many_n_reads`。当输出为 0、read 数为奇数或 pass fraction 小于 0.50 时返回非零。

- [ ] **Step 3: 实现每样本 fastp 命令**

正式模式不得加入流程图外的过滤参数：

```bash
run_conda "${FASTP_PREFIX}" fastp \
  --in1 "$R1" \
  --in2 "$R2" \
  --out1 "$OUT_R1" \
  --out2 "$OUT_R2" \
  --json "$JSON" \
  --html "$HTML" \
  --thread "$THREADS" \
  -n "${FASTP_MAX_N}" \
  -q "${FASTP_QUAL}"
```

smoke 模式只额外加入 `--reads_to_process 50000`。每个样本完成后要求两个输出非空、`gzip -t` 通过、JSON 门禁通过；任一样本失败立即停止，不跳过样本。

- [ ] **Step 4: 增加明确的参数决策检查点**

保持以下初始状态并停止正式执行：

```bash
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
```

只有用户明确批准后，实施者才能在独立提交中改为：

```bash
FASTP_POLICY_STATUS=approved
FASTP_MAX_N=1
```

提交说明必须记录：9 个样本 R1 第 9 位系统性 `N`，以及 S1 50,000 对 reads 的 `-n 0`/`-n 1` 对照结果。

- [ ] **Step 5: 运行测试并提交实现**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_fastp_gate.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh
git add tss/tss_utr_reproduction_20260710/scripts/check_fastp_json.pl tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh tss/tss_utr_reproduction_20260710/tests
git commit -m "feat(tss): 增加fastp质控与非空门禁"
```

### Task 5: 实现 STAR 索引、九样本比对与 BAM 门禁

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_star.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/estimate_strandedness.pl`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_strandedness.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/strandedness.gff3`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/strandedness.sam`

**Interfaces:**
- Consumes: 参考 FASTA 副本、9 对 fastp 输出。
- Produces: `work/$RUN_ID/star/index/`、9 个坐标排序 BAM、bedGraph、STAR 日志、`reports/$RUN_ID/star_summary.tsv`、`reports/$RUN_ID/strandedness.tsv`。

- [ ] **Step 1: 写 STAR 命令和输出契约测试**

测试要求脚本包含 `genomeSAindexNbases 11`、`SortedByCoordinate`、`bedGraph`、`intronMotif`、`readFilesCommand zcat`；禁止使用 `resources/S1.genome.fasta`；BAM 校验必须调用 PASA prefix 内的 samtools。

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
```

Expected: FAIL，因为 STAR 脚本尚不存在。

- [ ] **Step 2: 实现共享索引**

```bash
run_conda "${STAR_PREFIX}" STAR \
  --runMode genomeGenerate \
  --runThreadN "$THREADS" \
  --genomeDir "$RUN_ROOT/star/index" \
  --genomeFastaFiles "$RUN_ROOT/reference/S1.genome.fasta" \
  --genomeSAindexNbases "${STAR_GENOME_SA_INDEX_NBASES}"
```

索引完成后要求 `Genome`、`SA`、`SAindex`、`genomeParameters.txt` 均非空，再写 `star_index.done`。

- [ ] **Step 3: 实现九样本独立比对**

```bash
run_conda "${STAR_PREFIX}" STAR \
  --runThreadN "$THREADS" \
  --genomeDir "$RUN_ROOT/star/index" \
  --readFilesIn "$CLEAN_R1" "$CLEAN_R2" \
  --readFilesCommand zcat \
  --outFileNamePrefix "$SAMPLE_DIR/${SAMPLE}." \
  --outSAMtype BAM SortedByCoordinate \
  --outWigType bedGraph \
  --outSAMstrandField intronMotif
```

每个 BAM 必须通过：

```bash
run_conda "${PASA_PREFIX}" samtools quickcheck "$BAM"
run_conda "${PASA_PREFIX}" samtools view -c "$BAM"
```

总 alignment 数必须大于 0。不得设置流程图未给出的错配、多重比对、两遍比对或剪接过滤参数。

- [ ] **Step 4: 解析 STAR 指标**

从每个 `Log.final.out` 结构化提取 input reads、uniquely mapped、multi-mapped、too many loci、too short、splice junction 和 mismatch rate。只对“输入为 0”或“无任何 alignment”设硬失败，不根据公司结果设置 mapping-rate 阈值。

- [ ] **Step 5: 统计但不应用链特异性**

`estimate_strandedness.pl` 解析运行目录 GFF 副本的 exon，排除同时被正负链注释覆盖的区域；从 `samtools view -f 64 -F 2308` 流式读取 primary mapped R1，解析 CIGAR reference blocks，最多统计 1,000,000 条落入单一链 exon 的 informative R1。输出 R1 与转录本同向/反向计数和比例：同向比例不低于 0.80 标记 `fr-secondstrand`，反向比例不低于 0.80 标记 `fr-firststrand`，否则标记 `unstranded_or_ambiguous`。该结果仅进入报告，不能自动添加 StringTie `--rf` 或 `--fr`。

fixture 同时包含正链、负链、跨内含子 CIGAR 和正负链重叠区域；`test_strandedness.sh` 分别验证 same、opposite、ambiguous 计数及 0.80 判定边界。

- [ ] **Step 6: 运行语法和命令测试并提交**

```bash
bash -n tss/tss_utr_reproduction_20260710/scripts/run_star.sh
/opt/miniconda3/bin/conda run --no-capture-output -p /data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pasa/env perl -c tss/tss_utr_reproduction_20260710/scripts/estimate_strandedness.pl
bash tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
bash tss/tss_utr_reproduction_20260710/tests/test_strandedness.sh
git add tss/tss_utr_reproduction_20260710/scripts/run_star.sh tss/tss_utr_reproduction_20260710/scripts/estimate_strandedness.pl tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh tss/tss_utr_reproduction_20260710/tests/test_strandedness.sh tss/tss_utr_reproduction_20260710/tests/fixtures/strandedness.gff3 tss/tss_utr_reproduction_20260710/tests/fixtures/strandedness.sam
git commit -m "feat(tss): 增加STAR索引与九样本比对"
```

### Task 6: 实现单样本 StringTie 与九样本并集

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_stringtie.sh`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh`

**Interfaces:**
- Consumes: 9 个已校验 BAM、运行目录参考 GFF 副本。
- Produces: `work/$RUN_ID/stringtie/samples/$SAMPLE.gtf`、`mergelist.txt`、`merged.gtf`、`reports/$RUN_ID/stringtie_summary.tsv`。

- [ ] **Step 1: 扩展失败测试**

测试要求：每样本必须单独调用 StringTie；guide 必须是 run-local GFF；不得出现 `--rf`、`--fr`、`-e`、`-t`；merge list 必须严格为 S1-S9 九行。

- [ ] **Step 2: 实现单样本 guided assembly**

```bash
run_conda "${STRINGTIE_PREFIX}" stringtie "$BAM" \
  -G "$RUN_ROOT/reference/S1.genome.gff" \
  -p "$THREADS" \
  -o "$SAMPLE_GTF"
```

每个 GTF 要求非空且至少包含一个 `transcript` 行。记录 transcript、exon 数量和文件 SHA-256。

- [ ] **Step 3: 实现固定顺序 merge**

先逐行验证 9 个 GTF 非空，再生成绝对路径 `mergelist.txt`：

```bash
run_conda "${STRINGTIE_PREFIX}" stringtie --merge \
  -G "$RUN_ROOT/reference/S1.genome.gff" \
  -p "$THREADS" \
  -o "$RUN_ROOT/stringtie/merged.gtf" \
  "$RUN_ROOT/stringtie/mergelist.txt"
```

要求 merged transcript 数大于 0，并报告九样本 transcript 总数、merged 数和去冗余比例。

- [ ] **Step 4: 运行测试并提交**

```bash
bash -n tss/tss_utr_reproduction_20260710/scripts/run_stringtie.sh
bash tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git add tss/tss_utr_reproduction_20260710/scripts/run_stringtie.sh tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git commit -m "feat(tss): 增加StringTie组装与九样本合并"
```

### Task 7: 生成 PASA 配置和转录本 FASTA

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/config/alignAssembly.config.in`
- Create: `tss/tss_utr_reproduction_20260710/config/annotCompare.config.in`
- Create: `tss/tss_utr_reproduction_20260710/scripts/render_pasa_configs.sh`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh`

**Interfaces:**
- Consumes: run ID、PASA SQLite 绝对路径、`merged.gtf`、参考 FASTA 副本。
- Produces: 两份 run-local 配置、无注释行 GTF、`merged_transcripts.fasta`。

- [ ] **Step 1: 写配置渲染测试**

测试用 run-local 假路径渲染配置，要求没有未替换 token，DATABASE 为绝对 SQLite 路径，参数与设计文档完全一致。

- [ ] **Step 2: 写 alignment 配置模板**

```text
DATABASE=@DATABASE@
validate_alignments_in_db.dbi:--MIN_PERCENT_ALIGNED=90
validate_alignments_in_db.dbi:--MIN_AVG_PER_ID=95
subcluster_builder.dbi:-m=50
```

- [ ] **Step 3: 写 annotation compare 配置模板**

```text
DATABASE=@DATABASE@
cDNA_annotation_comparer.dbi:--MIN_PERCENT_OVERLAP=50
cDNA_annotation_comparer.dbi:--MIN_PERCENT_PROT_CODING=40
cDNA_annotation_comparer.dbi:--MIN_PERID_PROT_COMPARE=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_LENGTH_FL_COMPARE=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_LENGTH_NONFL_COMPARE=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_ALIGN_LENGTH=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_OVERLAP_GENE_REPLACE=80
cDNA_annotation_comparer.dbi:--MAX_UTR_EXONS=2
cDNA_annotation_comparer.dbi:--GENETIC_CODE=universal
```

不写 `MIN_FL_ORF_SIZE`、`TRUST_FL_STATUS`、`STOMP_HIGH_PERCENTAGE_OVERLAPPING_GENE`，从而保持 PASA 2.5.2 代码默认。

- [ ] **Step 4: 实现转录本提取**

先仅去除 GTF 注释行，避免 PASA helper 对 StringTie 头部产生无意义警告：

```bash
awk '$0 !~ /^#/' "$RUN_ROOT/stringtie/merged.gtf" > "$RUN_ROOT/pasa_align/merged.features.gtf"
run_conda "${PASA_PREFIX}" \
  "${PASA_HOME}/misc_utilities/cufflinks_gtf_genome_to_cdna_fasta.pl" \
  "$RUN_ROOT/pasa_align/merged.features.gtf" \
  "$RUN_ROOT/reference/S1.genome.fasta" \
  > "$RUN_ROOT/pasa_align/merged_transcripts.fasta"
```

要求 GTF transcript 数与 FASTA `>` 条目数完全一致、条目 ID 唯一、序列非空。

- [ ] **Step 5: 运行测试并提交**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git add tss/tss_utr_reproduction_20260710/config tss/tss_utr_reproduction_20260710/scripts/render_pasa_configs.sh tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git commit -m "feat(tss): 固定PASA配置与转录本提取"
```

### Task 8: 实现 PASA alignment assembly

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_pasa_align.sh`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh`

**Interfaces:**
- Consumes: alignment config、参考 FASTA 副本、merged transcript FASTA。
- Produces: `S1_alignment.sqlite`、GMAP/BLAT alignment、PASA assemblies GFF3/GTF/BED 和运行日志。

- [ ] **Step 1: 扩展 PASA 安全测试**

测试要求：启动器使用完整 `$PASA_HOME` 路径；aligners 为 `gmap,blat`；top alignment 为 1；max intron 为 500000；不得出现数据库覆盖参数；当前工作目录必须是 `work/$RUN_ID/pasa_align/`。

- [ ] **Step 2: 实现新数据库与检查点恢复分支**

数据库不存在时：

```bash
run_conda "${PASA_PREFIX}" "${PASA_HOME}/Launch_PASA_pipeline.pl" \
  -c "$RUN_ROOT/pasa_align/alignAssembly.config" \
  -C -R \
  -g "$RUN_ROOT/reference/S1.genome.fasta" \
  -t "$RUN_ROOT/pasa_align/merged_transcripts.fasta" \
  --ALIGNERS gmap,blat \
  --CPU "$THREADS" \
  -N "${PASA_TOP_ALIGNMENTS}" \
  -I "${PASA_MAX_INTRON_LENGTH}"
```

数据库已存在且 stage 未完成时，保留同一工作目录和 checkpoint，仅去掉 `-C` 后重跑 `-R`。不得重建或覆盖已有数据库。

- [ ] **Step 3: 实现 PASA 输出门禁**

要求 SQLite 非空且至少包含 `cdna_info`、`alignment`、`align_link`、`clusters`、`asmbl_link` 五张表；`S1_alignment.sqlite.pasa_assemblies.gff3` 非空；GMAP 和 BLAT 均有有效 alignment 记录；有效 assembled transcript 数大于 0。

- [ ] **Step 4: 运行测试并提交**

```bash
bash -n tss/tss_utr_reproduction_20260710/scripts/run_pasa_align.sh
bash tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git add tss/tss_utr_reproduction_20260710/scripts/run_pasa_align.sh tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git commit -m "feat(tss): 增加PASA转录本比对组装"
```

### Task 9: 实现 PASA annotation compare/update

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_pasa_update.sh`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh`

**Interfaces:**
- Consumes: alignment SQLite、annotation config 模板、运行目录原始 GFF/FASTA 副本。
- Produces: 独立 update SQLite、PASA annotation compare 日志、唯一更新版 GFF3。

- [ ] **Step 1: 写数据库分离测试**

测试要求 update 阶段先 reflink/copy alignment DB 到 `pasa_update/S1_update.sqlite`，annot config 只指向副本；alignment DB 的 SHA-256 在 update 前后必须一致；公司版 GFF3 不得出现在 PASA 命令中。

- [ ] **Step 2: 实现注释更新命令**

```bash
run_conda "${PASA_PREFIX}" "${PASA_HOME}/Launch_PASA_pipeline.pl" \
  -c "$RUN_ROOT/pasa_update/annotCompare.config" \
  -A -L \
  --annots "$RUN_ROOT/reference/S1.genome.gff" \
  -g "$RUN_ROOT/reference/S1.genome.fasta" \
  -t "$RUN_ROOT/pasa_align/merged_transcripts.fasta" \
  --CPU "$THREADS" \
  --GENETIC_CODE universal
```

命令只执行一次 annotation compare/update。若失败，将整个 update attempt 移入 `trash/$RUN_ID/`，再从未修改的 alignment DB 建立新 attempt；不得在失败 DB 上强制覆盖。

- [ ] **Step 3: 捕获动态 PASA 输出**

在命令前写 attempt 起始 marker，命令后查找本次新生成且唯一匹配 `S1_update.sqlite.gene_structures_post_PASA_updates.*.gff3` 的文件，复制为 `work/$RUN_ID/pasa_update/S1.pasa.updated.gff3`。要求 GFF3 非空、含 gene 和 mRNA、所有坐标位于参考 contig 范围内。

- [ ] **Step 4: 运行测试并提交**

```bash
bash -n tss/tss_utr_reproduction_20260710/scripts/run_pasa_update.sh
bash tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git add tss/tss_utr_reproduction_20260710/scripts/run_pasa_update.sh tss/tss_utr_reproduction_20260710/tests/test_stage_commands.sh
git commit -m "feat(tss): 增加PASA注释比较与更新"
```

### Task 10: 实现 AGAT 最终整理与结构化比较

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_agat_finalize.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/gff3_to_tables.awk`
- Create: `tss/tss_utr_reproduction_20260710/scripts/compare_annotations.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/reference.fa`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/original.gff3`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/reproduced.gff3`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_gff3_comparison.sh`

**Interfaces:**
- Consumes: PASA 更新版 GFF3、公司版只读 GFF3、参考 FASTA 副本。
- Produces: `results/$RUN_ID/S1.genome_reproduced.gff3` 和 `reports/$RUN_ID/validation/` 下的统计、差异、候选 TSS 表。

- [ ] **Step 1: 写正负链候选 TSS 和结构差异测试**

fixture 包含一个正链 mRNA 和一个负链 mRNA。测试断言正链 TSS 等于 start，负链 TSS 等于 end；UTR 类型、CDS phase、ID/Parent 和坐标差异分别进入正确 TSV；输入行顺序变化不影响比较结果。

Run:

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_gff3_comparison.sh
```

Expected: FAIL，因为转换和比较脚本尚不存在。

- [ ] **Step 2: 实现 longest isoform 和确定性标准化**

```bash
run_conda "${AGAT_PREFIX}" agat_sp_keep_longest_isoform.pl \
  --gff "$RUN_ROOT/pasa_update/S1.pasa.updated.gff3" \
  --output "$RUN_ROOT/agat/S1.longest_isoform.gff3"

run_conda "${AGAT_PREFIX}" agat_convert_sp_gxf2gxf.pl \
  --gff "$RUN_ROOT/agat/S1.longest_isoform.gff3" \
  --gff_version_input 3 \
  --gff_version_output 3 \
  --no_check \
  --output "$RUN_ROOT/agat/S1.normalized.gff3"
```

第一条命令允许 AGAT 按默认规则修复关系并保留最长 isoform；第二条命令只做确定性 GFF3 标准化，不再次改变生物结构。输出通过后复制到 `results/$RUN_ID/S1.genome_reproduced.gff3`，若目标已存在则阻断。

- [ ] **Step 3: 使用 AGAT 官方比较工具**

```bash
run_conda "${AGAT_PREFIX}" agat_sp_statistics.pl \
  --gff "$REPRODUCED_GFF" \
  --output "$VALIDATION_DIR/reproduced.statistics.txt"

run_conda "${AGAT_PREFIX}" agat_sp_sensitivity_specificity.pl \
  --gff1 "${COMPANY_GFF}" \
  --gff2 "$REPRODUCED_GFF" \
  --output "$VALIDATION_DIR/sensitivity_specificity.txt"

run_conda "${AGAT_PREFIX}" agat_sp_compare_two_annotations.pl \
  --gff1 "${COMPANY_GFF}" \
  --gff2 "$REPRODUCED_GFF" \
  --output "$VALIDATION_DIR/gene_overlap_events.txt"

run_conda "${AGAT_PREFIX}" agat_sp_compare_two_annotations.pl \
  --gff1 "$RUN_ROOT/reference/S1.genome.gff" \
  --gff2 "${COMPANY_GFF}" \
  --output "$VALIDATION_DIR/original_to_company_events.txt"

run_conda "${AGAT_PREFIX}" agat_sp_compare_two_annotations.pl \
  --gff1 "$RUN_ROOT/reference/S1.genome.gff" \
  --gff2 "$REPRODUCED_GFF" \
  --output "$VALIDATION_DIR/original_to_reproduced_events.txt"
```

报告必须保留 split、fusion、1:1、仅公司版、仅复现版五类事件，不能只报告 UTR 数量。解析两份 original-to-updated 报告中的 fusion ID 集合，生成 `fusion_event_match.tsv`，明确公司版 3 个两基因合并事件中有多少被复现。

- [ ] **Step 4: 生成稳定 feature 和候选 TSS 表**

`gff3_to_tables.awk` 解析分号分隔属性，不假设 `ID` 或 `Parent` 的属性顺序，输出：

```text
type	seqid	start	end	strand	phase	id	parent	tss
```

非 mRNA 的 `tss` 留空；mRNA 按链计算。`compare_annotations.sh` 对规范化后 TSV 使用 `LC_ALL=C sort`、`join`、`comm` 和 awk 生成：

- `feature_counts.tsv`
- `id_coordinate_match.tsv`
- `coordinate_set_metrics.tsv`
- `utr_metrics.tsv`
- `candidate_tss_by_shared_mrna.tsv`
- `candidate_tss_distance_histogram.tsv`
- `only_company.tsv`
- `only_reproduced.tsv`
- `cds_phase_mismatches.tsv`

- [ ] **Step 5: 写结构硬校验**

最终 GFF3 必须满足：首行 GFF3 声明；gene/mRNA ID 唯一；所有 Parent 可解析；start/end 为正整数且 start 不大于 end；seqid 存在于 FASTA；坐标不超 contig；CDS phase 为 0/1/2；gene、mRNA、exon、CDS 均大于 0。UTR 允许为 0，但必须在报告中明确标红。

- [ ] **Step 6: 运行 fixture 测试并提交**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_gff3_comparison.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_agat_finalize.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/compare_annotations.sh
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests
git commit -m "feat(tss): 增加AGAT整理与注释结构比较"
```

### Task 11: 实现总驱动器、断点续跑和 nohup 启动器

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_pipeline.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_orchestrator.sh`
- Modify: `tss/tss_utr_reproduction_20260710/README.md`

**Interfaces:**
- Consumes: 全部阶段脚本。
- Produces: 严格阶段顺序、`--stop-after`、`--resume`、PID/driver 日志、run summary。

- [ ] **Step 1: 写 mocked orchestrator 测试**

测试用 fake stage 脚本记录调用顺序，覆盖：新 run、`--stop-after fastp`、有效 resume、输出哈希改变后的拒绝 resume、前一阶段失败时下游不执行、已有结果不覆盖。

- [ ] **Step 2: 实现固定阶段图**

驱动器只允许以下顺序和阶段名：

```text
preflight -> fastp -> star -> stringtie -> pasa_align -> pasa_update -> agat -> compare -> postflight
```

CLI：

```text
run_pipeline.sh --run-id ID --mode smoke|full --threads N [--resume] [--stop-after STAGE]
```

配置文件 SHA-256、Git commit、命令参数在 preflight 时写入 `reports/$RUN_ID/run_manifest.tsv`。同一 run ID 变更配置后不得 resume，必须使用新 run ID。

- [ ] **Step 3: 实现 postflight 原始文件保护检查**

`postflight` 重新运行 `snapshot_inputs.sh --phase after` 并与 before manifest 做字节级比较；检查 `resources/` 顶层仍只有四个受控文件、原始数据目录仍只有 18 个 FASTQ 和 18 个 MD5、`S1.genome.fasta.fai` 不存在于 resources，并拒绝 reports 中任何超过 10 MiB 的文件。任何变化将 run 标为失败，不发布最终结果。

- [ ] **Step 4: 实现 nohup 启动器**

`launch_pipeline.sh` 先创建 `logs/$RUN_ID/`，拒绝已有活动 PID，然后执行：

```bash
nohup bash "$PROJECT_ROOT/scripts/run_pipeline.sh" "$@" \
  > "$PROJECT_ROOT/logs/$RUN_ID/driver.log" 2>&1 &
printf '%s\n' "$!" > "$PROJECT_ROOT/logs/$RUN_ID/driver.pid"
```

启动器打印 run ID、PID、日志路径和当前 Git commit。不得自动向后台会话注入不同的算法参数。

- [ ] **Step 5: 完成 README 运行手册**

README 写明：参数批准流程、smoke/full 命令、分阶段 `--stop-after` 命令、状态文件位置、失败产物位置、恢复规则、最终结果路径和候选 TSS 解释边界。

- [ ] **Step 6: 运行全部实现测试并提交**

```bash
for test_script in tss/tss_utr_reproduction_20260710/tests/test_*.sh; do
  bash "$test_script"
done
git diff --check
```

Expected: 全部测试打印 `[PASS]`，差异检查无输出。

Commit:

```bash
git add tss/tss_utr_reproduction_20260710/scripts/run_pipeline.sh tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh tss/tss_utr_reproduction_20260710/tests/test_orchestrator.sh tss/tss_utr_reproduction_20260710/README.md
git commit -m "feat(tss): 增加阶段驱动与断点续跑"
```

### Task 12: 执行九样本 50,000 read-pair 烟雾测试

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/smoke_summary.md`
- Modify: `tss/tss_utr_reproduction_20260710/config/pipeline.env`（仅在用户批准 fastp 参数后）

**Interfaces:**
- Consumes: 全部实现、用户批准的 fastp 策略、9 个样本各前 50,000 对 reads。
- Produces: 九样本端到端 smoke run 和不修改原始文件的证据。

- [ ] **Step 1: 执行 fastp 决策门禁**

若用户尚未明确批准，停止本任务并保留：

```text
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
```

获得明确批准后才修改为 approved/1，运行配置测试并创建独立本地提交：

```bash
git add tss/tss_utr_reproduction_20260710/config/pipeline.env tss/tss_utr_reproduction_20260710/README.md
git commit -m "config(tss): 批准fastp允许单个N碱基"
```

- [ ] **Step 2: 启动九样本 smoke run**

```bash
RUN_ID="smoke_$(date '+%Y%m%d_%H%M%S')_n1"
bash tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh \
  --run-id "$RUN_ID" \
  --mode smoke \
  --threads 32
```

smoke 模式对 S1-S9 均使用 `--reads_to_process 50000`，不是只测 S1。

- [ ] **Step 3: 验证 smoke 产物**

必须满足：9 个 fastp 样本通过 0.50 门禁；9 个 BAM quickcheck 通过；9 个 StringTie GTF 非空；mergelist 恰有 9 行；merged GTF 与 transcript FASTA 条目数一致；PASA SQLite 和 updated GFF3 非空；AGAT final GFF3 通过结构校验；before/after 输入 manifest 完全一致。

- [ ] **Step 4: 记录 smoke 结论并提交小型报告**

报告列出每个阶段命令、版本、退出码、运行时间、关键计数和失败警告。不得提交 `work/logs/results/trash` 中任何文件。

```bash
git add "tss/tss_utr_reproduction_20260710/reports/$RUN_ID/smoke_summary.md"
git commit -m "test(tss): 记录九样本端到端烟雾测试"
```

### Task 13: 分阶段执行九样本全量运行

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/fastp_review.md`
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/star_review.md`
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/stringtie_review.md`
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/pasa_review.md`

**Interfaces:**
- Consumes: 已通过 smoke 的同一 Git commit 和已批准配置。
- Produces: 九样本全量中间结果及四个阶段审核点。

- [ ] **Step 1: 创建不可变 full run ID 并只运行到 fastp**

```bash
RUN_ID="full_$(date '+%Y%m%d_%H%M%S')_n1"
bash tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh \
  --run-id "$RUN_ID" \
  --mode full \
  --threads 32 \
  --stop-after fastp
```

审核 9 个样本的 input/output pairs、pass fraction、Q20/Q30、GC、adapter、too-many-N；任一样本失败不进入 STAR。

- [ ] **Step 2: 恢复并只运行到 STAR**

```bash
bash tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh \
  --run-id "$RUN_ID" \
  --mode full \
  --threads 32 \
  --resume \
  --stop-after star
```

审核 9 个 BAM、mapping 分类、splice junction、mismatch、bedGraph 和磁盘占用；不根据公司结果改变 STAR 参数。

- [ ] **Step 3: 恢复并只运行到 StringTie merge**

```bash
bash tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh \
  --run-id "$RUN_ID" \
  --mode full \
  --threads 32 \
  --resume \
  --stop-after stringtie
```

审核每样本 transcript 数、九样本总数、merged transcript 数和去冗余比例；确认合并来自 9 个独立 GTF。

- [ ] **Step 4: 恢复并只运行到 PASA alignment assembly**

```bash
bash tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh \
  --run-id "$RUN_ID" \
  --mode full \
  --threads 32 \
  --resume \
  --stop-after pasa_align
```

审核 GMAP/BLAT alignment、有效/失败 transcript、PASA assembly 数、SQLite 完整性和 checkpoint 状态。

- [ ] **Step 5: 完成 PASA update、AGAT、比较和 postflight**

```bash
bash tss/tss_utr_reproduction_20260710/scripts/launch_pipeline.sh \
  --run-id "$RUN_ID" \
  --mode full \
  --threads 32 \
  --resume
```

只有 PASA update、AGAT、compare 和 postflight 全部完成，run 才能标记为 success。

### Task 14: 形成最终复现结论和交付报告

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/final_report.md`
- Create: `tss/tss_utr_reproduction_20260710/reports/$RUN_ID/reproduction_verdict.tsv`
- Modify: `tss/tss_utr_reproduction_20260710/README.md`

**Interfaces:**
- Consumes: `results/$RUN_ID/S1.genome_reproduced.gff3`、全部阶段报告、公司版基准。
- Produces: 可追溯的复现判定，不通过调参追求预设一致。

- [ ] **Step 1: 核对公司版已知基准**

公司版应报告 gene 10,367、mRNA 10,367、exon 15,477、CDS 15,272、five_prime_UTR 3,051、three_prime_UTR 2,922。若重新统计不一致，先阻断并调查比较脚本，不能继续解释复现差异。

- [ ] **Step 2: 生成复现判定表**

`reproduction_verdict.tsv` 至少包含：

```text
metric	company	reproduced	exact_or_rate	verdict
```

指标覆盖 feature 数、gene/mRNA ID 集、同 ID 坐标精确率、exon/CDS/UTR 坐标集合、CDS phase、split/fusion、候选 TSS 精确率和距离分布。

- [ ] **Step 3: 写最终报告**

报告按“输入与版本 → 各阶段 QC → PASA 更新事件 → AGAT 变化 → 公司版结构比较 → 候选 TSS/UTR 结论 → 未复现差异及来源”组织。逐项标注已知、推断、假设；候选 TSS 不能表述为实验验证 TSS。

- [ ] **Step 4: 应用严格结论措辞**

- 全部规范化结构一致：写“结构级精确复现”。
- 主体一致但存在差异：写匹配率并列出差异来源。
- 仅 UTR/TSS 数量接近：不得写“复现成功”。
- fastp 参数偏差必须在 Methods 和限制中单列。

- [ ] **Step 5: 最终验证和本地提交**

```bash
for test_script in tss/tss_utr_reproduction_20260710/tests/test_*.sh; do
  bash "$test_script"
done
git check-ignore -v --no-index \
  "tss/tss_utr_reproduction_20260710/work/$RUN_ID/example.bam" \
  "tss/tss_utr_reproduction_20260710/logs/$RUN_ID/driver.log" \
  "tss/tss_utr_reproduction_20260710/results/$RUN_ID/S1.genome_reproduced.gff3" \
  "tss/tss_utr_reproduction_20260710/trash/$RUN_ID/failed.out"
git diff --check
```

Expected: 全部测试 PASS，四类大文件路径均命中 `.gitignore`，差异检查无输出。

```bash
git add tss/tss_utr_reproduction_20260710/README.md "tss/tss_utr_reproduction_20260710/reports/$RUN_ID"
git commit -m "docs(tss): 记录S1注释复现与结构验证结果"
```

## 5. 阶段门禁总表

| 阶段 | 通过条件 | 失败处理 |
| --- | --- | --- |
| preflight | 版本、MD5、磁盘、策略、参考副本全部通过 | 停止；不创建下游任务 |
| fastp | 9 样本输出非空、gzip 完整、pass fraction ≥ 0.50 | 停止；样本产物移入 trash |
| STAR | 索引完整、9 BAM quickcheck、alignment > 0 | 停止；不运行 StringTie |
| StringTie | 9 GTF 非空、mergelist 九行、merged transcript > 0 | 停止；不运行 PASA |
| PASA align | DB 核心表存在、GMAP/BLAT 有效、assembly > 0 | 保留 checkpoint 后恢复 |
| PASA update | 独立 DB 副本、唯一更新 GFF3、结构合法 | attempt 移入 trash，从 alignment DB 重建 |
| AGAT | longest 和 normalized GFF3 非空、结构校验通过 | 停止；不发布 results |
| compare | 公司基准复算正确、全部比较表生成 | 停止；修复比较逻辑，不调流程参数 |
| postflight | before/after 输入 manifest 完全一致 | run 标记失败并阻止发布 |

## 6. 预期交付物

| 交付物 | Git 状态 |
| --- | --- |
| 配置、样本表、阶段脚本、测试、README | 跟踪 |
| PASA 两份模板 | 跟踪 |
| smoke/final 小型 Markdown 与 TSV 报告 | 跟踪 |
| fastp FASTQ/HTML/JSON、STAR 索引/BAM/bedGraph | 忽略 |
| StringTie GTF、PASA FASTA/SQLite/checkpoint/GFF3 | 忽略 |
| AGAT 过程 GFF3、最终生成 GFF3 | 忽略 |
| 失败 attempt 和历史 run 大文件 | `trash/` 中保存并忽略 |

## 7. 完成定义

1. 所有静态、fixture、orchestrator 测试通过。
2. 九样本 smoke run 端到端通过，且原始输入 before/after manifest 一致。
3. 九样本 full run 按四个审核点完成，无样本被静默跳过。
4. 最终 GFF3 通过语法、层级、坐标和 CDS phase 校验。
5. 复现版与公司版的 feature、ID、坐标、UTR、融合/拆分和候选 TSS 差异均可追溯。
6. 报告明确记录 fastp 参数偏差，不把候选 TSS 写成实验验证 TSS。
7. Git 仅包含代码、配置和小型报告，工作区不存在未忽略的大文件。
