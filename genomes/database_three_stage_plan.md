# Genomes 数据库三阶段规划

> 状态快照：2026-07-14 13:36 CST
> 适用目录：`genomes/` 及已经下载、但脚本位于目录外的 RefSeq 数据
> 计量约定：GB/TB 使用十进制；“下载量”指压缩或原始远端文件，“工作空间”指解压、索引和表格转换后的估算，不包含模型 checkpoint 与训练缓存。

## 1. 结论

当前 `genomes/` 下有 15 个数据库目录，`common/` 和 `tests/` 不属于数据库。按统一建模中的主要作用划分为：

| 阶段 | 目标 | 当前目录内数据库 | 核心判断 |
|---|---|---|---|
| 第一阶段：通用序列预训练 | 学习 DNA、RNA、蛋白质的跨物种序列规律 | RNAcentral、UniProt | RefSeq 虽不在 `genomes/` 中，但属于本阶段且已下载 |
| 第二阶段：注释与知识对齐 | 将序列表征对齐到基因结构、分类、功能和通路标签 | GTDB、GENCODE、Ensembl、GenBank、BV-BRC、MycoCosm、IMG/M、Phytozome、VEuPathDB | 当前脚本默认以 metadata、GTF/GFF 和功能表为主，不重复下载已有序列 |
| 第三阶段：下游训练与评测 | 为 TSS、调控元件、染色质状态和细胞类型任务提供监督信号 | FANTOM5、UCSC、Roadmap、ENCODE | 应按任务选择，不应默认全量下载 ENCODE |

阶段表示数据在统一建模中的主要职责，不代表数据库只能服务一个阶段。例如，GENCODE 主要用于第二阶段的结构对齐，也可作为 TSS 下游任务的高质量标签；MycoCosm 主要用于真菌功能对齐，也可用于真菌专项下游任务。

## 2. 第一阶段：通用序列预训练

### 2.1 数据库划分

| 数据库 | 版本/范围 | 主要内容 | 建模功能 | 当前状态 | 后续动作 |
|---|---|---|---|---|---|
| RefSeq | 已下载的全物种基因组集合 | DNA 基因组序列及配套注释 | DNA 通用预训练核心 | 脚本位于 `refseq/`，不在当前 `genomes/` 下；用户已确认下载完成 | 不重复下载，后续只做 QC、去重、分片和索引 |
| [RNAcentral](rnacentral/download_scheme.md) | Release 26 | ncRNA 序列、RNA 类型、物种与 ID mapping | RNA 通用预训练核心 | v26 位于 `/data1/p252701008/RNAcentral`，约 144 GB；`/data5` 另有旧 v25 和派生数据 | 不重下 FASTA；只补 release metadata 与 mapping |
| [UniProt](uniprot/download_scheme.md) | Release 2026_02 | UniRef、Swiss-Prot、TrEMBL、ID mapping、Reference Proteomes | 蛋白质通用预训练核心 | 主要序列文件已按 manifest 字节数完整，最终 MD5 校验尚未执行 | 先校验核心文件，再补 ID mapping；Reference Proteomes 延后 |

### 2.2 UniProt 当前状态

当前 `all` 计划包含 25 个文件，共 618,535,806,550 bytes；本地已有 263,347,576,631 bytes，当前没有活动下载进程。

已达到目标字节数的主要数据包括：

- Swiss-Prot DAT、FASTA 和可变剪接 FASTA；
- TrEMBL DAT 和 FASTA；
- UniRef50、UniRef90、UniRef100 FASTA。

尚未下载的主要数据包括：

| 数据 | 压缩大小 | 阶段价值 | 决策 |
|---|---:|---|---|
| ID mapping | 14.058 GB | 连接 UniProt、RefSeq、Ensembl 等 ID，是第一阶段到第二阶段的桥梁 | 优先补齐 |
| `sec_ac.txt` | 0.049 GB | 处理历史 accession 与主 accession 的映射 | 与 ID mapping 一并补齐 |
| Reference Proteomes | 341.071 GB | 面向按物种组织的蛋白质组扩展，并非统一预训练前置条件 | 延后下载 |

因此，不需要等待 UniProt `all` 全部完成才进入第二阶段。完成核心文件校验并补齐 ID mapping 后，即可开始注释对齐。

## 3. 第二阶段：注释与知识对齐

### 3.1 通用对齐层

| 优先级 | 数据库 | 固定版本/范围 | 当前默认载荷 | 数据量与存储 | 主要用途 | 当前结论 |
|---|---|---|---|---|---|---|
| P0 | [GTDB](gtdb/download_scheme.md) | R232 / 232.0 | bac120/ar53 metadata、taxonomy、species clusters、QC；代表基因组 FASTA 关闭 | 901,341 个基因组记录、199,923 个物种簇；下载约 0.388 GB，工作空间约 5-15 GB | 给 RefSeq/GenBank 原核 assembly 添加统一分类、质量和去冗余标签 | 下一批优先下载 |
| P0 | [GENCODE](gencode/download_scheme.md) | Human v50 / Mouse M39 | 人、鼠 GTF 与 README；转录本和翻译 FASTA 关闭 | 下载约 0.216 GB，工作空间约 3-5 GB | 高可信基因、转录本、外显子和 TSS 结构标签 | 修复 README 文件名后下载 |
| P0 | [Ensembl](ensembl/download_scheme.md) | Ensembl 116 / Ensembl Genomes 63 | 脊椎动物、植物、真菌、原生生物和后生动物 GTF | 1,149 个物种目录、2,246 个 GTF；下载约 23.36 GB，工作空间约 150-250 GB | 提供广泛真核物种的基因结构对齐 | 修复 listing 父目录解析后下载 |
| P3 | [GenBank](genbank/download_scheme.md) | assembly summary freeze 2026-07-07 | 默认只下载 assembly summary 和 README；assembly payload 关闭 | metadata 体积很小 | 发现 RefSeq 未覆盖的 assembly 和后续补缺候选 | 保持 metadata-only；不下载全量 assembly |

### 3.2 领域知识扩展层

| 优先级 | 数据库 | 当前默认载荷 | 基本规模 | 主要用途 | 前置条件/限制 |
|---|---|---|---|---|---|
| P1 | [MycoCosm](mycocosm/download_scheme.md) | GFF、CAZy、SMURF、annotation；蛋白/CDS FASTA 关闭 | 门户快照约 3,864 个真菌基因组；全库下载粗估 19-193 GB | 真菌基因功能、CAZyme 和次级代谢基因簇对齐 | 需要 JGI 凭证、物种清单和冻结 manifest；按代表物种选择 |
| P1 | [BV-BRC](bv_brc/download_scheme.md) | genome feature、pathway、subsystem TSV | 当前查询 25,000 个基因组、75,000 个 TSV，下载点估计约 1.24 GB | 微生物基因功能、代谢通路和 subsystem 标签 | 当前结果 97.292% 为病毒，必须先修正抽样与物种范围 |
| P1 | [IMG/M](img_m/download_scheme.md) | dataset IDs、功能注释、pathway、COG/KO/Pfam/CAZy | 由人工 cart 决定，无法预先固定总量 | MAG、微生物组与环境微生物功能对齐 | 需要 JGI 登录、人工 cart 和 data policy 记录 |
| P2 | [Phytozome](phytozome/download_scheme.md) | GFF、annotation、CAZy；蛋白/CDS FASTA 关闭 | 门户快照 463 个基因组、194 个物种；全库下载粗估 9-46 GB | 植物基因结构和功能注释 | 仅在植物任务需要时按物种选择；需要 JGI 凭证和冻结 manifest |
| P2 | [VEuPathDB](veupathdb/download_scheme.md) | 当前仅 PlasmoDB 68 的 README、TXT、XML、GFF；FASTA 关闭 | 88 个目录、278 个目标文件，下载约 2.109 GB | 寄生虫和疟原虫专项注释 | 当前不是完整 VEuPathDB，仅是 PlasmoDB 组件 |

第二阶段中，GTDB、GENCODE 和 Ensembl 构成通用对齐层，应先完成。其余数据库属于领域扩展，应根据微生物、真菌、植物、寄生虫或微生物组任务选择，不需要同时全量下载。

## 4. 第三阶段：下游训练与评测

| 优先级 | 数据库 | 固定范围 | 当前默认载荷 | 数据量与存储 | 主要任务 | 下载策略 |
|---|---|---|---|---|---|---|
| P0 | [FANTOM5](fantom5/download_scheme.md) | phase1.3 / phase2.0 | CAGE peaks、TPM、SDRF、README、ChangeLog | 约 2,834 个样本和 360,768 个 CAGE peaks；下载约 4-10 GB，工作空间约 20-50 GB | TSS、promoter、CAGE 信号和表达建模 | 下游库中优先级最高 |
| P1 | [UCSC](ucsc/download_scheme.md) | hg38 / mm39 | chrom.sizes 与 phastCons bigWig；2bit 关闭 | 修正后目标下载量约 10.453 GB | 保守性预测、功能约束和辅助监督 | 将错误的 mm39 60-way 路径修正为官方 35-way 后下载 |
| P1 | [Roadmap](roadmap/download_scheme.md) | 2015 coreMarks final subset | 127 个 epigenome 的 ChromHMM 状态与 EID metadata | 下载约 0.312 GB，工作空间约 1-3 GB | 染色质状态、组织特异性调控和表观组任务 | 规模小，可直接排入第三阶段 |
| P2 | [ENCODE](encode/download_scheme.md) | API freeze 2026-07-07 | GRCh38/mm10 的 DNase、ATAC、ChIP bigWig/bigBed/BED | 当前没有 frozen manifest，精确数量未知，属于多 TB 风险级 | 染色质可及性、TF/组蛋白结合、调控元件和细胞类型任务 | 先定义任务，再选择默认/pooled signal 和 replicated/IDR peaks；不下载全量 |

ENCODE、FANTOM5、Roadmap 和 UCSC 提供的是实验信号或功能标签，不是新增的通用序列知识。它们应服务于后训练、微调、评测或多任务监督，而不是替代 RefSeq、RNAcentral 和 UniProt 的第一阶段语料。

## 5. 推荐下载顺序

在带宽不能并行占用的前提下，按数据科学价值和当前依赖关系执行：

1. 校验已经落盘的 UniProt 核心文件，补齐 ID mapping 和 `sec_ac.txt`；暂缓 Reference Proteomes。
2. 下载 GTDB taxonomy、metadata、species clusters 和 QC 文件。
3. 修复 GENCODE README 路径后，下载人鼠 GTF。
4. 修复 Ensembl listing 解析后，下载广泛真核 GTF。
5. 下载 FANTOM5，建立 TSS/CAGE 下游标签层。
6. 修复 UCSC mm39 phastCons 路径后，下载人鼠保守性轨道。
7. 下载 Roadmap ChromHMM 小型子集。
8. 按微生物与合成生物学需求选择 MycoCosm 代表物种、修正后的 BV-BRC 子集和 IMG/M cart。
9. 有明确植物或寄生虫任务时，再选择 Phytozome 或 VEuPathDB 子集。
10. 明确具体调控任务、输出类型和数据划分后，再生成 ENCODE 子集 manifest。

GenBank metadata 可在任意空闲窗口补齐，但其建模价值低于上述序列、注释和下游监督数据，不应占用主下载队列。

## 6. 当前阻断项

| 数据库 | 阻断项 | 下载前要求 |
|---|---|---|
| UniProt | 当前没有活动下载进程；完整文件尚未完成最终 MD5 验证 | 先执行现有 manifest 的校验，再续传指定缺失数据 |
| GENCODE | 脚本使用 `README.TXT`，官方文件为 `_README.TXT` | 修正目标文件名 |
| Ensembl | listing 中的绝对父目录链接会被误识别为物种目录 | 排除绝对父目录链接并重新生成计划 |
| UCSC | 脚本使用不存在的 mm39 `phastCons60way` | 改为官方 `phastCons35way` 文件和目录 |
| BV-BRC | 默认 25,000 条结果中病毒占 97.292% | 明确细菌、古菌和病毒配额或分别查询 |
| ENCODE | 服务器 live API 受阻，且没有 frozen manifest | 从可访问环境生成任务级 manifest，并按 accession 去重 |
| Phytozome / MycoCosm | 缺少 `.env`、`species_ids.txt` 和 `frozen_file_manifest.tsv` | 完成 JGI 认证、物种选择和候选 manifest 审核 |
| IMG/M | 没有稳定公开批量文件 API | 使用 web cart 手动导出并记录筛选条件和 policy |

## 7. 维护规则

1. 稳定的阶段定位与易变化的下载状态分开维护；每次真实下载前刷新状态快照。
2. 数据库增加 FASTA/2bit/assembly payload 时，必须重新评估与 RefSeq、RNAcentral、UniProt 的重复关系。
3. 第二阶段保留不同来源的注释标签，但训练时应记录来源，避免把相互冲突的注释直接合并为唯一真值。
4. 第三阶段按实验、细胞类型、组织、物种和染色体进行数据划分，防止训练集与评测集泄漏。
5. 任何“全库大小”估算都不能替代冻结 manifest；正式下载计划应以 accession、URL、字节数和 checksum 为准。

## 8. 本地依据

- 各数据库的 `download_scheme.md` 与 `validation_report.md`；
- `genomes/uniprot/download_file_manifest_2026_02.md`；
- `/data/p252701008/datasets/uniprot_2026_02_runlogs/` 中的计划、状态和进度文件；
- `/data1/p252701008/RNAcentral` 与 `/data5/p25wuhx/data/RNAcentral` 的服务器目录快照。
