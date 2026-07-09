# RNAcentral Release 26

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | RNAcentral 有 REST API 和公共 PostgreSQL；全量序列/metadata 以 FTP release 目录为准。 |
| 固定版本 | Release 26 |
| 固定入口 | https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/ |
| manifest 中心 | 保存 release 根目录及 sequences/id_mapping/md5/database_files listing；md5/md5.tsv.gz 是序列 MD5 映射，不是下载文件 checksum |
| metadata 同步 | 默认同步 id_mapping、md5.tsv、toc.dat、release notes；active/inactive/species-specific FASTA 由开关控制 |
| 校验策略 | 未找到顶层文件级 MD5 时走 gzip 弱校验 |
| 差异报告 | 报告 planned_not_in_listing 与 remote_not_planned |

## 2. 脚本说明

脚本：download_rnacentral.sh。

序列下载开关：`DOWNLOAD_RNACENTRAL_SEQUENCES=0`。因当前服务器已有 RNAcentral 全量序列，本轮默认只补 metadata / mapping；需要重下 Release 26 FASTA 时设为 `1`。

## 3. 来源

- https://rnacentral.org/downloads
- https://rnacentral.org/api
- https://ftp.ebi.ac.uk/pub/databases/RNAcentral/releases/26.0/
