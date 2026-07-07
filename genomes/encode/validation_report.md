# encode 校验报告

## 1. 结论

本报告为 Group D 修复后的库内校验记录。ENCODE 保持 REST API + `FREEZE_DATE=2026-07-07` 方案；缺失 `md5sum` 的 API 记录现在写入差异报告、排除下载计划并直接失败，不再降级为弱校验。未运行真实下载。

## 2. 修复项

| finding | 状态 | 证据 |
|---|---|---|
| Important-1：缺失 MD5 时仍允许下载并弱校验 | 已修复 | `download_encode.sh` 对空 md5 写 `NO_MD5_EXCLUDED` 并 `die`；`verify_after_download` 不再调用弱校验兜底。 |
| Important-2：assembly 字段 jq 表达式存在类型风险 | 已修复 | jq 新增 `normalized_assembly`，显式处理 array/string/null/其他类型。 |
| 静态补充：计划写入使用未定义 `host` 变量 | 已修复 | 计划 URL 改为使用已定义的 `${ENCODE_HOST}`。 |

## 3. 流程验收

| 校验项 | 状态 | 结论 |
|---|---|---|
| 脚本流程性 | 通过 | API manifest 后生成 plan/diff，再下载和强校验。 |
| 脚本文本 | 通过 | assembly 解析为显式类型判断；URL host 使用 `ENCODE_HOST`。 |
| 鲁棒性 | 通过 | 有 md5 才进入下载计划；MD5 失败进入 `move_to_trash`。 |
| 方案一致性 | 通过 | `download_scheme.md` 已同步说明缺失 MD5 直接失败。 |
| 完整性 | 通过 | `download_scheme.md`、`download_encode.sh`、`validation_report.md` 齐全。 |

## 4. 未执行项

未运行真实下载；`jq` 表达式因本机未安装 jq，未做运行态解析测试；`bash -n` 结果见本轮总修复报告。
