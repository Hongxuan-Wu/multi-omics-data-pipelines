# TSS/UTR 数据与 PEGS 复现

本目录包含两条独立主线：

1. 从 RefSeq/SRA 元数据中筛选 TSS 或转录组数据。
2. 使用公司的 [zxgsy520/pegs](https://github.com/zxgsy520/pegs) 流程复现 S1 九样本 UTR 注释。

PEGS 是公司实际使用的上游项目，不是本仓库自创流程。复现时固定 commit `043a69d6ad272affda6efdc40990ad3140899c63`，并在本仓库中补充输入隔离、版本锁、过程审计和结果比较。

## 数据来源

4090 上可检查的 SRA 数据入口：

```text
/data/shared/SRA
/data/shared/sra_parquet
```

H100 上可检查的 SRA XML full 索引入口：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

RefSeq 原始数据已下载到：

```text
/data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
```

## 目录结构

```text
.
├── README.md                        # 本目录唯一入口
├── RefSeq与SRA关联查询流程.md       # 公共数据关联、筛选和下载列表生成
├── tss注释流程.png                  # 公司提供的原始流程图
├── resources/                       # S1参考基因组、原始/公司版GFF
├── tss_utr_annotation_flow_review_20260709/
│   └── tss_utr_annotation_flow_review.md  # 工具能力与TSS证据边界审计
├── tss_utr_reproduction_20260710/
│   ├── README.md                    # 当前执行状态
│   ├── design.md                    # 公司PEGS流程复现设计
│   ├── implementation_plan.md       # 当前唯一实施计划
│   ├── config/                      # 配置与九样本清单
│   ├── scripts/                     # 已实现的隔离/预检脚本
│   └── tests/                       # 小型契约测试
├── tools/                           # 第三方工具和PEGS源码，Git忽略
└── trash/                           # 旧文档与清理文件，不属于现行入口
```

## 公共数据筛选

1. RefSeq 侧先从 `assembly_summary_refseq.txt` 生成 `refseq_assembly_core.parquet`。
2. SRA 侧使用 `SRA_Accessions` Parquet 过滤可下载 RUN。
3. SRA XML full 索引用于补充 sample attributes、library strategy、platform、BioSample/BioProject/Taxon。
4. 优先用 BioSample 关联 RefSeq 和 SRA。
5. 生成 `selected_sra_runs.tsv` 作为后续下载输入。

具体 SQL 和字段见 `RefSeq与SRA关联查询流程.md`。

## S1 UTR 复现

当前公司流程数据链：

```text
9 paired FASTQ
-> fastp
-> STAR
-> 9 x guided StringTie
-> StringTie merge
-> PEGS transcript preparation
-> PASA/minimap2 alignment SQLite
-> PASA annotation update
-> AGAT keep longest isoform
-> S1.genome_reproduced.gff3
```

现行文档：

- [执行状态](tss_utr_reproduction_20260710/README.md)
- [复现设计](tss_utr_reproduction_20260710/design.md)
- [实施计划](tss_utr_reproduction_20260710/implementation_plan.md)
- [流程能力审计](tss_utr_annotation_flow_review_20260709/tss_utr_annotation_flow_review.md)

正式运行仍受 fastp `-n 0` 数据兼容性门禁阻断。普通 RNA-seq 可支持候选 UTR 和候选 TSS，不能直接作为实验验证 TSS。

## 文件管理

- `resources/` 中既有的 S1 参考与公司结果基线继续由 Git 保存；该目录新增的原始数据和过程文件被忽略。
- `tools/`、`work/`、`logs/`、`results/` 和日常运行垃圾不纳入 Git。
- 旧方案不再出现在主目录；已移动到 `trash/legacy_docs_20260711/`。为遵守不删除文档的约束，该迁移目录继续由 Git 保存，但不属于现行方案。
