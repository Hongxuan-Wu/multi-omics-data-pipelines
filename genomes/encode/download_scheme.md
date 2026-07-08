# ENCODE

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 优先使用 ENCODE REST API 生成 manifest。 |
| 固定版本 | FREEZE_DATE=2026-07-07 |
| 固定入口 | https://www.encodeproject.org/search/ |
| manifest 中心 | API JSONL manifest |
| metadata 同步 | API 字段 accession/md5sum/assembly/assay 同步保存 |
| 校验策略 | API md5sum 强校验；缺失 md5sum 的 API 记录写入差异报告并直接失败，不降级为弱校验 |
| 差异报告 | 报告 API preflight/query 失败与缺失 MD5；缺失 MD5 的记录不进入下载计划 |

## 2. 脚本说明

脚本：download_encode.sh。正式查询前先执行最小 API preflight；若当前服务器访问 ENCODE 返回 403 或 JSON 结构不符合预期，会在批量查询前失败并记录差异报告。

## 3. 来源

- https://www.encodeproject.org/help/rest-api/
- https://www.encodeproject.org/
