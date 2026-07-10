# S1 TSS/UTR 注释流程复现设计

## 1. 目标与边界

本项目从 9 份双端 RNA-seq 原始数据出发，按流程图给出的软件版本和参数完成独立质控、比对、单样本转录本组装、九样本非冗余合并、PASA 注释更新和 AGAT 后处理，得到复现版 GFF3，并与公司交付的 `S1.genome_new.gff3` 做结构化比较。

本项目的目标包括：

1. 建立可重复运行、可审计、可断点续跑的完整流程。
2. 使用流程图中明确给出的参数，其余参数采用对应软件版本的官方默认值。
3. 在运行前固定全部配置，不使用公司版 GFF3 反向调参。
4. 量化复现结果与公司版 GFF3 在 gene、mRNA、exon、CDS 和 UTR 层面的差异。

本项目不把普通 RNA-seq 推断的 mRNA 5' 端表述为实验验证的 TSS。最终只能输出候选 TSS，即链方向上的转录本 5' 端坐标。

## 2. 已知输入与基准

| 类型 | 路径或规模 | 状态 |
| --- | --- | --- |
| 参考基因组 | `tss/resources/S1.genome.fasta`，约 40.3 MB | 已纳入版本控制 |
| 原始注释 | `tss/resources/S1.genome.gff`，10,370 个 gene | 已纳入版本控制 |
| 原始 RNA-seq | `tss/resources/裂殖壶菌原始数据-BYT2025041001/` | 9 个样本、18 个 BGZF FASTQ、约 53 GB |
| 原始数据校验 | 每个 FASTQ 均有同名 `.md5` 文件 | 运行前逐一校验 |
| 公司结果 | `tss/resources/S1.genome_new.gff3` | 只用于最终验证 |
| 流程图 | `tss/resources/tss注释流程.png` | 唯一公司流程说明 |

公司结果的已知结构基准如下：

| feature | 数量 |
| --- | ---: |
| gene | 10,367 |
| mRNA | 10,367 |
| exon | 15,477 |
| CDS | 15,272 |
| five_prime_UTR | 3,051 |
| three_prime_UTR | 2,922 |

初步反向检查还确认：公司结果中有 2,972 个可直接按 ID 对应的 mRNA 改变了边界，1,957 个可直接对应的 CDS 模型发生变化，并出现 3 个两基因合并事件。最终验证不能只比较 UTR 数量。

## 3. 固定决策

| 项目 | 固定决策 |
| --- | --- |
| 参数策略 | 流程图参数优先；未展示参数采用固定版本的实际代码默认值 |
| 样本处理 | 9 个样本分别完成 fastp、STAR 和 StringTie |
| 九样本合并 | 使用 `stringtie --merge` 合并 9 个单样本 GTF |
| 链特异性 | 公司复现主线按 StringTie 默认的非链特异模式运行；另做 BAM 链特异性统计，不据此修改主线参数 |
| STAR 索引 | 使用参考 FASTA；不额外加入流程图未说明的注释剪接位点 |
| PASA 数据库 | 使用运行目录内的 SQLite 数据库 |
| PASA 比对器 | 同时使用已随 PASA 环境安装的 GMAP 和 BLAT |
| PASA 更新 | 执行一次 annotation compare/update，不依据公司结果追加轮次 |
| AGAT | 使用 `agat_sp_keep_longest_isoform.pl` 默认规则，每个基因保留最长 CDS 或最长拼接 exon 的 isoform |
| 公司排序脚本 | 不复刻；使用确定性 GFF3 排序，比较时忽略行顺序和属性顺序 |

## 4. 项目目录

```text
tss/tss_utr_reproduction_20260710/
├── design.md
├── README.md
├── config/
│   ├── samples.tsv
│   ├── alignAssembly.config
│   └── annotCompare.config
├── scripts/
├── reports/
├── work/
├── logs/
└── results/
```

版本控制范围：

- 跟踪 `design.md`、`README.md`、`config/`、`scripts/` 和最终汇总报告。
- 忽略 `work/`、`logs/` 和 `results/`，其中包含 FASTQ、STAR 索引、BAM、bedGraph、GTF、PASA SQLite 数据库、检查点和生成版 GFF3。
- `tss/tools/` 和原始测序数据目录继续由 `tss/.gitignore` 屏蔽。

实施阶段将在 `tss/.gitignore` 增加：

```gitignore
/tss_utr_reproduction_20260710/work/
/tss_utr_reproduction_20260710/logs/
/tss_utr_reproduction_20260710/results/
```

## 5. 数据流

```text
9 对原始 FASTQ
  -> 每样本 fastp
  -> 每样本 STAR SortedByCoordinate BAM + bedGraph
  -> 每样本 StringTie guided assembly
  -> stringtie --merge
  -> merged.gtf
  -> PASA 自带 StringTie/Cufflinks GTF 转录本提取工具
  -> merged_transcripts.fasta
  -> PASA SQLite alignment assembly（GMAP + BLAT）
  -> PASA annotation compare/update
  -> PASA 更新版 GFF3
  -> AGAT longest isoform
  -> 确定性排序与结构校验
  -> S1.genome_reproduced.gff3
  -> 与公司版 S1.genome_new.gff3 结构化比较
```

## 6. 分阶段设计

### 6.1 输入预检

1. 校验 18 个 FASTQ 与对应 `.md5`。
2. 检查 R1/R2 read 名称配对、read 数量一致性和 read 长度。
3. 检查 FASTA 序列 ID 与 GFF 第 1 列的一致性。
4. 对原始 GFF3 检查 feature 数量、ID 唯一性、Parent 关系、坐标范围和 CDS phase。
5. 记录输入文件大小、mtime、MD5/SHA-256 和工具版本。

任何 FASTQ 校验失败都会阻断后续运行，不通过跳过样本的方式继续。

### 6.2 fastp

每个样本独立运行 fastp v0.23.1：

```text
-n 0 -q 20
```

其余过滤、接头处理、长度阈值和 polyG/polyX 行为使用 v0.23.1 默认值。每个样本保留 JSON 和 HTML 报告，汇总过滤前后 reads、bases、Q20、Q30、GC 和失败原因。

### 6.3 STAR

使用 STAR v2.7.9a 构建一次共享索引。参考基因组约 40 Mb，`genomeSAindexNbases` 按 STAR 小基因组公式设置为 11；该值属于基因组规模适配，不属于经验调参。

每个样本独立比对，保留流程图明确参数：

```text
--outWigType bedGraph
--outSAMstrandField intronMotif
```

同时输出 StringTie 所需的坐标排序 BAM。其他比对过滤、多重比对、错配、两遍比对和剪接相关参数使用 STAR v2.7.9a 默认值。

### 6.4 单样本 StringTie

每个样本使用 StringTie v2.2.0 对自己的 STAR BAM 进行有参组装：

```text
-G tss/resources/S1.genome.gff
```

不添加 `--rf`、`--fr`、`-e` 或 `-t`。覆盖度、junction、isoform fraction、最小长度和端部 trimming 使用 v2.2.0 默认值。每个样本生成独立 GTF 和基础统计。

### 6.5 九样本合并

将 9 个单样本 GTF 写入固定顺序的 `mergelist.txt`，按 S1 到 S9 顺序执行 `stringtie --merge`。合并阶段继续使用原始 GFF 作为 guide，其余 merge 阈值使用 v2.2.0 默认值。

该结果定义为九样本非冗余转录本并集，不等同于简单文本拼接，也不通过合并 BAM 后重新组装替代。

### 6.6 转录本 FASTA

使用 PASA 2.5.2 自带的 `cufflinks_gtf_genome_to_cdna_fasta.pl` 从 `merged.gtf` 和 `S1.genome.fasta` 提取转录本 FASTA。该工具明确支持 Cufflinks/StringTie GTF，不增加新的外部软件。

提取后检查：

1. FASTA ID 唯一。
2. FASTA 条目数与 merged GTF transcript 数一致。
3. 所有序列非空且只包含允许的核苷酸字符。
4. 负链转录本方向正确。

### 6.7 PASA alignment assembly

PASA v2.5.2 使用 SQLite 数据库：

```text
/data/p252701008/projects/multi-omics-data-pipelines/tss/tss_utr_reproduction_20260710/work/pasa/S1_pasa.sqlite
```

alignment assembly 阶段使用 GMAP 和 BLAT。两者均随当前 PASA conda prefix 安装。PASA 要求显式指定至少一个 aligner，因此选择官方帮助示例中的 `gmap,blat` 组合。

实际 `Launch_PASA_pipeline.pl` v2.5.2 源码中的启动器默认值为：

| 参数 | 值 |
| --- | ---: |
| 最大 intron 长度 | 500,000 bp |
| top alignment 数量 | 1 |
| CPU | 由运行环境指定，不属于算法复现参数 |

源码帮助文本仍写 100,000 bp，但实际变量初始化为 500,000 bp。本项目以运行代码为准，并在报告中记录该差异。

alignment 配置采用：

| 配置项 | 值 |
| --- | ---: |
| `MIN_PERCENT_ALIGNED` | 90 |
| `MIN_AVG_PER_ID` | 95 |
| `subcluster_builder.dbi:-m` | 50 |

### 6.8 PASA annotation compare/update

首次更新时加载 `S1.genome.gff`，执行一次 annotation compare/update。`annotCompare.config` 显式写入 PASA 2.5.2 源码默认值：

| 参数 | 值 |
| --- | ---: |
| `MIN_PERCENT_OVERLAP` | 50 |
| `MIN_PERCENT_PROT_CODING` | 40 |
| `MIN_PERID_PROT_COMPARE` | 70 |
| `MIN_PERCENT_LENGTH_FL_COMPARE` | 70 |
| `MIN_PERCENT_LENGTH_NONFL_COMPARE` | 70 |
| `MIN_PERCENT_ALIGN_LENGTH` | 70 |
| `MIN_PERCENT_OVERLAP_GENE_REPLACE` | 80 |
| `MAX_UTR_EXONS` | 2 |
| `GENETIC_CODE` | `universal` |

`MIN_FL_ORF_SIZE` 在源码中没有固定数值默认值，因此从配置中省略。`TRUST_FL_STATUS` 和 `STOMP_HIGH_PERCENTAGE_OVERLAPPING_GENE` 默认关闭，也通过省略对应 flag 保持关闭。

### 6.9 AGAT 与最终整理

对 PASA 输出运行 AGAT v0.8.0：

```text
agat_sp_keep_longest_isoform.pl
```

随后执行结构校验和确定性排序。AGAT 可以修正部分 gene/mRNA 包含关系，因此验证报告同时保留 PASA 原始输出与 AGAT 后输出的统计。

公司版 GFF3 经 AGAT v0.8.0 再处理时会修正 5 个 gene 边界，并调整一个局部 feature 顺序。因此不会使用文件 MD5 或逐行 diff 作为生物结构一致性的唯一标准。

## 7. 验证设计

### 7.1 过程验证

| 阶段 | 必须记录的指标 |
| --- | --- |
| 输入 | MD5、文件大小、read 配对和 read 长度 |
| fastp | 输入/输出 reads、过滤率、Q20、Q30、GC、adapter 和 N 过滤 |
| STAR | uniquely mapped、multi-mapped、unmapped、splice junction、mismatch、chimeric |
| StringTie | 每样本 transcript 数、参考匹配数、新转录本数、长度分布 |
| merge | 九样本各自贡献、合并前后 transcript 数、去冗余比例 |
| PASA | 有效 alignment、更新/合并/拆分/拒绝事件及其原因 |
| AGAT | 删除的 isoform 数、坐标修复、重复和 orphan 记录 |

### 7.2 最终结构验证

最终比较前，将复现版和公司版 GFF3 规范化为与行顺序、属性顺序无关的 feature 表。比较内容包括：

1. 各 feature 类型总数。
2. gene 和 mRNA ID 集合。
3. 同 ID gene/mRNA 的染色体、链、起止坐标完全匹配率。
4. exon、CDS、five_prime_UTR、three_prime_UTR 的坐标集合精确匹配率。
5. CDS phase 一致率。
6. 3 个已知基因合并事件是否复现。
7. UTR 覆盖 transcript 数和长度分布。
8. 候选 TSS 坐标的精确匹配、距离分布和链一致性。
9. 仅存在于复现版或公司版的结构差异清单。

### 7.3 成功判据

技术复现成功要求：

1. 所有 9 个样本通过输入校验并完成全部阶段。
2. 最终 GFF3 通过语法、ID、Parent、坐标和 CDS phase 校验。
3. 每一步具有命令、版本、配置、日志和统计证据。
4. 最终差异可逐 gene 追溯到 StringTie、PASA 或 AGAT 阶段。

与公司结果是否相同属于验证结果，而不是预设条件。只有规范化后的全部结构完全一致时，才表述为结构级精确复现；否则报告匹配率和差异原因，不通过调整官方默认参数追求目标文件。

## 8. 运行、恢复与文件保护

1. 每次完整运行使用不可变 run ID，已有结果不覆盖。
2. 长任务使用后台运行和独立日志，保存 PID、开始时间、结束时间和退出码。
3. 各阶段成功后写入完成标记，下游只读取通过校验的上游产物。
4. 失败重跑从最近有效检查点继续。
5. 不删除任何文件；需要隔离的失败产物移动到项目 `trash/` 下按 run ID 分类保存。
6. 运行前检查可用磁盘，运行过程中记录 FASTQ、BAM、索引和 PASA 数据库占用。

## 9. 交付物

| 交付物 | 是否纳入 Git |
| --- | --- |
| 设计文档 | 是 |
| 样本清单 | 是 |
| 两份 PASA 配置 | 是 |
| 可重复运行脚本 | 是 |
| 版本与命令清单 | 是 |
| 过程统计汇总 | 是 |
| 最终结构比较报告 | 是 |
| STAR 索引、FASTQ、BAM、bedGraph、GTF、SQLite、生成 GFF3 | 否，由 `.gitignore` 屏蔽 |
