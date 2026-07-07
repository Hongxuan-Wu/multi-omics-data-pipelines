# veupathdb 校验报告

## 1. 结论

本报告为 Group D 修复后的库内校验记录。VEuPathDB 仍限定为 PlasmoDB release-68；已补充持久化 `remote_listing_${RUN_ID}.tsv`，记录 listing URL、href、child URL、是否选入计划和说明。未运行真实下载。

## 2. 修复项

| finding | 状态 | 证据 |
|---|---|---|
| Minor-1：未单独持久化完整 remote listing manifest | 已修复 | `download_veupathdb.sh` 新增 `REMOTE_LISTING_MANIFEST`，在递归 listing 时写入 selected_for_plan 与 note。 |

## 3. 流程验收

| 校验项 | 状态 | 结论 |
|---|---|---|
| 脚本流程性 | 通过 | 配置校验后生成 plan、diff、remote listing manifest，再下载和校验。 |
| 脚本文本 | 通过 | 固定入口为 `https://plasmodb.org/common/downloads/release-68`，未使用 latest/current。 |
| 鲁棒性 | 通过 | aria2 断点续传、复跑跳过、弱校验失败进入 `move_to_trash`。 |
| 方案一致性 | 通过 | `download_scheme.md` 已同步说明 remote listing manifest。 |
| 完整性 | 通过 | `download_scheme.md`、`download_veupathdb.sh`、`validation_report.md` 齐全。 |

## 4. 未执行项

未运行真实下载；`bash -n` 结果见本轮总修复报告。
