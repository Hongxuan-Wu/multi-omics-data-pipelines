# NCBI GenBank

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | NCBI Datasets API 可用；本脚本采用 assembly_summary_genbank.txt 作为精准 manifest。 |
| 固定版本 | 本地冻结的 assembly_summary_genbank.txt；默认不刷新，REFRESH_MANIFEST=1 才更新 |
| 固定入口 | https://ftp.ncbi.nlm.nih.gov/genomes/genbank/ |
| manifest 中心 | assembly_summary_genbank.txt + md5/sha256 digest；解析以 ftp_path 锚定并记录坏行 |
| metadata 同步 | README_assembly_summary.txt 与每个 assembly 的 md5checksums.txt |
| 校验策略 | 每个 assembly 下载后用 md5checksums.txt 强校验 |
| 差异报告 | 报告 manifest 解析异常与远端 HEAD 不可达目标 |

## 2. 脚本说明

脚本：download_genbank.sh。

## 3. 来源

- https://ftp.ncbi.nlm.nih.gov/genomes/genbank/
