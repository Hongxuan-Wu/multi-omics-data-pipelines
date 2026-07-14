# UniProt 数据资源调研与统一建模方案

## 1. 文档口径

| 项 | 说明 |
|---|---|
| 调研日期 | 2026-07-13；下载器运行机制复核于 2026-07-14 |
| 当前官方版本 | UniProt Release `2026_02`，发布日期 2026-06-10 |
| 当前下载脚本版本 | `download_uniprot.sh` 使用经过审核的 `2026_02` 静态 manifest |
| 存储单位 | 十进制 GB，`1 GB = 10^9 bytes` |
| 存储口径 | 官方压缩下载文件大小，不含解压、索引、训练缓存和文件系统冗余 |

脚本 URL 使用官方 `current_release`，但不跟随版本静默漂移。下载前会检查所选 `RELEASE.metalink` 仍为 `2026_02`；版本或字节数变化时立即停止，要求重新生成并审核清单。

## 2. 核心结论

| 目标 | 推荐数据集 | 原因 |
|---|---|---|
| 统一蛋白序列建模核心 | UniRef50 FASTA | 多物种覆盖广、冗余低、规模可控，适合作为第一阶段预训练语料 |
| 高可信监督与验证 | UniProtKB/Swiss-Prot | 人工审校、证据清晰，适合功能标签、验证集和高质量评测 |
| 扩展细粒度序列知识 | UniRef90 FASTA | 比 UniRef50 保留更多近缘变体，适合第二阶段扩展 |
| 物种与系统发育覆盖 | Reference Proteomes | 按代表性蛋白组组织，便于跨物种采样和评测 |
| 完整功能注释检索 | UniProtKB complete | 同时包含 Swiss-Prot 和 TrEMBL，注释丰富，但冗余与弱标注更多 |
| 最大序列覆盖和历史追踪 | UniParc | 覆盖 UniProtKB 及更多公共、历史和失活序列，但缺少 UniProtKB 的丰富功能注释 |

统一建模的原则不是“只使用最干净的少量数据”，而是：

1. 保留广泛的物种、蛋白家族和长尾序列覆盖。
2. 通过去冗余、污染过滤和质量控制降低无效重复。
3. 不把自动注释噪声当作高可信监督标签。
4. 使用 Swiss-Prot 承担监督与验证，使用 UniRef 承担广覆盖表征学习。

本项目最终下载合同为 25 个文件、618,535,806,550 bytes：

| 需求 | 纳入的数据 |
|---|---|
| 全量序列比对 | Swiss-Prot FASTA、varsplic FASTA、TrEMBL FASTA |
| 可区分 reviewed/unreviewed | Swiss-Prot 与 TrEMBL 保持为独立文件 |
| 完整条目注释 | Swiss-Prot DAT、TrEMBL DAT |
| 统一建模 | UniRef50、UniRef90、UniRef100 FASTA |
| 多组学和标识符对齐 | `idmapping.dat.gz`、`sec_ac.txt`、Reference Proteomes |
| 可追溯下载 | 每个目录对应的 README、STATS（如有）和 `RELEASE.metalink` |

UniParc、GOA、RDF、Pan Proteomes、Proteomes REST 和其他派生目录仍可作为后续研究对象，但不属于当前下载合同。

## 3. UniProt 数据资源体系

UniProt 官方严格定义三个数据库家族：

1. `UniProtKB`：蛋白序列与功能知识库。
2. `UniRef`：UniProt Reference Clusters，提供不同相似度层级的聚类数据。
3. `UniParc`：UniProt Archive，保存当前和历史蛋白序列及来源。

`Proteomes`、`Reference Proteomes` 和 `Pan Proteomes` 是基于上述数据库组织或派生的数据资源，不是第四、第五个主数据库家族。

### 3.1 数据量、存储占用与用途

| 数据库或数据集 | 2026_02 数据量 | 官方压缩存储占用 | 主要内容 | 主要功能 |
|---|---:|---:|---|---|
| UniProtKB/Swiss-Prot | 575,503 个 reviewed 条目 | FASTA 0.094 GB；DAT 0.699 GB；XML 0.942 GB；varsplic FASTA 0.0086 GB | 人工审校序列、功能、结构域、修饰、疾病、文献和证据 | 高可信标签、验证集、功能注释 |
| UniProtKB/TrEMBL | 149,234,636 个 unreviewed 条目 | FASTA 40.543 GB；DAT 118.072 GB；XML 142.935 GB | 自动分析和自动注释蛋白，物种与长尾家族覆盖广 | 扩展序列空间、弱监督和长尾知识 |
| UniProtKB complete | 149,810,139 个条目 | FASTA 40.637 GB；DAT 118.771 GB；XML 143.877 GB；下载全部格式约 303.294 GB | Swiss-Prot 与 TrEMBL 的并集 | 完整功能知识库、检索和注释 |
| UniRef100 | 220,919,788 个簇 | FASTA 63.102 GB；XML 79.145 GB | 全部 UniProtKB 加选定 UniParc 记录；聚合相同序列和子片段 | 最大覆盖下去除完全重复 |
| UniRef90 | 121,389,642 个簇 | FASTA 32.059 GB；XML 46.499 GB | 基于 UniRef100 seed 的 90% identity 聚类 | 训练规模与细粒度知识折中 |
| UniRef50 | 38,794,121 个簇 | FASTA 8.770 GB；XML 20.576 GB | 基于 UniRef90 seed 的 50% identity 聚类 | 强去冗余的统一建模核心语料 |
| UniParc | 1,158,429,795 个唯一序列记录；其中 active 1,086,882,406，inactive 71,547,389 | active FASTA 239.043 GB，共 200 分片；all XML 675.808 GB，共 200 分片 | 公共数据库当前和历史序列，按完全相同全长序列合并，保留来源和版本 | 全量序列归档、来源追踪、历史恢复 |
| Proteomes catalog | 1,086,758 个 proteome 记录：reference 36,465、non-reference 476,871、excluded 573,422 | 无单一官方全量包；REST 导出体积随字段和格式变化 | 基因组组装对应的蛋白组元数据、状态和质量信息 | 按物种、组装和 proteome ID 检索 |
| Reference Proteomes | FTP 包含 36,466 个 proteome 目录；138,154,580 条 canonical 和 8,978,977 条 additional 序列，共 147,133,557 条 | 完整 tar.gz 341.071 GB | 代表生命树多样性的蛋白组，以及蛋白、CDS、XML、DAT 和映射文件 | 跨物种建模、系统发育和标准评测 |
| Pan Proteomes | 3,195 个物种数据集；67,243 个输入 proteome；270,173,927 条输入蛋白；最终 24,141,274 条代表序列 | FASTA 5.339 GB；全部文件 5.470 GB | 同一物种多个蛋白组的 core/accessory 聚类、代表序列和存在缺失矩阵 | 泛蛋白组、菌株多样性和核心/可变功能分析 |

注意：FASTA、DAT 和 XML 是同一生物数据的不同分发格式。除非确实需要多种表示，不应把三个格式全部下载并视为新增数据。

## 4. 包含和派生关系

### 4.1 唯一严格的 UniProtKB 包含关系

```text
UniProtKB complete
|-- UniProtKB/Swiss-Prot: reviewed, manually curated
`-- UniProtKB/TrEMBL: unreviewed, automatically annotated
```

因此：

```text
UniProtKB complete = Swiss-Prot + TrEMBL
```

下载 UniProtKB complete 后，序列和条目层面已经包含 Swiss-Prot 与 TrEMBL。仍可单独保存 Swiss-Prot，以便构建高可信标签层和独立验证集。

### 4.2 UniParc 是序列档案覆盖，不是完整注释包含

```text
UniParc
|-- UniProtKB 中所有蛋白对应的序列
|-- 其他公共数据库中的额外序列
`-- 已删除或失活的历史序列
```

UniParc 的序列覆盖范围大于 UniProtKB，但二者记录结构不同：

- UniParc 重点保存唯一序列、来源数据库、版本和 active/inactive 状态。
- UniProtKB 重点保存蛋白名称、功能、结构域、文献、证据和交叉引用。
- 下载 UniParc 不能替代 UniProtKB 的功能注释。

### 4.3 UniRef 是逐级聚类压缩，不是普通文件子集

```text
全部 UniProtKB 记录 + 选定的 UniParc 记录
                    |
                    v
                UniRef100
          相同序列和子片段聚类
                    |
                    v
                 UniRef90
             90% identity 聚类
                    |
                    v
                 UniRef50
             50% identity 聚类
```

正确理解是：UniRef100、UniRef90、UniRef50 是由细到粗的聚类层级，而不是简单删除部分记录形成的文件子集。

| 下载内容 | 实际获得 | 没有获得 |
|---|---|---|
| UniRef100 FASTA | 每个 UniRef100 簇的一条代表序列和简化 header | 全部原始成员序列、UniProtKB 完整注释 |
| UniRef90 FASTA | 每个 UniRef90 簇的一条代表序列 | UniRef100 全部代表序列和原始成员序列 |
| UniRef50 FASTA | 每个 UniRef50 簇的一条代表序列 | UniRef90/100 全部代表序列和原始成员序列 |
| UniRef XML | 代表序列、成员交叉引用、成员数、公共分类单元等 | UniProtKB 条目的完整功能注释 |

长度小于 11 aa 的序列保留在 UniRef100，但不进入 UniRef90 和 UniRef50 聚类。

### 4.4 Proteomes 是按基因组组织的数据视图

```text
Proteomes catalog
|-- Reference Proteomes
|-- Non-reference Proteomes
`-- Excluded Proteomes

Pan Proteomes
`-- 对同一物种的多个合格 Proteome 进行聚类后生成
```

- Reference Proteomes 是 Proteomes catalog 中选出的代表性蛋白组。
- Reference Proteome 的蛋白序列来自 UniProtKB，并同时可在 UniParc 中追踪。
- 当前 non-reference 和 excluded proteome 的蛋白序列主要保留在 UniParc。
- Pan Proteomes 使用 Reference Proteome 蛋白和选定 UniParc 蛋白构建，不是 Reference Proteomes 的简单超集。

### 4.5 下载某个库后是否已经拥有其他库

| 已下载的数据 | 是否等价于获得其他库 | 结论 |
|---|---|---|
| UniProtKB complete | 是 | 已包含 Swiss-Prot 与 TrEMBL 条目 |
| Swiss-Prot | 否 | 不包含 TrEMBL，也不等价于 complete |
| TrEMBL | 否 | 不包含 Swiss-Prot，也不等价于 complete |
| UniParc | 部分 | 覆盖 UniProtKB 的序列，但没有 UniProtKB 完整注释 |
| UniRef50 FASTA | 否 | 只有代表序列，不能替代 UniRef90、UniRef100 或 UniProtKB |
| Reference Proteomes | 否 | 只是选定蛋白组，不是全部 UniProtKB 或全部 Proteomes |
| Pan Proteomes | 否 | 是跨同物种多个 proteome 的派生聚类数据 |

## 5. 统一建模数据策略

### 5.1 为什么以 UniRef50 FASTA 为核心

1. **覆盖广**：来源覆盖 UniProtKB 和选定 UniParc，不局限于少数模式物种。
2. **冗余低**：50% identity 层级显著降低近重复序列对训练采样的支配。
3. **规模可控**：当前压缩 FASTA 为 8.770 GB，明显小于 UniRef90、UniRef100 和 UniParc。
4. **输入简单**：FASTA 可以直接进入序列清洗、tokenization、分片和预训练流程。
5. **适合统一表征**：每条序列代表更宽的蛋白家族范围，有利于学习跨物种和跨家族的共享规律。

UniRef50 的“干净”主要来自去冗余，不意味着生物范围狭窄。它与仅使用 Swiss-Prot 或仅使用模式物种不同，仍然保留广泛的序列空间。

### 5.2 为什么不以 UniProtKB complete 作为第一阶段核心

UniProtKB complete 包含 Swiss-Prot，但其约 99.62% 条目来自 TrEMBL。作为第一阶段训练核心存在以下问题：

1. 大量近重复物种和近缘菌株会造成采样偏置。
2. 自动注释质量不均，不能直接作为高可信功能监督。
3. FASTA 规模约为 UniRef50 的 4.6 倍，但新增信息中包含大量冗余。
4. 需要额外设计去重、物种平衡和功能标签置信度策略。

UniProtKB complete 仍然重要，但更适合作为后续注释检索、长尾补充和弱监督来源。

### 5.3 干净数据与知识覆盖的平衡

应避免两种极端：

| 极端 | 风险 |
|---|---|
| 只使用 Swiss-Prot 或少数模式物种 | 标签干净，但损失多物种、长尾家族和生态多样性 |
| 直接使用全部 TrEMBL 注释作为标签 | 覆盖广，但自动注释错误可能被模型当作真实监督 |

推荐做法：

- 序列表征学习使用多物种、去冗余的 UniRef50/UniRef90。
- 功能监督、验证和高质量检索使用 Swiss-Prot。
- TrEMBL 注释仅作为有置信度控制的弱标签或候选知识。
- Reference Proteomes 用于物种均衡采样和跨物种评测。
- 通过 UniRef cluster 进行 train/validation/test 拆分，降低同源序列泄漏。

## 6. 数据科学价值与下载优先级

| 优先级 | 数据集 | 建议格式 | 建模角色 | 进入下一阶段的条件 |
|---:|---|---|---|---|
| P0 | UniRef50 | FASTA | 第一阶段统一序列表征核心 | 完成序列 QC、去异常、分片和基础预训练 |
| P0 | Swiss-Prot | FASTA + varsplic FASTA + DAT | 高可信监督、验证、功能注释和序列比对 | 建立证据等级、任务标签和同源隔离评测 |
| P1 | UniRef90 | FASTA | 增加近缘变体和细粒度序列知识 | UniRef50 训练收敛且需要扩展容量 |
| P1 | ID mapping + secondary accession | DAT/TXT | UniProt 与基因、转录本、蛋白组及其他数据库标识符对齐 | 建立目标组学的字段解析与一对多关系规则 |
| P1 | Reference Proteomes | 官方完整 tar + STATS | 物种平衡、系统发育、组装上下文和跨物种评测 | 建立物种采样与 proteome-level split |
| P2 | TrEMBL | FASTA + DAT | 全量比对、长尾覆盖、注释检索和受控弱监督 | 建立冗余控制和标签置信度策略 |
| P2 | UniRef100 | FASTA | 100% 聚类层级、细粒度检索和近重复序列研究 | 明确需要精确层级映射或检索 |

P0 中的 UniRef50 和 Swiss-Prot 不是互相替代，而是分别承担“广覆盖表征学习”和“高可信监督/验证”。

这是数据科学价值顺序，不是要求同时下载。磁盘或带宽受限时，按 `UniRef50 -> Swiss-Prot -> UniRef90 -> ID mapping -> Reference Proteomes -> TrEMBL -> UniRef100` 推进。

## 7. 推荐的数据分层

```text
Layer 1: sequence_core
`-- UniRef50 FASTA

Layer 2: trusted_annotation
`-- Swiss-Prot FASTA + varsplic FASTA + DAT

Layer 3: coverage_expansion
|-- UniRef90 FASTA
`-- Reference Proteomes

Layer 4: long_tail_and_retrieval
|-- TrEMBL FASTA + DAT
`-- UniRef100

Layer 5: cross_omics_alignment
|-- idmapping.dat.gz
`-- sec_ac.txt
```

训练和评测数据应保留以下字段：

- 原始 accession 或 cluster ID。
- 来源数据库及 release。
- reviewed/unreviewed 状态。
- taxonomy ID、proteome ID 和 reference proteome 状态。
- UniRef100、UniRef90、UniRef50 cluster 映射。
- 标签来源、证据等级和生成方式。
- 清洗、去重和过滤原因。

## 8. 当前项目实现边界

当前目录中的 `download_uniprot.sh`：

- release 与静态 manifest 固定为 `2026_02`。
- 无参数默认选择 UniRef50 的 README、metalink 和 FASTA。
- `--dataset` 支持 7 个 manifest 数据组、`swissprot`/`trembl` 子集视图，以及 `uniprotkb`、`uniref`、`multiomics` 预设；`--all` 选择全部 25 个文件。
- `--plan-only` 离线生成可审阅计划，不访问网络。
- `--verify-only` 只读执行完整性校验并生成最小文件级修复清单，不移动 payload。
- `--status` 和 `--summary` 读取最近状态、进度与终态证据。
- 下载前检查远端 metalink 版本和字节数，避免 `current_release` 静默漂移。
- 静态文件按官方 MD5 强校验，metalink 按大小和 release version 校验。
- 支持绑定数据根目录的独占锁，避免两个进程并发写入相同 payload。
- 支持 aria2 断点续传、已验证文件跳过、外层有界恢复、分轮错误日志、manifest 快照、运行报告和异常文件移入 `trash`。
- 使用 `RATE_LIMITED`、`TRANSIENT_NETWORK`、`REMOTE_PERMANENT`、`STORAGE_BLOCKED`、`AUTH_CONFIG`、`CONFIG_BLOCKED`、`VALIDATION_FAILED` 和 `INTERNAL_INVARIANT` 区分补救动作。
- 以强校验而非 aria2 退出码作为最终完成判据；中断时保留 partial 与 `.aria2` sidecar。

机器可读合同见 `download_file_manifest_2026_02.tsv`，逐文件人工清单见 `download_file_manifest_2026_02.md`，运行合同与操作命令分别见 `download_contract.md` 和 `runbook.md`。

## 9. 已知差异与更正

1. Reference Proteomes FTP `README/STATS` 包含 36,466 个 proteome 目录；当前 Proteomes REST facet 标记 36,465 个 reference proteome。容量规划使用 FTP 的 36,466，API 查询过滤使用 REST 的 36,465，不推断这一条差异的具体原因。
2. Reference Proteomes 的 additional/isoform-variant 序列总数按当前 `STATS` 汇总为 8,978,977。此前调研中的 139,095 不能作为该资源的总 additional 序列数，应废弃。
3. `current_release` 会随 UniProt 发布更新。当前脚本通过静态 manifest、MD5 和下载前版本断言锁定 `2026_02`；待官方归档入口可用后，可在不改变文件合同的前提下切换为归档 URL。

## 10. 官方来源

- UniProt 数据库总览：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/README>
- UniProt 2026_02 release notes：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/relnotes.txt>
- UniProtKB complete：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/>
- UniRef100：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/uniref100/>
- UniRef90：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/uniref90/>
- UniRef50：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/uniref50/>
- UniRef 帮助：<https://www.uniprot.org/help/uniref>
- UniParc：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniparc/>
- Proteomes 帮助：<https://www.uniprot.org/help/proteome>
- Proteomes REST：<https://rest.uniprot.org/proteomes/search>
- Reference Proteomes：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/reference_proteomes/>
- Pan Proteomes：<https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/pan_proteomes/>
