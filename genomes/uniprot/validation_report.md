# UniProt 校验报告

## 1. 结论

当前目录使用 UniProt `2026_02` 静态清单驱动的可恢复流程。最终合同仍为 25 个文件、618,535,806,550 bytes；默认只选择 UniRef50。可靠性重构没有改变任何下载目标或批准清单 SHA-256。

2026-07-14 本轮没有访问 UniProt 网络端点，没有下载数据库正文，也没有解压或建立索引。验证全部使用冻结清单、临时目录、本地 payload 和 fake aria2 故障注入；因此不会写入默认 `/data2` 数据目录或 `/data` 运行目录。

## 2. 清单验收

| 检查 | 预期 | 结果 |
|---|---:|---:|
| release | `2026_02` | 通过 |
| 官方 7 个 metalink 重新生成 | 与静态 TSV 除生成时间外逐字一致 | 通过 |
| 总文件数 | 25 | 通过 |
| 总压缩字节 | 618,535,806,550 | 通过 |
| `uniprotkb_complete` | 7 | 通过 |
| `uniprotkb_accessions` | 2 | 通过 |
| `uniref50` / `uniref90` / `uniref100` | 各 3 | 通过 |
| `idmapping` | 3 | 通过 |
| `reference_proteomes` | 4 | 通过 |
| 相对路径重复 | 0 | 通过 |
| 静态文件缺失 MD5 | 0 | 通过 |
| 非官方 URL | 0 | 通过 |

已确认关键官方 MD5：

- `Reference_Proteomes_2026_02.tar.gz`: `dac5c26eaf65eb2c5e9615f8faf2c9d7`
- `sec_ac.txt`: `36985d8756a672823f60f1b81acece9a`

## 3. 下载器验收

| 场景 | 预期 | 结果 |
|---|---|---|
| 无参数 `--plan-only` | 只规划 UniRef50 的 3 个文件 | 通过 |
| `--dataset uniprotkb --plan-only` | 规划 complete 与 accessions，共 9 个文件 | 通过 |
| `--dataset swissprot --plan-only` | 5 项且不包含 TrEMBL 正文 | 通过 |
| `--dataset trembl --plan-only` | 4 项且不包含 Swiss-Prot 正文 | 通过 |
| `--dataset multiomics --plan-only` | accessions + idmapping + Reference Proteomes，共 9 项 | 通过 |
| `--all --plan-only` | 规划全部 25 个文件 | 通过 |
| `--all` 与 `--dataset` 同时使用 | 参数错误并在建计划前退出 | 通过 |
| 空 MD5 的 metalink 行 | 8 列对齐，类型为 `release_manifest` | 通过 |
| 静态文件行 | 保留官方 MD5，类型为 `static_file` | 通过 |
| `--plan-only` | 不访问网络、不启动 aria2 | 通过 |
| `--plan-only` | 不创建 payload 根目录 | 通过 |
| 默认存储根目录 | payload 位于 `/data2`，运行证据位于 `/data` | 通过 |
| `--verify-only` 缺失目标 | 返回 20、写校验/修复报告、不移动 payload | 通过 |
| `--status` / `--summary` | 不依赖 `LOCAL_ROOT`，可读取最近证据 | 通过 |
| 篡改 manifest | 即使总数和总字节不变也必须拒绝 | 通过 |
| 禁用远端 release 检查 | 必须拒绝 | 通过 |
| 禁用下载后复核 | 必须拒绝 | 通过 |
| 禁用已验证文件跳过 | 必须拒绝 | 通过 |
| `/`、相同或嵌套根目录 | 建目录前以退出码 30 拒绝 | 通过 |
| 同一数据根、不同运行根并发 | 第二个进程锁冲突并返回 30 | 通过 |
| HTTP 429/503/404/403、磁盘错误 | 分类为既定错误类 | 通过 |
| 首轮 503、次轮成功 | 保留 sidecar、生成修复计划并自动恢复 | 通过 |
| 连续 503 达到轮次上限 | 返回 20、保留 sidecar 和修复计划 | 通过 |
| aria2 非零但最终文件完整 | 以强校验结果判定完成 | 通过 |
| 传输中 SIGTERM | 返回 143、记录 `INTERRUPTED`、保留 sidecar | 通过 |
| aria2 失败后的无效完整文件 | 移入 `trash`；partial 保留 | 通过 |

## 4. 保护措施

1. 下载前校验本地 manifest 的版本、范围、大小、MD5 和路径。
2. 实际下载前读取所选 `RELEASE.metalink`，检查版本和字节数未漂移。
3. aria2 启用断点续传，并把官方 MD5 写入下载任务。
4. 已有文件按 MD5 或大小验证后跳过。
5. 不匹配文件只移动到 `RUN_ROOT/trash`，不删除。
6. 下载后复核大小、MD5 或 metalink version，并写出校验报告。
7. 每次运行保存下载计划和静态 manifest 快照。
8. 对 manifest 数据行执行批准合同 SHA-256，阻止 URL、路径、大小或 MD5 被等量替换。
9. aria2 失败后区分可续传 partial 与无 sidecar 文件，后者复核失败才隔离。
10. 每次运行写状态历史、进度快照和 Markdown 终态摘要；分轮保留 console、transport 和 failure 日志。
11. 锁绑定规范化数据根目录；切换运行日志目录不能绕过并发保护。
12. 下载失败后按文件生成修复计划并执行有界恢复，重试耗尽后返回明确的 20/30 终态。
13. `--verify-only` 与修复核验分离，审计过程不改变 payload。

## 5. 未执行项

- 未执行 618.536 GB 的真实全量下载。
- 未对 UniProt 远端执行本轮实时 release 探针；真实下载启动时脚本会强制执行该门禁。
- 未对数据库正文做解压、索引或下游生物学内容抽检。
- 因此本报告证明的是冻结清单、参数、状态、恢复、故障处置和离线控制流，不等同于真实数据已落盘。

## 6. 已执行命令

```bash
bash genomes/uniprot/test_manifest_contract.sh
bash genomes/uniprot/test_operational_contract.sh
bash genomes/tests/test_static_contracts.sh
bash -n genomes/uniprot/download_uniprot.sh
git diff --check
```

上述前三项均通过。`test_operational_contract.sh` 不访问网络，并覆盖 fake aria2 重试恢复与 SIGTERM 中断。服务器实际安装的 `aria2c 1.37.0` 也使用 `/dev/null` 输入通过了完整参数组合解析，未发起下载。最终门禁同时确认受保护路径未变化。
