# UniProt 2026_02 下载合同

## 1. 固定范围

| 字段 | 合同值 |
|---|---|
| Release | `2026_02` |
| 机器可读清单 | `download_file_manifest_2026_02.tsv` |
| 清单数据行 SHA-256 | `1107165a1a1256314ec193202f127f40f8d64308a6c609d0fdf03b91728e5070` |
| 必需文件 | 25 个 |
| 压缩总字节 | 618,535,806,550 bytes |
| 默认选择 | `uniref50`，3 个文件 |
| 全合同选择 | `--all` |
| 默认 payload 根目录 | `/data2/p252701008/genomes/uniprot_2026_02` |
| 默认运行证据根目录 | `/data/p252701008/datasets/uniprot_2026_02_runlogs` |

`--all` 仅表示当前批准清单中的 25 个目标，不表示 UniProt 官方站点的全部产品。UniParc、GOA、XML、RDF、Pan Proteomes、Proteomes REST 导出和其他未列入清单的文件均不在本合同内。

## 2. 数据职责

| 数据组 | 主要职责 |
|---|---|
| `uniprotkb_complete` | 分开的 Swiss-Prot/TrEMBL FASTA 和 DAT，以及共享 README/metalink |
| `uniprotkb_accessions` | secondary accession 映射 `sec_ac.txt` 及其 metalink |
| `uniref50/90/100` | 三个聚类层级的 FASTA、README 和 metalink |
| `idmapping` | UniProt 与其他数据库标识符的全量映射 |
| `reference_proteomes` | Reference Proteomes 完整归档、README、STATS 和 metalink |

## 3. 完成判据

每个所选目标必须同时满足以下条件：

1. 本地文件存在，且不存在同名 `.aria2` sidecar。
2. 文件字节数与冻结清单一致。
3. `static_file` 的官方 MD5 与清单一致。
4. `release_manifest` 包含 `<version>2026_02</version>`。
5. 所有目标通过同一次终态强校验，状态才可写为 `COMPLETE`。

终态定义：

| 状态 | 退出码 | 含义 |
|---|---:|---|
| `COMPLETE` | 0 | 所选目标全部通过强校验 |
| `PLANNED` | 0 | 离线计划已生成，未下载 |
| `NEEDS_REPAIR` | 20 | 仍有缺失、partial、校验失败或永久远端错误 |
| `BLOCKED` | 30 | 路径、清单、安全门、磁盘、权限、锁或内部前置条件阻塞 |
| `INTERRUPTED` | 130/143 | 收到 SIGINT/SIGTERM，partial 与 sidecar 保留 |

## 4. 生命周期

```text
INITIALIZED -> PLANNED
            -> VERIFYING -> COMPLETE | NEEDS_REPAIR
            -> LOCKED -> PREFLIGHT -> TRANSFERRING -> VERIFYING
                                      ^                   |
                                      |---- RECOVERING ----|
                                                       -> COMPLETE
                                                       -> NEEDS_REPAIR/BLOCKED
```

下载前必须完成本地清单合同检查和远端 release metalink 检查。每轮 aria2 结束后均以磁盘实际状态为准重新校验；aria2 返回非零但全部文件已完整时，允许判定成功。

## 5. 恢复合同

- 最小恢复粒度是清单中的单个文件。
- 带 `.aria2` 的文件视为可续传 partial，原地保留。
- 无 sidecar 且校验失败的完整文件移动到 `RUN_ROOT/trash`，不删除。
- 每轮失败后生成 `plans/repair_plan_<run>.attempt<N>.tsv`。
- 默认最多执行 3 个外层恢复轮次；aria2 每轮内部默认重试 10 次。
- `RATE_LIMITED`、`TRANSIENT_NETWORK` 和 `VALIDATION_FAILED` 可进入下一轮。
- `REMOTE_PERMANENT` 终止为 `NEEDS_REPAIR`。
- `STORAGE_BLOCKED`、`AUTH_CONFIG` 和 `INTERNAL_INVARIANT` 终止为 `BLOCKED`。
- 参数、清单、路径、安全门、依赖或锁问题记为 `CONFIG_BLOCKED` 并终止为 `BLOCKED`。

## 6. 安全边界

1. `LOCAL_ROOT` 与 `RUN_ROOT` 必须是不同、互不嵌套的绝对路径，且都不能是 `/`。
2. `CHECK_REMOTE_RELEASE=1`、`VERIFY_AFTER_DOWNLOAD=1`、`SKIP_VERIFIED_FILES=1` 是不可关闭的安全门。
3. 下载模式按规范化 `LOCAL_ROOT` 获取独占 flock；更换 `RUN_ROOT` 不能绕过锁。
4. `--plan-only` 和 `--verify-only` 不创建或修改 payload 根目录。
5. `--verify-only` 不移动任何 payload；异常仅写入报告和修复计划。
6. 日志消息会转为单行，并遮蔽常见 token/password/API-key 赋值。
7. 脚本不执行删除命令；异常证据与旧文件只进入 `trash`。

## 7. 证据目录

```text
RUN_ROOT/
|-- logs/       主日志、错误日志、每轮 aria2 console/transport/failure 日志
|-- plans/      下载计划、aria2 输入、每轮修复计划
|-- manifests/  冻结清单快照、强校验报告
|-- status/     每次运行的状态/进度历史及 latest 快照
|-- reports/    每次运行的终态摘要及 latest 摘要
|-- tmp/        远端 release 探针等运行期证据
|-- locks/      锁位置审计记录
`-- trash/      隔离的无效文件，不自动删除
```

`status/latest_status.tsv` 保存最近一次运行的完整状态历史；`status/latest_progress.tsv` 保存最新进度行；`reports/latest_summary.md` 保存最近终态摘要。
