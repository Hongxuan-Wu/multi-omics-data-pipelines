# Transcriptomics Pipelines

> DSS 分支。TSS / 转录组数据构建流水线，含 NCBI SRA 元数据审计、XML 实体关系索引和 RefSeq↔SRA 关联设计。

## 目录结构

```text
.
├── README.md                                 # 本文件
├── TSS数据处理.md                            # 顶层设计：RefSeq↔SRA 关联方案与表结构
├── sra_accessions_audit_full_20260601/       # SRA_Accessions.tab 并行审计（full 版，32 分片）
└── sra_xml_index_cpp/                        # SRA XML 实体关系索引 C++ 流水线
```

## 子模块

### `TSS数据处理.md` — 顶层设计

转录组 / TSS 数据的整体处理方案。核心目标：

- RefSeq `assembly_summary_refseq.txt` → `refseq_assembly_linkage.tsv`（带 biosample 关联键）
- SRA 元数据 → `sra_run_metadata.tsv`（可下载 RUN + LibraryStrategy/Source 判定）
- 通过 `biosample ↔ BioSample` 关联得到 `refseq_sra_transcriptomic_runs.tsv`

### `sra_accessions_audit_full_20260601/`

对 `SRA_Accessions.tab` 的并行审计产物（1.48 亿行 / 32 分片 / 16 workers）。

- `code/`：C++ 分片审计 + Python 合并 + Shell 并行调度
- `outputs/sra_accessions_parallel_audit.{md,json}`：Accession 前缀 / Type / Status / Visibility / 关键字段非缺失计数等统计

### `sra_xml_index_cpp/`

SRA XML 实体关系索引流水线，已完成 100k stress pilot 验证（core/relation/attribute 准确率 1.0）。

- `sra_xml_indexer.cpp`：C++ 解析器
- `generate_directory_manifest.py`：稳定目录清单（避免 760 万目录重扫）
- `run_cpp_chunked_parallel.sh`：分片并行调度（CHUNK_SIZE=500 / WORKERS=16）
- `convert_tsv_chunks_to_parquet.py`：TSV → Parquet（DuckDB strict + 行数校验）
- `evaluate_parquet_index.py`：QC（缺失率 / 关系闭合率 / 全量体积估算）
- `validate_against_xml.py`：原 XML 随机回查
- `README_build_process.md` / `README_query_usage.md`：建索引流程 + 查询样例

## 数据约定

- 数据集标识：`NCBI_SRA_Metadata_Full_20260516`（约 760 万目录 / 1.48 亿行 SRA Accession）
- 主关联键：`RefSeq biosample ↔ SRA BioSample`（BioProject 只做辅助校验）
- 下载单位：仅 `Type = RUN` 的 SRA Accession
- 并行参数基线：`CHUNK_SIZE=500` / `WORKERS=16` / `CHUNK_TIMEOUT=900`

## 关联工具 / 服务器

- 4090 服务器：`ssh -p 24722 m252202014@223.2.43.222`，项目根 `/home/m252202014/SRA/`
- 共享数据盘：`/data/p252701008/datasets/SRA/`、`/data/shared/`
- SRA XML 索引输出：`/data/shared/sra_xml_index_*`
