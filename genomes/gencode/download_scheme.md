# GENCODE v50/M39

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 官网与 FTP 提供固定 release；不需要 API。 |
| 固定版本 | Human v50 / Mouse M39 |
| 固定入口 | https://ftp.ebi.ac.uk/pub/databases/gencode/ |
| manifest 中心 | MD5SUMS / README |
| metadata 同步 | 人鼠 GTF、transcripts、translation 同步下载 |
| 校验策略 | `CHECKSUM_REQUIRED=1`；所有计划目标必须匹配官方 MD5SUMS，aria2 写入 `checksum=md5=...`，下载后执行 `md5sum --check`；缺 MD5 不降级为弱校验 |
| 差异报告 | 报告计划与 checksum 差异；任一计划目标缺 MD5 时失败 |

## 2. 脚本说明

脚本：download_gencode.sh。

## 3. 来源

- https://www.gencodegenes.org/
- https://ftp.ebi.ac.uk/pub/databases/gencode/
