# GTDB R232

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 官网提供 HTTPS 目录；未采用 API，固定 release232/232.0 目录更适合批量复现。 |
| 固定版本 | R232 / 232.0 |
| 固定入口 | https://data.gtdb.ecogenomic.org/releases/release232/232.0/ |
| manifest 中心 | MD5SUM.txt + FILE_DESCRIPTIONS.txt |
| metadata 同步 | bac120/ar53 metadata 与 taxonomy 同步下载 |
| 校验策略 | MD5SUM.txt 强校验 |
| 差异报告 | 报告 planned_without_md5 与 checksum_not_planned |

## 2. 脚本说明

脚本：download_gtdb.sh。

## 3. 来源

- https://data.gtdb.ecogenomic.org/releases/release232/232.0/
