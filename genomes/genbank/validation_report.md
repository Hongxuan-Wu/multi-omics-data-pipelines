# genbank 校验报告

## 1. 结论

本报告为主会话整合子智能体只读校验后的结果。已修复校验中指出的阻断项和重要问题。Linux 服务器 `bash -n` 已通过；真实下载未执行。

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

## 3. Group A 复修记录（2026-07-07）

- 已修复 C1：`select_assemblies` 现在统计非注释 selected assembly；数量为 0 时立即失败。`build_download_plan` 现在统计总计划数和非 metadata genome payload 数；payload 为 0 时立即失败。
- 已修复 C2：移除 `md5sum --check --ignore-missing`，改为按下载计划中的 genome payload 逐项读取同目录 `md5checksums.txt` 并执行强 MD5 校验；缺失、空文件、checksum 条目缺失或 MD5 失败时调用 `move_to_trash` 隔离 payload/`.aria2`/异常 checksum 文件。
- 静态复查：未发现残留 `--ignore-missing`；未发现 `rm`、`rm -f`、`rm -rf`、`del`、`Remove-Item`；未运行真实下载。
- 服务器复验：Linux 服务器 `bash -n genomes/genbank/download_genbank.sh` 已通过。

## 4. 统一建模下载策略更新（2026-07-09）

- 已新增：`DOWNLOAD_GENBANK_ASSEMBLY_FILES=0`，默认 metadata-only，不筛选和下载 GenBank assembly payload。
- 已调整：metadata-only 模式只生成 `assembly_summary_genbank.txt` 与 README 下载计划，并跳过 assembly MD5 校验。
- 已新增：`FULL_SEQUENCE_MIN_DISK_GB`，仅开启 assembly 文件下载时恢复全量磁盘阈值。
