# gencode 校验报告

## 1. 结论

本轮已修复 Group B 指出的 GENCODE Critical/Important 项：去除 GNU awk 三参数 `match(..., array)` 依赖；`CHECKSUM_REQUIRED=1` 时任一计划目标缺官方 MD5 会失败，不再静默降级为弱校验。未运行真实下载。

## 2. 流程验收

| 序号 | 步骤 | 状态 | 结论 |
|---:|---|---|---|
| 1 | 固定版本与入口 | 已完成 | Human v50 / Mouse M39 固定入口不变 |
| 2 | awk 兼容性 | 已修复 | metalink 解析改为 POSIX awk/sed 风格，不要求 gawk |
| 3 | checksum 获取 | 已完成 | Human/Mouse 官方 MD5SUMS 下载失败时直接失败 |
| 4 | 缺 MD5 处理 | 已修复 | `write_manifests_and_diff`、`write_aria_input`、`verify_after_download` 均禁止 required checksum 降级 |
| 5 | aria2 强校验 | 已完成 | 有 MD5 的目标写入 `checksum=md5=...` |
| 6 | 下载后校验 | 已完成 | 有 MD5 的目标执行 `md5sum --check` |
| 7 | 静态语法检查 | 待目标环境确认 | 本机未完成 Bash 语法解析；需在 Linux 服务器执行 `bash -n genomes/gencode/download_gencode.sh` |
