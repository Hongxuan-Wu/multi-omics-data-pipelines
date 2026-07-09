# BV-BRC

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 使用 BV-BRC Data API 查询 genome metadata，并通过 Data API TSV 导出功能注释表。 |
| 固定版本 | Data API freeze 2026-07-07 |
| 固定入口 | https://www.bv-brc.org/api/ |
| manifest 中心 | Data API genome TSV 生成 genome_id 下载计划 |
| metadata 同步 | genome_summary / genome_metadata 由 Data API TSV 固定查询导出，并保存 Data API probe |
| 校验策略 | 未发现全局 MD5，走 TSV 非空弱校验；无记录表保留表头视为有效 TSV |
| 差异报告 | 报告 API probe 失败、下载失败和弱校验失败 |

## 2. 脚本说明

脚本：download_bv_brc.sh。主下载不再依赖 FTPS/lftp；默认导出 `genome_feature`、`pathway`、`subsystem` 三类 TSV，并使用字段白名单降低 BV-BRC 空结果接口返回 500 的风险。

## 3. 来源

- https://www.bv-brc.org/
- https://www.bv-brc.org/api/
