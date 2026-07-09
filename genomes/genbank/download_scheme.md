# NCBI GenBank

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | NCBI Datasets API 可用；本脚本采用 assembly_summary_genbank.txt 作为精准 manifest。 |
| 固定版本 | 本地冻结的 assembly_summary_genbank.txt；默认不刷新，REFRESH_MANIFEST=1 才更新 |
| 固定入口 | https://ftp.ncbi.nlm.nih.gov/genomes/genbank/ |
| manifest 中心 | assembly_summary_genbank.txt + md5/sha256 digest；解析以 ftp_path 锚定并记录坏行 |
| metadata 同步 | 默认同步 assembly_summary_genbank.txt 与 README_assembly_summary.txt；开启 assembly 文件下载时同步每个 assembly 的 md5checksums.txt |
| 校验策略 | metadata-only 模式只校验下载链路；开启 assembly 文件下载时每个 assembly 用 md5checksums.txt 强校验 |
| 差异报告 | 报告 manifest 解析异常与远端 HEAD 不可达目标 |

## 2. 脚本说明

脚本：download_genbank.sh。

序列下载开关：`DOWNLOAD_GENBANK_ASSEMBLY_FILES=0`。默认 metadata-only，不筛选和下载 `genomic.fna.gz` / `genomic.gff.gz`，避免和 RefSeq 主库重复。需要补 RefSeq 覆盖缺口时再设为 `1`。

## 3. 来源

- https://ftp.ncbi.nlm.nih.gov/genomes/genbank/
