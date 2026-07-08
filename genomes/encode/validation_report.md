# encode 校验报告

## 1. 结论

本报告为服务器复验后的库内校验记录。ENCODE 保持 REST API + `FREEZE_DATE=2026-07-07` 方案；缺失 `md5sum` 的 API 记录写入差异报告、排除下载计划并直接失败，不降级为弱校验。2026-07-08 服务器复验显示当前主机访问 `www.encodeproject.org` 返回 403；脚本已增加 API preflight，若 ENCODE API 不可达会在批量查询前明确失败并写入差异报告。未运行真实下载。

## 2. 修复项

| finding | 状态 | 证据 |
|---|---|---|
| Important-1：缺失 MD5 时仍允许下载并弱校验 | 已修复 | `download_encode.sh` 对空 md5 写 `NO_MD5_EXCLUDED` 并 `die`；`verify_after_download` 不再调用弱校验兜底。 |
| Important-2：assembly 字段 jq 表达式存在类型风险 | 已修复 | jq 新增 `normalized_assembly`，显式处理 array/string/null/其他类型。 |
| 静态补充：计划写入使用未定义 `host` 变量 | 已修复 | 计划 URL 改为使用已定义的 `${ENCODE_HOST}`。 |
| 服务器复验：ENCODE API 返回 403 | 已加固 | 新增 `probe_encode_api_access`，先检查最小 API JSON；不可达时立即停止并记录 `api_probe FAILED`。 |

## 3. 流程验收

| 校验项 | 状态 | 结论 |
|---|---|---|
| 脚本流程性 | 通过 | API manifest 后生成 plan/diff，再下载和强校验。 |
| 脚本文本 | 通过 | assembly 解析为显式类型判断；URL host 使用 `ENCODE_HOST`。 |
| 鲁棒性 | 通过 | API 不可达先失败；有 md5 才进入下载计划；MD5 失败进入 `move_to_trash`。 |
| 方案一致性 | 通过 | `download_scheme.md` 已同步说明缺失 MD5 直接失败。 |
| 完整性 | 通过 | `download_scheme.md`、`download_encode.sh`、`validation_report.md` 齐全。 |

## 4. 未执行项

服务器已安装 jq；Linux 服务器 `bash -n` 已通过；未运行真实下载。
