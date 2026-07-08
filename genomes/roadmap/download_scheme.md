# Roadmap Epigenomics ChromHMM coreMarks + metadata subset

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 无统一现行 API；本脚本只使用 Roadmap 静态 data/byFileType/metadata 与 data/byFileType/chromhmmSegmentations/ChmmModels/coreMarks/jointModel/final 子集入口。 |
| 固定版本 | 2015 static tracks 中的 metadata + ChromHMM coreMarks final 子集 |
| 固定入口 | https://egg2.wustl.edu/roadmap/data/ |
| manifest 中心 | TARGET_RECORDS subset manifest + metadata/coreMarks final remote listing |
| metadata 同步 | EID_metadata.tab 同步下载 |
| 校验策略 | 优先使用 https://egg2.wustl.edu/roadmap/data/checksums.md5 中匹配到的官方 MD5；否则 gzip/非空弱校验 |
| 差异报告 | 报告无 MD5 条目、remote listing 中未纳入 subset 的文件、计划 URL 不在对应 listing 中的目标 |

## 2. 脚本说明

脚本：download_roadmap.sh。范围限定为 ChromHMM coreMarks final 的 all.mnemonics.bedFiles.tgz 与 EID_metadata.tab；不声称覆盖完整 Roadmap byFileType。

## 3. 来源

- https://egg2.wustl.edu/roadmap/web_portal/
- https://egg2.wustl.edu/roadmap/data/
- https://egg2.wustl.edu/roadmap/data/byFileType/metadata/
- https://egg2.wustl.edu/roadmap/data/byFileType/chromhmmSegmentations/ChmmModels/coreMarks/jointModel/final/
