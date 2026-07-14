# UniProt 下载运行手册

默认存储布局：

| 内容 | 默认根目录 |
|---|---|
| 数据正文（payload） | `/data2/p252701008/genomes/uniprot_2026_02` |
| 日志、计划、状态、报告、tmp、trash | `/data/p252701008/datasets/uniprot_2026_02_runlogs` |

## 1. 前置检查

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines/genomes/uniprot
bash -n download_uniprot.sh
bash test_manifest_contract.sh
bash test_operational_contract.sh
```

真实下载需要 `bash`、`awk`、`aria2c`、`curl`、`flock`、`md5sum`、`sha256sum`、`readlink`、`sed`、`stat` 和足够的磁盘空间。

## 2. 先生成计划

默认 UniRef50：

```bash
bash download_uniprot.sh --plan-only \
  --local-root /data2/p252701008/genomes/uniprot_2026_02 \
  --run-root /data/p252701008/datasets/uniprot_2026_02_runlogs
```

全部批准目标：

```bash
bash download_uniprot.sh --all --plan-only \
  --local-root /data2/p252701008/genomes/uniprot_2026_02 \
  --run-root /data/p252701008/datasets/uniprot_2026_02_runlogs
```

审阅 `RUN_ROOT/plans/download_plan_*.tsv` 的数据组、相对路径、目标路径、文件数和总字节。`--all` 是 25 文件合同，不是 UniProt 官方全部产品。

## 3. 后台启动

```bash
RUN_ROOT=/data/p252701008/datasets/uniprot_2026_02_runlogs
RUN_TAG="$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "${RUN_ROOT}/nohup"

nohup bash download_uniprot.sh --all \
  --local-root /data2/p252701008/genomes/uniprot_2026_02 \
  --run-root "${RUN_ROOT}" \
  --download-attempts 3 \
  --retry-wait 60 \
  --progress-interval 120 \
  1>"${RUN_ROOT}/nohup/uniprot_2026_02_${RUN_TAG}.log" 2>&1 &
printf '%s\n' "$!" > "${RUN_ROOT}/uniprot_2026_02.pid"
```

同一 `LOCAL_ROOT` 同时只能有一个下载进程。锁冲突返回 `30`，不会启动第二份 aria2。

## 4. 查看状态和日志

```bash
bash download_uniprot.sh --status \
  --run-root /data/p252701008/datasets/uniprot_2026_02_runlogs

bash download_uniprot.sh --summary \
  --run-root /data/p252701008/datasets/uniprot_2026_02_runlogs

tail -n 100 /data/p252701008/datasets/uniprot_2026_02_runlogs/logs/download_*.log
tail -n 100 /data/p252701008/datasets/uniprot_2026_02_runlogs/logs/error_*.log
```

进度快照包含目标/完成/partial 文件数、目标/已落盘字节、运行时长、10/30/60 分钟速度和 ETA。进度中的“完成”仅指大小已到位且无 sidecar；终态仍以 MD5/release 强校验为准。

## 5. 只读校验

```bash
bash download_uniprot.sh --all --verify-only \
  --local-root /data2/p252701008/genomes/uniprot_2026_02 \
  --run-root /data/p252701008/datasets/uniprot_2026_02_runlogs
```

结果为 `0` 表示全部通过；`20` 表示需要修复。该模式不会移动 payload，也不会创建不存在的 payload 根目录。报告位于 `manifests/verification_*.tsv`，修复清单位于 `plans/repair_plan_*.tsv`。

## 6. 恢复下载

使用与原运行相同的 release、数据选择和两个根目录重新执行即可：

```bash
RUN_ROOT=/data/p252701008/datasets/uniprot_2026_02_runlogs
RUN_TAG="$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "${RUN_ROOT}/nohup"

nohup bash download_uniprot.sh --all \
  --local-root /data2/p252701008/genomes/uniprot_2026_02 \
  --run-root "${RUN_ROOT}" \
  1>"${RUN_ROOT}/nohup/uniprot_2026_02_resume_${RUN_TAG}.log" 2>&1 &
printf '%s\n' "$!" > "${RUN_ROOT}/uniprot_2026_02.pid"
```

脚本会跳过通过校验的文件、续传带 `.aria2` 的 partial，并重下被隔离的无效文件。不要手工移动或修改 `.aria2` sidecar。

## 7. 受控停止

```bash
kill -TERM "$(cat /data/p252701008/datasets/uniprot_2026_02_runlogs/uniprot_2026_02.pid)"
```

预期退出码为 `143`，状态为 `INTERRUPTED`。脚本会停止监控和 aria2 子进程，保留 payload、partial、sidecar 与日志。再次执行同一命令即可恢复。

## 8. 参数表

| 参数 | 含义 |
|---|---|
| `--dataset NAME[,NAME...]` | 选择一个或多个数据组，可重复 |
| `--all` | 选择批准清单的全部 25 个文件 |
| `--list-datasets` | 列出数据组、文件数和压缩大小 |
| `--plan-only` | 离线生成计划 |
| `--verify-only` | 只读强校验 |
| `--status` / `--summary` | 读取最近状态/终态摘要 |
| `--download-attempts N` | 外层下载/修复轮数，默认 3 |
| `--retry-wait SEC` | 外层轮次间隔，默认 60 秒 |
| `--progress-interval SEC` | 进度采样间隔，0 为关闭 |
| `--lock-wait SEC` | 数据目录锁等待时间，0 为立即失败 |
| `--connections N` | aria2 单服务器连接数，范围 1-16 |
| `--max-concurrent N` | aria2 并发文件数 |
| `--split N` | aria2 单文件分片数 |
| `--min-split-size SIZE` | 最小分片大小，范围 `1M`-`1024M` |
| `--aria-max-tries N` | aria2 单轮内部重试次数 |
| `--aria-retry-wait SEC` | aria2 内部重试间隔 |
| `--summary-interval SEC` | aria2 console 汇总间隔 |
| `--min-disk-gb N` | 最低可用磁盘阈值 |
| `--local-root PATH` | payload 根目录 |
| `--run-root PATH` | 日志、状态、计划、报告和 trash 根目录 |
| `--manifest PATH` | 覆盖清单路径；内容仍必须匹配批准 SHA-256 |

## 9. 故障处置

| 错误类 | 默认动作 | 人工检查 |
|---|---|---|
| `RATE_LIMITED` | 等待后重试 | 降低并发，检查服务端限流 |
| `TRANSIENT_NETWORK` | 保留 sidecar 并重试 | DNS、代理、TLS、出口网络 |
| `VALIDATION_FAILED` | 隔离无效完整文件并重试 | 磁盘/传输稳定性、官方 MD5 |
| `REMOTE_PERMANENT` | `NEEDS_REPAIR` | URL 是否下线、release 是否更新 |
| `STORAGE_BLOCKED` | `BLOCKED` | 空间、配额、只读挂载、I/O 错误 |
| `AUTH_CONFIG` | `BLOCKED` | 代理或网关返回的 401/403 |
| `CONFIG_BLOCKED` | `BLOCKED` | 路径、参数、清单、安全门、依赖或锁 |
| `INTERNAL_INVARIANT` | `BLOCKED` | 参数、依赖、脚本日志与故障证据 |

任何失败先看 `reports/latest_summary.md`，再看对应 `repair_plan` 和 `aria2_failure` 日志。不要删除现场文件。
