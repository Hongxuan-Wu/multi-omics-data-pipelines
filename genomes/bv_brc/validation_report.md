# bv_brc 校验报告

## 1. 结论

本报告为服务器复验后的库内校验记录。2026-07-08 复验发现旧 API probe 查询 `limit(10)&select(...)` 返回 400；已改为 BV-BRC Data API RQL 查询 `eq(genome_status,Complete)&limit(10)&select(...)`。脚本语法在 Linux 服务器上已通过 `bash -n`。真实下载仍要求服务器安装 `lftp` 访问官方 FTPS。

## 2. 流程验收

| 序号 | 步骤 | 状态 | 验收标准 | 结论 |
|---:|---|---|---|---|
| 1 | 下载方案撰写 | 已完成 | 写明 API/FTP 判断、固定版本、manifest、metadata、校验策略 | 阻断项已修复；未执行真实下载 |
| 2 | 方案完整性校验 | 已整合子智能体反馈 | 覆盖入口、版本、metadata、差异报告与复跑策略 | 阻断项已修复；未执行真实下载 |
| 3 | 方案合理性校验 | 已整合子智能体反馈 | 优先 API；无合适 API 时使用固定 FTP/HTTPS/release 目录 | 阻断项已修复；未执行真实下载 |
| 4 | 下载脚本撰写 | 已完成 | 独立脚本、source common.sh、Linux 命令、USE_PROXY=0 | 阻断项已修复；未执行真实下载 |
| 5 | 脚本流程性校验 | 已完成静态校验 | plan/report 在 download 前生成，download 后 verify | 阻断项已修复；未执行真实下载 |
| 6 | 脚本文本错误校验 | 已完成静态校验 | 修复已发现的路径、版本、manifest 与注释不一致问题 | 阻断项已修复；未执行真实下载 |
| 7 | 脚本鲁棒性校验 | 已完成静态校验 | 断点续传、并行控制、失败报错、异常文件移入 trash | 阻断项已修复；未执行真实下载 |
| 8 | 方案和脚本一致性校验 | 已完成 | 方案字段与脚本变量、入口和校验策略一致 | 阻断项已修复；未执行真实下载 |
| 9 | 总体合理性校验 | 已完成 | 不使用 latest 作为版本；特殊库记录边界 | 阻断项已修复；未执行真实下载 |
| 10 | 总体完整性校验 | 已完成 | 脚本、方案、校验报告、手动说明均归入独立库目录 | 阻断项已修复；未执行真实下载 |

## 3. 服务器复验追加记录

- 已修复：Data API probe 查询语法，当前服务器对 `eq(genome_status,Complete)&limit(10)&select(genome_id,genome_name,genome_status)` 返回 200。
- 待环境满足：主下载仍依赖 `lftp`；当前服务器未安装 `lftp` 时该库不能真实运行。
- 已完成：Linux 服务器 `bash -n genomes/bv_brc/download_bv_brc.sh` 通过。
- 未执行：真实 FTPS 下载。
