# BV-BRC

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | BV-BRC Data API 可查 genome metadata；批量文件下载仍按官方 FTPS。API probe 使用 RQL 查询 `eq(genome_status,Complete)`。 |
| 固定版本 | FTPS/API freeze 2026-07-07 |
| 固定入口 | ftps://ftp.bvbrc.org/；API probe: https://www.bv-brc.org/api/genome/ |
| manifest 中心 | RELEASE_NOTES/genome_summary 与 genome_metadata |
| metadata 同步 | genome_summary / genome_metadata 同步下载，并保存 Data API probe |
| 校验策略 | 未发现全局 MD5，走非空弱校验 |
| 差异报告 | 报告 API probe 失败、下载失败和弱校验失败 |

## 2. 脚本说明

脚本：download_bv_brc.sh。主下载依赖 `lftp` 访问 BV-BRC FTPS；若目标服务器未安装 `lftp`，脚本会在依赖检查阶段退出。

## 3. 来源

- https://www.bv-brc.org/
- https://www.bv-brc.org/api/
- ftps://ftp.bvbrc.org/
