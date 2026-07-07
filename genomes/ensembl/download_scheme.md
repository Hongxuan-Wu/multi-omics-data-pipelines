# Ensembl / Ensembl Genomes

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | Ensembl REST API 可查元数据；批量 GTF 走固定 FTP release 目录。 |
| 固定版本 | Ensembl 116 / Ensembl Genomes 63 |
| 固定入口 | https://ftp.ensembl.org/pub/release-116/ 与 https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-63/ |
| manifest 中心 | FTP listing + species_Ensembl*.txt + 每个 species 目录官方 CHECKSUMS |
| metadata 同步 | species metadata 同步下载；bacteria division 暂不纳入，原核侧由 GTDB/RefSeq/BV-BRC 覆盖 |
| 校验策略 | 当前 Ensembl release 的 `CHECKSUMS` 不等同于 MD5 manifest；脚本只在解析到真实 32 hex MD5 时对 GTF 写入 `checksum=md5=...` 并执行 `md5sum --check`。无官方 MD5 的 GTF 不阻断计划生成，下载后走 `gzip -t` 或非空弱校验，并写入未强校验 manifest。 |
| 差异报告 | 报告 listing 不可读目录、CHECKSUMS 缺失/不可读、GTF 无官方 MD5、零 GTF payload；`CHECKSUMS` 同步保存为审计/差异核对文件。 |

## 2. 脚本说明

脚本：download_ensembl.sh。

## 3. 来源

- https://rest.ensembl.org/documentation/info/species
- https://ftp.ensembl.org/pub/release-116/
- https://ftp.ebi.ac.uk/ensemblgenomes/pub/release-63/
