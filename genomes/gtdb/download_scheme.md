# GTDB R232

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 官网提供 HTTPS 目录；未采用 API，固定 release232/232.0 目录更适合批量复现。 |
| 固定版本 | R232 / 232.0 |
| 固定入口 | https://data.gtdb.ecogenomic.org/releases/release232/232.0/ |
| manifest 中心 | MD5SUM.txt + FILE_DESCRIPTIONS.txt |
| metadata 同步 | bac120/ar53 metadata、taxonomy、species cluster、QC 失败清单同步下载 |
| 校验策略 | MD5SUM.txt 强校验 |
| 差异报告 | 报告 planned_without_md5 与 checksum_not_planned |

## 2. 脚本说明

脚本：download_gtdb.sh。

序列下载开关：`DOWNLOAD_GTDB_REP_GENOMES=0`。默认不下载 `gtdb_genomes_reps_r232.tar.gz`，只保留 GTDB taxonomy / metadata / species cluster，用于给 RefSeq/GenBank 原核 assembly 做分类和去冗余映射。确需直接训练 GTDB representative genome 序列时再设为 `1`。

## 3. 来源

- https://data.gtdb.ecogenomic.org/releases/release232/232.0/
