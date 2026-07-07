# Roadmap Epigenomics

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 无统一现行 API；使用 Roadmap 静态 data/byFileType 入口。 |
| 固定版本 | 2015 static tracks freeze |
| 固定入口 | https://egg2.wustl.edu/roadmap/data/ |
| manifest 中心 | metadata xlsx + byFileType 路径 |
| metadata 同步 | epigenome metadata 同步下载 |
| 校验策略 | gzip/非空弱校验 |
| 差异报告 | 报告无 MD5 条目 |

## 2. 脚本说明

脚本：download_roadmap.sh。

## 3. 来源

- https://egg2.wustl.edu/roadmap/web_portal/
- https://egg2.wustl.edu/roadmap/data/
