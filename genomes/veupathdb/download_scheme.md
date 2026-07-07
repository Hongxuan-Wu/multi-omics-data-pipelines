# VEuPathDB

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 有 WDK service API；批量文件下载按各 component 固定 release 目录。 |
| 固定版本 | PlasmoDB release-68 |
| 固定入口 | https://plasmodb.org/common/downloads/release-68/ |
| manifest 中心 | Apache index 递归生成自建 manifest |
| metadata 同步 | 固定 release 目录中的 README/txt/xml/GFF/FASTA 同步下载 |
| 校验策略 | 无官方 checksum 时走 gzip/非空弱校验 |
| 差异报告 | 报告 listing 不可读、remote_not_selected 与弱校验失败 |

## 2. 脚本说明

脚本：download_veupathdb.sh；默认示例锁定 PlasmoDB release-68，可扩展其他 component。

## 3. 来源

- https://veupathdb.org/veupathdb/service/record-types
- https://plasmodb.org/common/downloads/
