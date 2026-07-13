# uniprot_uniref50 校验报告

## 1. 结论

当前目录使用 UniProt `2026_02` 静态清单驱动流程。最终合同为 25 个文件、618,535,806,550 bytes；默认只选择 UniRef50。

本轮没有下载数据库正文，也没有解压或建立索引。官方元数据检查只读取 7 个 `RELEASE.metalink`。

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
| 篡改 manifest | 即使总数和总字节不变也必须拒绝 | 通过 |
| 禁用远端 release 检查 | 必须拒绝 | 通过 |
| 禁用下载后复核 | 必须拒绝 | 通过 |
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

## 5. 未执行项

- 未执行 618.536 GB 的真实全量下载。
- 未对数据库正文做解压、索引或下游生物学内容抽检。
- 因此本报告证明的是清单、控制流、选择逻辑和官方元数据的一致性，不等同于真实数据已落盘。

## 6. 范围外旧门禁

仓库级 `genomes/tests/test_static_contracts.sh` 仍绑定已废弃合同，要求旧变量 `DOWNLOAD_UNIREF50_SEQUENCE_ARCHIVE`、UniRef XML、Pan Proteomes 和 13,524 行清单。当前实测在旧变量断言处失败。

用户明确要求本次只修改 `genomes/uniprot_uniref50`，因此未修改 `genomes/tests/test_static_contracts.sh`，也未在新脚本中加入无效兼容字符串来伪造通过。当前目录的有效门禁为 `test_manifest_contract.sh`；仓库级旧测试需要在另行授权后更新。
