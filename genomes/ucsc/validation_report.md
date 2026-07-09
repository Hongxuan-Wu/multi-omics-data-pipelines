# ucsc 校验报告

## 1. 结论

本轮已修复 Group B 指出的 UCSC Critical/Important 项：去除 GNU awk 三参数 `match(..., array)` 依赖；`CHECKSUM_REQUIRED=1` 时未声明 weak policy 的计划目标缺 MD5 会失败；phastCons bigWig 明确为无官方 MD5 的弱校验目标；freeze 表述改为 static target freeze with live official md5 audit。未运行真实下载。

## 2. 流程验收

| 序号 | 步骤 | 状态 | 结论 |
|---:|---|---|---|
| 1 | 固定版本与入口 | 已修复 | `RELEASE` 改为 `hg38_mm39_static_targets_2026-07-07_live_md5_audit` |
| 2 | freeze 语义 | 已修复 | 脚本固定 TARGET_RECORDS，运行时拉取 live official md5sum 审计，不再暗示远端内容完整冻结 |
| 3 | awk 兼容性 | 已修复 | metalink 解析改为 POSIX awk/sed 风格，不要求 gawk |
| 4 | bigZips 强校验 | 已完成 | bigZips 目标必须匹配官方 MD5 并写入 aria2 checksum |
| 5 | phastCons policy | 已修复 | hg38 phastCons100way 与 mm39 phastCons60way 显式记录 `EXPLICIT_WEAK_POLICY` 并执行非空弱校验 |
| 6 | 缺 MD5 处理 | 已修复 | 未声明 weak policy 的计划目标缺 MD5 时失败 |
| 7 | 静态语法检查 | 通过 | Linux 服务器 `bash -n genomes/ucsc/download_ucsc.sh` 已通过 |

## 3. 统一建模下载策略更新（2026-07-09）

- 已新增：`DOWNLOAD_UCSC_2BIT=0`。
- 默认跳过 hg38/mm39 `.2bit` 序列，只下载 chrom.sizes 与 phastCons bigWig 等坐标/保守性辅助文件。
