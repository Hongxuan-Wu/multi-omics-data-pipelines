# roadmap 校验报告

## 1. 结论

本报告为 Group D 修复后的库内校验记录。Roadmap 已明确收窄为 `metadata + ChromHMM coreMarks final` 子集，不再声称完整覆盖 Roadmap byFileType。脚本补充对应 remote listing URL，并清理非 Roadmap checksum 泛化残留逻辑。未运行真实下载。

## 2. 修复项

| finding | 状态 | 证据 |
|---|---|---|
| Important-3：静态 byFileType 覆盖和差异报告能力偏弱 | 已修复 | `download_roadmap.sh` 标题、`RELEASE` 和方案均收窄为 subset；`REMOTE_LISTING_URLS` 指向 metadata 与 coreMarks final。 |
| Minor-2：非 Roadmap checksum 泛化残留注释/死逻辑 | 已修复 | 已移除外部 release XML 版本断言、XML hash 解析和对应 diff 分支。 |

## 3. 流程验收

| 校验项 | 状态 | 结论 |
|---|---|---|
| 脚本流程性 | 通过 | checksum/listing、plan、manifest/diff、aria2、校验顺序完整。 |
| 脚本文本 | 通过 | 文档和脚本标题均限定为 ChromHMM coreMarks + metadata subset。 |
| 鲁棒性 | 通过 | 无官方 MD5 时记录 `PLANNED_WITHOUT_MD5` 并执行弱校验；失败进入 `move_to_trash`。 |
| 方案一致性 | 通过 | `download_scheme.md` 已同步 subset 范围与 remote listing URL。 |
| 完整性 | 通过 | `download_scheme.md`、`download_roadmap.sh`、`validation_report.md` 齐全。 |

## 4. 未执行项

未运行真实下载；`bash -n` 结果见本轮总修复报告。
