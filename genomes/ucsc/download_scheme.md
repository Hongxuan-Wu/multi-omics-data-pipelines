# UCSC hg38/mm39

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | UCSC REST API 可查小片段；大文件轨道用 hgdownload 固定路径。 |
| 固定版本 | hg38/mm39 freeze 2026-07-07 |
| 固定入口 | https://hgdownload.soe.ucsc.edu/goldenPath/ |
| manifest 中心 | bigZips md5sum.txt |
| metadata 同步 | chrom.sizes 同步下载 |
| 校验策略 | bigZips 有 MD5 时强校验，其他 track 弱校验 |
| 差异报告 | 报告 checksum 未纳入计划的文件 |

## 2. 脚本说明

脚本：download_ucsc.sh。

## 3. 来源

- https://api.genome.ucsc.edu/
- https://hgdownload.soe.ucsc.edu/
