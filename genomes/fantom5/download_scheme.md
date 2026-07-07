# FANTOM5

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | SSTAR API 只适合目录/语义查询；bulk 数据用固定 phase 目录。 |
| 固定版本 | phase1.3 / phase2.0 |
| 固定入口 | https://fantom.gsc.riken.jp/5/datafiles/phase1.3/ 和 phase2.0 |
| manifest 中心 | 递归读取固定 phase 目录 listing，自建 manifest，并持久化 `remote_listing_${RUN_ID}.tsv` |
| metadata 同步 | CAGE peak、TPM matrix 与 SDRF/readme/changelog 同步下载 |
| 校验策略 | gzip/非空弱校验 |
| 差异报告 | 报告 listing 不可读、remote_not_selected 与弱校验失败；remote listing manifest 记录 listing URL、href、child URL、是否选入计划 |

## 2. 脚本说明

脚本：download_fantom5.sh。

## 3. 来源

- https://fantom.gsc.riken.jp/5/data/
- https://fantom.gsc.riken.jp/5/datafiles/phase1.3/
- https://fantom.gsc.riken.jp/5/datafiles/phase2.0/
