# S1 TSS/UTR 注释流程复现设计（PEGS 版）

## 1. 结论与版本状态

公司于 2026-07-10 明确指定使用 [zxgsy520/pegs](https://github.com/zxgsy520/pegs) 补齐前期注释阶段生成的 PASA 比对数据库和转录本数据。因此，现行复现目标不再是仅串联流程图中的五个软件，而是复现以下两段 PEGS 数据链：

1. `pegs/rnaseq2gene.py` 中与 UTR 更新直接相关的前置链，生成去冗余、清洗后的转录本和 `pasa.sqlite`。
2. `pegs/add_utr.py` 中的注释加载、PASA annotation compare/update 和 AGAT longest-isoform 后处理。

旧版设计和实施计划已原样归档至：

- `archive/design_pre_pegs_20260710.md`
- `archive/implementation_plan_pre_pegs_20260710.md`

旧版中“只缺 PASA config”“使用 GMAP+BLAT 即可重建前置数据库”的判断已废止。输入隔离、不可变 run ID、失败产物进入 `trash/`、完成标记和结构化验证等工程约束继续有效。

## 2. 目标与边界

### 2.1 目标

从 9 份双端 RNA-seq 原始数据出发，以公司流程图为显式参数依据、以固定 PEGS 源码为缺失步骤依据，逐步生成：

1. 9 份 clean paired FASTQ。
2. 9 份 STAR 排序 BAM 和 StringTie 单样本 GTF。
3. 9 样本 StringTie 合并 GTF。
4. 去冗余并经 SeqClean 清洗的转录本 FASTA。
5. 与该转录本集合一致的 PASA alignment SQLite 数据库。
6. 基于 `S1.genome.gff` 的 PASA 更新版 GFF3。
7. AGAT longest-isoform 后的 `S1.genome_reproduced.gff3`。
8. 与公司 `S1.genome_new.gff3` 的结构化验证报告和候选 TSS/UTR 表。

### 2.2 非目标

- 不运行 PEGS 的完整真核基因预测流程。
- 不运行同源蛋白注释、EVIANN、MetaEuk、EVM、GeneMark、AUGUSTUS、DIAMOND、TransDecoder 训练、BUSCO 或 transposonPSI，除非 PASA 2.5.2 annotation update 内部按固定配置调用其自带 TransDecoder。
- 不复刻公司的专有 GFF 排序工具；公司已说明该步骤不改变生物结构。
- 不将普通 RNA-seq 推断的 transcript 5' 边界表述为实验验证 TSS。
- 不使用公司结果反向选择参数、过滤转录本或决定 PASA 更新轮次。

### 2.3 TSS 结论边界

本流程能够生成 RNA-seq 支持的候选 UTR，并可将链方向上的 mRNA 5' 端导出为候选 TSS。由于输入不是 CAGE、RAMPAGE、TSS-seq、dRNA-seq、Cappable-seq 或 5' RACE，候选 TSS 不能升级为实验验证 TSS。

## 3. 权威来源与冲突裁决

### 3.1 来源优先级

当参数或步骤冲突时，按以下顺序裁决：

1. 公司提供的 `tss/resources/tss注释流程.png` 中明确写出的命令或参数。
2. 公司随后指定的 PEGS 固定提交中，与 `rnaseq2gene.py` 和 `add_utr.py` 直接相关的步骤。
3. 对应固定软件版本的源码默认值。
4. 本项目为保证不覆盖、不删除、可恢复而增加的工程包装；不得改变生物学算法输出。

### 3.2 PEGS 源码锁

PEGS 主分支当前自称 `v1.3.0a`，但没有对应 tag；必须锁定提交而不是跟随 `main`。

| 项目 | 固定值 |
| --- | --- |
| Repository | `https://github.com/zxgsy520/pegs.git` |
| Commit | `043a69d6ad272affda6efdc40990ad3140899c63` |
| Commit date | `2026-07-08T11:34:59+08:00` |
| `pegs/rnaseq2gene.py` SHA-256 | `be7a5c745ceb2f57de28b61eb1b9990070990550f30792dfdb34091879164806` |
| `pegs/add_utr.py` SHA-256 | `a477bf8500f043b4bd26f5c9df3732835a9bfaf2db7d8f182d2c6091c5c806c3` |
| `pegs/config.py` SHA-256 | `283e92a035f062bdc886700f80dc4482b6751f5424d0638e366c3e6a14eaf8cd` |
| `scripts/rename_pasa_gtf.py` SHA-256 | `e720401f15015aa1d4dbc9fc08d7711a8ac2f357f038a382d004e0d6c38d614a` |

PEGS 源码安装到 `tss/tools/pegs/source/`，但该目录由 `tss/.gitignore` 屏蔽。仓库中跟踪 URL、commit 和上述文件哈希，不跟踪第三方源码副本。

### 3.3 已确认的冲突与裁决

| 项目 | 公司流程图 | PEGS 源码 | 现行裁决 |
| --- | --- | --- | --- |
| fastp N 阈值 | `-n 0` | `-n 0` | 精确保留；当前数据不兼容，正式运行设硬门禁 |
| fastp 质量阈值 | `-q 20` | `-q 20` | `-q 20` |
| fastp 固定裁剪 | 未写 | 默认 `trim=3`，传给 `-f/-F/-t/-T` | 双端两侧各 3 bp，记为 PEGS 补充参数 |
| STAR bedGraph | 明确要求 | 明确要求 | 保留 |
| STAR `intronMotif` | 明确要求 | 明确要求 | 保留 |
| STAR 建库前过滤 | 未写 | 去除 `<2 kb` contig | 执行等价过滤并记录；S1 的 86 条 contig 均不小于 28,453 bp，过滤前后应字节一致 |
| StringTie guide | `-G gff` | 单样本命令未加 `-G` | 公司显式参数优先，使用 run-local `S1.genome.gff` 副本 |
| StringTie 合并 | 9 样本取并集 | `stringtie --merge` | 使用 S1-S9 严格九行列表合并 |
| CD-HIT identity | 未写 | `-c 0.98b` | `0.98b` 不是合法数值，按唯一可解释意图修正为 `-c 0.98`，偏差写入报告 |
| SeqClean | 未写 | 对 UniVec 和 UniVec_Core 执行 | 保留，属于生成 PEGS 前置数据的必要步骤 |
| PASA aligner | 未写 | `minimap2` | 使用 PASA 环境中的 minimap2，不再使用旧方案的 GMAP+BLAT |
| PASA 对齐过滤 | 未写 | 75% aligned、85% identity、0 bp perfect splice、`-m 50` | 完整保留 |
| PASA admin 字段 | 未写 | 作者邮箱和 `PASA2_admin` | 属于作者服务器运维配置，不复制；SQLite 本地运行不发送邮件、不连接外部 admin DB |
| PASA annotation update | `-c annotCompare.config -A -g` | 相同，并先加载当前 GFF | 完整保留；数据库使用 alignment DB 的独立副本 |
| AGAT | keep longest isoform | keep longest isoform | 使用 AGAT 0.8.0 conda prefix，不使用 PEGS Docker 包装 |

### 3.4 不直接运行 PEGS 原脚本的原因

PEGS 是算法和参数来源，不作为未经修改的调度器直接执行，原因均可由固定提交复核：

1. 软件和数据库路径硬编码为作者服务器的 `/Work/...`。
2. `rnaseq2gene.py`、`add_utr.py` 和 PEGS 调用的 SeqClean 含删除旧产物的命令，不符合本项目不可删除约束。
3. `cd-hit-est -c 0.98b` 为语法错误。
4. `add_utr.py` 默认 BUSCO 分支引用未定义变量 `kingdom`。
5. 直接运行会引入本次生成 UTR GFF 不需要的全基因组预测、蛋白数据库和 BUSCO 环节。
6. 原脚本没有原始输入只读审计、完成标记原子发布、输出哈希和不可变 run ID。

因此实现为“PEGS-compatible runner”：命令参数和数据变换与上述裁决一致，执行、隔离、审计和恢复由仓库自己的 Bash/Perl 包装负责。

### 3.5 可复现性不确定项

| 层级 | 事项 | 处理 |
| --- | --- | --- |
| 已知 | 公司当前明确要求使用 PEGS | 以当前指定仓库为方案依据 |
| 待验证 | 公司生成 `S1.genome_new.gff3` 时使用的历史 PEGS commit 未提供；现行 add-UTR 源码提交日期为 2026-07-08 | 锁定当前指定 commit，最终报告不得声称已证明历史代码完全相同 |
| 已知 | 公司流程图要求 StringTie `-G`，当前 PEGS 源码未写 `-G` | 公司显式参数优先，并把冲突写入 provenance |
| 推断 | `cd-hit-est -c 0.98b` 只能解释为 `0.98` 后的录入字符错误 | 修正为 `0.98`，单列为源码语法修正 |
| 待验证 | 公司历史 UniVec/UniVec_Core 快照未提供 | 固定本次 NCBI 下载文件及 index 哈希，差异分析中列为潜在来源 |
| 已知 | 当前 FASTQ 与 `-n 0` 不兼容 | 保留 company-exact 失败证据，正式兼容参数需用户另行批准 |

## 4. 已知输入与基准

| 类型 | 路径或规模 | 固定约束 |
| --- | --- | --- |
| 参考基因组 | `tss/resources/S1.genome.fasta`，约 40.3 MB | 只读；86 条 contig；最短 28,453 bp |
| 原始注释 | `tss/resources/S1.genome.gff` | 只读；10,370 个 gene |
| RNA-seq | `tss/resources/裂殖壶菌原始数据-BYT2025041001/` | 9 样本、18 个 BGZF FASTQ、约 53 GB |
| FASTQ 校验 | 每个 FASTQ 的同目录 `.md5` | 运行前后均对实际样本路径计算并验证 MD5 |
| 公司结果 | `tss/resources/S1.genome_new.gff3` | 只读；只用于最终比较 |
| 公司流程图 | `tss/resources/tss注释流程.png` | 显式参数最高优先级 |

公司结果的结构基准：

| feature | 数量 |
| --- | ---: |
| gene | 10,367 |
| mRNA | 10,367 |
| exon | 15,477 |
| CDS | 15,272 |
| five_prime_UTR | 3,051 |
| three_prime_UTR | 2,922 |

已确认公司结果中有 2,972 个可直接按 ID 对应的 mRNA 改变边界，1,957 个可直接对应的 CDS 模型发生变化，并有 3 个两基因合并事件。因此不能只比较 UTR 总数，也不能把 gene 数接近视为复现成功。

## 5. 工具链

### 5.1 五个公司主工具

| 工具 | 固定版本 | 安装 prefix |
| --- | --- | --- |
| fastp | 0.23.1 | `tss/tools/fastp/env` |
| STAR | 2.7.9a | `tss/tools/STAR/env` |
| StringTie | 2.2.0 | `tss/tools/stringtie/env` |
| PASA | 2.5.2 | `tss/tools/pasa/env` |
| AGAT | 0.8.0 | `tss/tools/agat/env` |

### 5.2 PEGS 前置链新增依赖

| 依赖 | 固定版本或来源 | 用途 |
| --- | --- | --- |
| PEGS | commit `043a69d...` | 权威脚本、参数与 ID 重命名逻辑 |
| Python | 3.11 | 通过独立 `tss/tools/pegs/env` 调用 PEGS 的 stdlib 脚本 |
| gffread | 0.12.7 | 从 merged GTF 提取 transcript FASTA |
| CD-HIT | 4.8.1 | `cd-hit-est -c 0.98 -d 0 -M 64000` 去冗余 |
| SeqClean | PASA 2.5.2 内置副本 | transcript polyA/low-complexity/UniVec 清洗 |
| blast-legacy | 2.2.26 | 为 SeqClean 提供 `blastall`、`megablast` 和 `formatdb` |
| UniVec | NCBI 运行时固定快照 | SeqClean vector database |
| UniVec_Core | NCBI 运行时固定快照 | SeqClean core vector database |
| minimap2 | 2.31，已在 PASA prefix | PASA transcript-to-genome alignment |
| samtools | 1.23.1，已在 PASA prefix | BAM 完整性和统计 |
| SQLite | 3.53.3，已在 PASA prefix | PASA 数据库审计 |
| TransDecoder | 6.0.0，已在 PASA prefix | PEGS `RUN_TRANS_DECODER=1` 的 PASA update 内部依赖 |

新增依赖各自放入 `tss/tools/` 下的独立目录。UniVec 和 UniVec_Core 下载后必须分别用固定 blast-legacy `formatdb -p F` 建立 nucleotide index；FASTA 与全部 index sidecar 的 SHA-256 均写入跟踪的 `config/toolchain.lock.tsv`。

### 5.3 调用规则

- 所有 conda prefix 必须是绝对路径。
- 不依赖 base 环境、交互式 `PATH` 或当前 `PASAHOME`。
- PASA 启动器固定使用 `$PASA_HOME/Launch_PASA_pipeline.pl` 的绝对路径。
- PEGS Python 脚本通过 `conda run --no-capture-output -p "$PEGS_PREFIX" python ...` 调用。
- SeqClean 使用 `build_safe_seqclean.sh` 从 PASA 2.5.2 固定副本生成无删除版；构建只跳过固定源码中 5 行文件清理逻辑，不改序列过滤算法。
- 每个工具先通过真实功能测试，再允许进入正式运行。

## 6. 文件与运行隔离

```text
tss/tss_utr_reproduction_20260710/
├── README.md
├── design.md
├── implementation_plan.md
├── archive/
│   ├── design_pre_pegs_20260710.md
│   └── implementation_plan_pre_pegs_20260710.md
├── config/
│   ├── pipeline.env
│   ├── samples.tsv
│   ├── toolchain.lock.tsv
│   ├── pegs_alignAssembly.config.in
│   └── pegs_annotCompare.config.in
├── scripts/
│   ├── build_safe_seqclean.sh
├── tests/
├── work/<RUN_ID>/
├── logs/<RUN_ID>/
├── reports/<RUN_ID>/
├── results/<RUN_ID>/
└── trash/<RUN_ID>/
```

跟踪：文档、配置模板、工具锁、safe SeqClean 构建脚本、小型测试 fixture 和汇总报告。

忽略：第三方工具、UniVec 快照、FASTQ、clean FASTQ、STAR 索引、BAM、bedGraph、GTF、transcript FASTA、CD-HIT cluster、SeqClean 临时文件、PASA SQLite/checkpoint/GFF3、AGAT 过程文件和生成版 GFF3。

原始 `resources/` 只读。所有可能产生旁文件的工具只接收 `work/<RUN_ID>/reference/` 下的副本。任何失败重试使用新的 `attempt-XXXX/`，旧 attempt 原样保留或移动到 run-local `trash/`，不原位清空。

## 7. 现行数据流

```text
9 paired FASTQ
  -> fastp per sample
       company exact: -n 0 -q 20
       PEGS supplement: -f 3 -F 3 -t 3 -T 3
  -> STAR index on >=2 kb reference copy
  -> STAR per sample (SortedByCoordinate + bedGraph + intronMotif)
  -> samtools validation
  -> StringTie per sample with -G run-local S1.genome.gff
  -> stringtie --merge on strict S1..S9 list
  -> gffread merged transcript FASTA
  -> cd-hit-est 0.98 identity
  -> PEGS rename_id.py, IDs transngs1..N
  -> safe SeqClean with formatted UniVec,UniVec_Core
  -> PASA alignment assembly with minimap2
       MIN_PERCENT_ALIGNED=75
       MIN_AVG_PER_ID=85
       NUM_BP_PERFECT_SPLICE_BOUNDARY=0
       subcluster -m=50
  -> copy alignment SQLite to independent update attempt
  -> Load_Current_Gene_Annotations.dbi with S1.genome.gff copy
  -> PASA annotation compare/update (-A, RUN_TRANS_DECODER=1)
  -> AGAT keep longest isoform
  -> deterministic GFF3 normalization
  -> structural comparison with S1.genome_new.gff3
  -> candidate UTR/TSS report
```

## 8. 阶段设计

### 8.1 Preflight

Preflight 在读取 53 GB FASTQ 前先检查策略门禁。允许执行的 `audit` 模式只做工具、配置和小型 fixture 审核；`smoke/full` 在 fastp policy 未批准时以退出码 42 立即停止，并且不创建 run 目录。

通过策略门禁后依次执行：

1. 精确工具版本和二进制哈希。
2. 至少 300 GB 可用磁盘；该下限不能被配置降级。
3. 18 个 FASTQ 官方 MD5 对实际样本绝对路径的直接验证。
4. R1/R2 全文件流式四行结构、read name、长度和 pair 数验证。
5. 参考 FASTA/GFF 复制、字节比较和 SHA-256。
6. GFF seqid、坐标、ID/Parent 和 10,370 gene 结构门禁。
7. PEGS commit/hash、UniVec FASTA/index hash 和 safe SeqClean hash。
8. 输入清单在复制前后字节一致。

任何失败均不得发布 `preflight.done`。

### 8.2 fastp 精确模式与兼容门禁

PEGS 和公司流程均固定 `-n 0 -q 20`，PEGS 另固定双端首尾各裁 3 bp：

```bash
fastp \
  --in1 R1.fastq.gz --in2 R2.fastq.gz \
  --out1 clean_R1.fastq.gz --out2 clean_R2.fastq.gz \
  --thread THREADS -n 0 -q 20 \
  -f 3 -F 3 -t 3 -T 3 \
  --json sample.fastp.json --html sample.fastp.html
```

已知事实：9 个样本的 R1 第 9 位均为 100% `N` 且质量字符为 `!`；S1 前 50,000 对 reads 在 `-n 0` 下输出 0 对。`-n 1` 在同一子集中保留 49,937 对，是最小单参数兼容候选，但尚未获用户批准。

正式流程必须：

1. 先保存 `company_exact` smoke 证据。
2. 在 `FASTP_POLICY_STATUS=blocked` 时停止。
3. 仅在用户明确批准后，将 `FASTP_MAX_N` 改为批准值并记录审批时间、理由和前后统计。
4. 任何样本输出为 0、pair 数为奇数、gzip 失败或 pass fraction 小于 0.50 时停止。

### 8.3 STAR

先在 run-local reference 中执行 PEGS 的 `<2 kb` contig 过滤语义。当前参考应保持 86 条 contig 且过滤前后 SHA-256 相同；若未来输入不满足，不允许把过滤后参考与原始 GFF 混用。

每个样本独立运行 STAR，保留：

- `--readFilesCommand zcat`
- `--outWigType bedGraph`
- `--outSAMtype BAM SortedByCoordinate`
- `--outSAMstrandField intronMotif`

不额外添加公司和 PEGS 均未指定的 two-pass、注释 SJDB 或链特异参数。BAM 必须通过 `samtools quickcheck`，mapped read 数大于 0，并解析 STAR final log。

### 8.4 StringTie 与九样本并集

9 个样本各自运行：

```bash
stringtie sample.sorted.bam \
  -G work/RUN_ID/reference/S1.genome.gff \
  -o sample.stringtie.gtf \
  -p THREADS
```

不添加 `-e`、`-t`、`--rf` 或 `--fr`。`merge.list` 必须按 S1-S9 固定顺序恰有九行，之后执行：

```bash
stringtie --merge -p THREADS -o S1.merged.gtf merge.list
```

单样本 GTF 和 merged GTF 均需验证 transcript/exon 数、Parent 关系和参考坐标。

### 8.5 PEGS transcript preparation

按 PEGS 顺序执行：

1. `gffread -w S1.transcript.fasta -g S1.genome.fasta S1.merged.gtf`。
2. `cd-hit-est -c 0.98 -d 0 -T THREADS -M 64000` 生成 `S1.unitranscript.fasta`。
3. 固定 PEGS `rename_id.py -p transngs` 生成 `trans.rename.fasta` 和旧 ID 到新 ID 日志。
4. safe SeqClean 使用已建立 legacy BLAST index 的 `UniVec_Core,UniVec` 和 `-c THREADS` 生成 `trans.rename.fasta.clean` 与 `.cln` 报告。

PASA alignment 的 `-u` 输入为 `trans.rename.fasta`，`-t` 输入为 `trans.rename.fasta.clean`；PASA update 的 `-t` 也必须使用同一份 clean FASTA，确保 transcript ID 与 SQLite 一致。

每一步报告输入条目数、输出条目数、移除数、长度分布、重复 ID 和 SHA-256。SeqClean 所有临时文件保留在被忽略的 run-local attempt 中。

### 8.6 PASA alignment assembly

alignment config 固定为：

```text
DATABASE=@DATABASE@
validate_alignments_in_db.dbi:--MIN_PERCENT_ALIGNED=75
validate_alignments_in_db.dbi:--MIN_AVG_PER_ID=85
validate_alignments_in_db.dbi:--NUM_BP_PERFECT_SPLICE_BOUNDARY=0
subcluster_builder.dbi:-m=50
```

首次运行命令语义与 PEGS 一致：

```bash
Launch_PASA_pipeline.pl \
  -c pegs_alignAssembly.config \
  -C -R -g S1.genome.fasta -T \
  -u trans.rename.fasta \
  -t trans.rename.fasta.clean \
  --CPU THREADS --ALIGNERS minimap2
```

数据库、参考副本、日志和 checkpoint 全部位于 `work/<RUN_ID>/pasa_align/attempt-XXXX/`。恢复只允许使用同一 config/input hash 的 attempt；不能重建或覆盖已有 SQLite。

通过门禁至少要求：SQLite `quick_check=ok`、核心表存在、clean transcript 可在数据库中追溯、有效 alignment 大于 0、assembly GFF3/GTF 非空、失败原因统计完整。

### 8.7 PASA annotation compare/update

alignment SQLite 先复制或 reflink 到独立 update attempt，原 alignment DB 前后 SHA-256 必须一致。加载 run-local `S1.genome.gff` 副本后执行一次 update。

annotation config 固定包含：

```text
DATABASE=@DATABASE@
RUN_TRANS_DECODER=1
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

PEGS 中未替换的 `MIN_FL_ORF_SIZE`、`STOMP_HIGH_PERCENTAGE_OVERLAPPING_GENE` 和 `TRUST_FL_STATUS` 会被 PASA launcher 跳过，因此本配置也不写这些项，保留 PASA 2.5.2 默认行为。

命令为：

```bash
Load_Current_Gene_Annotations.dbi \
  -c pegs_alignAssembly.config \
  -g S1.genome.fasta \
  -P S1.genome.gff

Launch_PASA_pipeline.pl \
  --CPU THREADS \
  -c pegs_annotCompare.config \
  -A -g S1.genome.fasta \
  -t trans.rename.fasta.clean
```

只执行一轮 annotation update。要求唯一、非空的 `gene_structures_post_PASA_updates.*.gff3`，并报告 update、merge、split、rejected 和 unchanged 事件。

### 8.8 AGAT 与最终发布

对 PASA 更新 GFF3 运行 AGAT 0.8.0：

```bash
agat_sp_keep_longest_isoform.pl \
  --gff S1.pasa.updated.gff3 \
  --output S1.longest.gff3
```

之后使用 AGAT GFF3 转换或仓库的结构化排序器做确定性规范化。只有 gene/mRNA/exon/CDS/UTR 关系、坐标和 ID 检查全部通过，才以无覆盖方式发布：

```text
results/<RUN_ID>/S1.genome_reproduced.gff3
```

AGAT 前后分别统计结构变化，避免把 AGAT 修复误记为 PASA 更新。

### 8.9 结构化比较与候选 TSS

比较维度包括：

1. feature 总数和每 contig 数量。
2. gene/mRNA ID 集合。
3. gene/mRNA/exon/CDS/UTR 坐标集合。
4. mRNA 边界完全匹配率。
5. CDS 模型完全匹配率。
6. merge/split 事件和对应原始 gene。
7. five_prime_UTR、three_prime_UTR 覆盖 transcript 数和长度分布。
8. 1-3 bp 极短 UTR。
9. 候选 TSS 精确匹配、链一致性和距离分布。
10. source、属性顺序和 feature 行顺序差异；这些格式差异与结构差异分开报告。

候选 TSS 定义：正链取 mRNA 最小坐标，负链取 mRNA 最大坐标。输出必须标记 `candidate_tss`，不能使用 `validated_tss`。

## 9. 状态、恢复与失败隔离

阶段顺序固定为：

```text
preflight
-> fastp
-> star
-> stringtie
-> transcript_prepare
-> pasa_align
-> pasa_update
-> agat
-> compare
-> postflight
```

每个完成标记包含：run ID、stage、mode、开始/结束时间、配置哈希、输入哈希、输出哈希、工具锁哈希和命令日志路径。标记先写临时文件并完成全部哈希，再用无覆盖原子发布；任何失败不得留下部分 `.done`。

恢复条件：

- run ID 相同。
- config hash、toolchain lock hash 和输入 hash 相同。
- 前一阶段输出 hash 与 marker 一致。
- 失败 attempt 未被当成完成产物。

不满足任一条件即拒绝 resume。PASA 重试新建 attempt，不原位替换数据库。

## 10. 已实现基础与待修复项

### 10.1 已实现并保留

- 配置和九样本清单。
- `tss/.gitignore` 对 tools、work、logs、results、trash 和大过程文件的屏蔽。
- run-local 路径守卫、不可变 run ID、输出哈希和失败产物隔离。
- blocked fastp policy 在大文件扫描前快速退出。
- FASTQ/参考输入快照和初版 preflight。

### 10.2 Task 3 独立审查必须先修复

1. 300 GB 磁盘门禁不能被配置降至更低。
2. PEGS/PASA 新增依赖必须精确版本和哈希门禁。
3. `.done` marker 必须失败原子。
4. MD5 必须直接验证样本表指定的 FASTQ 绝对路径。
5. gzip checker 必须启用严格 gzip/CRC 校验并检查 close 错误。

旧 Task 4-14 全部由新版 `implementation_plan.md` 取代，不再按旧 GMAP+BLAT 路线继续。

## 11. 正式运行停止边界

当前保持：

```text
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
```

在用户明确批准数据兼容参数前，只允许完成：

- 文档和配置更新。
- 工具安装与调用验证。
- 单元/契约测试。
- 不读取全量 FASTQ 的 audit preflight。
- S1 前 50,000 对 reads 的 `company_exact` fastp 失败复核。

不允许开始九样本 STAR、StringTie、PASA 或正式 full run。若用户批准 `-n 1`，必须单独提交配置变更，随后依次执行九样本 fastp review、STAR review、StringTie review、PASA alignment review 和最终 update/compare；不得一条后台命令无检查地跑到底。

## 12. 验收标准

### 12.1 工程验收

- PEGS commit 和关键文件 SHA-256 精确匹配。
- 所有工具和依赖入口通过真实调用。
- 原始 FASTQ/FASTA/GFF/公司 GFF3 前后清单完全一致。
- 所有大文件和过程文件被 `tss/.gitignore` 命中。
- 阶段失败不发布 marker，不覆盖已有结果，不删除旧 attempt。
- full run 可从任一已验证阶段恢复。

### 12.2 生物信息验收

- 9 个样本分别完成 fastp、STAR 和 StringTie。
- merge list 恰有 S1-S9 九行。
- CD-HIT、SeqClean 前后 transcript 数和映射可审计。
- PASA SQLite 与 clean transcript ID 一致且 `quick_check=ok`。
- PASA update 仅使用 `S1.genome.gff` 副本，不读取公司结果。
- 最终 GFF3 结构合法并包含可追溯的 UTR。
- 与公司结果的差异可定位到 StringTie、transcript preparation、PASA 或 AGAT 阶段。
- 报告明确区分候选 UTR/TSS 与实验验证 TSS。

## 13. 来源

- [PEGS repository](https://github.com/zxgsy520/pegs)
- [PEGS `rnaseq2gene.py`](https://github.com/zxgsy520/pegs/blob/043a69d6ad272affda6efdc40990ad3140899c63/pegs/rnaseq2gene.py)
- [PEGS `add_utr.py`](https://github.com/zxgsy520/pegs/blob/043a69d6ad272affda6efdc40990ad3140899c63/pegs/add_utr.py)
- [PEGS usage](https://github.com/zxgsy520/pegs/blob/043a69d6ad272affda6efdc40990ad3140899c63/docs/USAGE.md)
- [gffread](https://github.com/gpertea/gffread)
- [CD-HIT](https://github.com/weizhongli/cdhit)
- [PASA](https://github.com/PASApipeline/PASApipeline)
- [minimap2](https://github.com/lh3/minimap2)
- [SeqClean downloads](https://sourceforge.net/projects/seqclean/files/)
- [Bioconda blast-legacy](https://bioconda.github.io/recipes/blast-legacy/README.html)
- [NCBI UniVec](https://ftp.ncbi.nlm.nih.gov/pub/UniVec/)
