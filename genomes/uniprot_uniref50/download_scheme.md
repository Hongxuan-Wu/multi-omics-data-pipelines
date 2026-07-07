# UniProt UniRef50 2026_02

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | UniProt 提供 REST API，但完整 UniRef50 批量文件以 FTP current_release + RELEASE.metalink 固定 2026_02。 |
| 固定版本 | 2026_02 |
| 固定入口 | https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/uniref50/ |
| manifest 中心 | RELEASE.metalink 内含版本、大小、MD5 与镜像 URL；脚本断言 metalink version=2026_02 |
| metadata 同步 | XML 注释与 FASTA 同步下载，并归档 RELEASE.metalink |
| 校验策略 | 解析 RELEASE.metalink 的 MD5 强校验，再做 gzip 弱校验 |
| 差异报告 | 报告 metalink/listing 中存在但未纳入计划的文件 |

## 2. 脚本说明

脚本：download_uniprot_uniref50.sh。

## 3. 来源

- https://www.uniprot.org/api-documentation
- https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/uniref50/
