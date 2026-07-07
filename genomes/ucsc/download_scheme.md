# UCSC hg38/mm39

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | UCSC REST API 可查小片段；大文件轨道用 hgdownload 固定路径。 |
| 固定版本 | hg38/mm39 static target freeze 2026-07-07 with live official md5 audit |
| 固定入口 | https://hgdownload.soe.ucsc.edu/goldenPath/ |
| manifest 中心 | 脚本内固定 TARGET_RECORDS + bigZips live official md5sum.txt |
| metadata 同步 | chrom.sizes 同步下载 |
| 校验策略 | bigZips 目标必须匹配官方 MD5 并执行 aria2/md5sum 强校验；hg38/mm39 phastCons bigWig 未找到对应官方 MD5 文件，显式标记 `EXPLICIT_WEAK_POLICY`，执行非空弱校验；其他缺 MD5 目标失败 |
| 差异报告 | 报告 checksum 未纳入计划的文件、计划目标缺 MD5、phastCons 显式 weak policy |

## 2. 脚本说明

脚本：download_ucsc.sh。

## 3. 来源

- https://api.genome.ucsc.edu/
- https://hgdownload.soe.ucsc.edu/
