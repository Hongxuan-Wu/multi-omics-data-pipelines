# Ensembl / Ensembl Genomes

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | Ensembl REST API 可查元数据；批量 GTF 走固定 FTP release 目录。 |
| 固定版本 | Ensembl 116 / Ensembl Genomes 63 |
| 固定入口 | https://ftp.ensembl.org/pub/release-116/ 与 https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-63/ |
| manifest 中心 | FTP listing + species_Ensembl*.txt |
| metadata 同步 | species metadata 同步下载；bacteria division 暂不纳入，原核侧由 GTDB/RefSeq/BV-BRC 覆盖 |
| 校验策略 | GTF gzip 弱校验，CHECKSUMS 保存审计 |
| 差异报告 | 报告 listing 不可读目录 |

## 2. 脚本说明

脚本：download_ensembl.sh。

## 3. 来源

- https://rest.ensembl.org/documentation/info/species
- https://ftp.ensembl.org/pub/release-116/
- https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-63/
