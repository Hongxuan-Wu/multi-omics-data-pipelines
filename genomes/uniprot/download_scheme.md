# UniProt 2026_02 下载方案

## 1. 目标与范围

| 项 | 结论 |
|---|---|
| Release | `2026_02` |
| 官方入口 | `https://ftp.uniprot.org/pub/databases/uniprot/current_release/` |
| 合同 | `download_file_manifest_2026_02.tsv` 中固定的 25 个目标 |
| 默认数据目录 | `/data2/p252701008/genomes/uniprot_2026_02` |
| 默认运行目录 | `/data/p252701008/datasets/uniprot_2026_02_runlogs` |
| 全量比对库 | Swiss-Prot 与 TrEMBL 的 FASTA 分开下载，二者共同构成 UniProtKB complete |
| 注释 | Swiss-Prot 与 TrEMBL DAT；另带 README 和 `RELEASE.metalink` |
| 统一建模 | UniRef50、UniRef90、UniRef100 FASTA |
| 多组学对齐 | `idmapping.dat.gz`、`sec_ac.txt`、Reference Proteomes tar/README/STATS |
| 总压缩体积 | 618,535,806,550 bytes（576.056 GiB） |

## 2. 下载器

`download_uniprot.sh` 是 UniProt 通用下载器；无参数时默认选择 UniRef50。

| 调用 | 选择 |
|---|---|
| 无参数 | `uniref50` |
| `--dataset swissprot` | Swiss-Prot FASTA、varsplic FASTA、DAT 与共享 metadata，共 5 项 |
| `--dataset trembl` | TrEMBL FASTA、DAT 与共享 metadata，共 4 项 |
| `--dataset uniprotkb_complete` | Swiss-Prot/TrEMBL FASTA、DAT、README、metalink |
| `--dataset uniprotkb` | 上述文件加 `sec_ac.txt` 和 docs metalink |
| `--dataset uniref` | UniRef50/90/100 |
| `--dataset multiomics` | secondary accession、idmapping 和 Reference Proteomes，共 9 项 |
| `--dataset A,B` | 任意组合 |
| `--all` | 全部 25 个目标 |
| `--plan-only` | 仅生成计划，不访问网络、不启动 aria2 |
| `--verify-only` | 只读强校验；不创建或移动 payload |
| `--status` | 输出最近一次运行的状态历史与最新进度 |
| `--summary` | 输出最近一次运行的终态摘要 |

示例：

```bash
# 默认 UniRef50
./download_uniprot.sh

# 先下载高可信 Swiss-Prot，后续再下载 TrEMBL
./download_uniprot.sh --dataset swissprot
./download_uniprot.sh --dataset trembl

# UniProtKB complete、secondary accession 与跨库映射
./download_uniprot.sh \
  --dataset uniprotkb,idmapping

# 先审阅全量计划
./download_uniprot.sh --all --plan-only

# 下载全部目标
./download_uniprot.sh --all

# 只读复核全部目标
./download_uniprot.sh --all --verify-only

# 查看最近一次运行
./download_uniprot.sh --status
./download_uniprot.sh --summary
```

也可通过环境变量配置：

```bash
DOWNLOAD_DATASETS=uniref50,uniref90 \
LOCAL_ROOT=/data2/p252701008/genomes/uniprot_2026_02 \
RUN_ROOT=/data/p252701008/datasets/uniprot_2026_02_runlogs \
nohup bash download_uniprot.sh \
  1>uniprot_2026_02.log 2>&1 &
```

## 3. 执行与校验

1. 在创建目录前规范化路径，拒绝 `/`、相同根目录、嵌套根目录和不可写父目录。
2. 校验本地静态 manifest 的版本、25 文件合同、路径、大小、MD5、URL、数据组和批准 SHA-256。
3. 解析选择项并生成 TSV 下载计划，同时保存 manifest 快照。
4. `--plan-only` 到此结束，不创建 payload 根目录、不访问网络。
5. 下载模式按 `LOCAL_ROOT` 获取独占 flock，防止不同 `RUN_ROOT` 绕过并发保护。
6. 下载前读取所有所选 `RELEASE.metalink`，检查版本和字节数未漂移。
7. 对已验证文件按 MD5 或大小跳过；aria2 使用断点续传、固定输出路径和官方 MD5。
8. 每轮传输后重新核验磁盘实际状态：静态文件检查大小和 MD5，metalink 检查大小和 release version。
9. 失败时保留带 `.aria2` 的 partial；无 sidecar 的无效完整文件移入 `trash`，并按文件生成修复计划。
10. 默认最多执行 3 轮“传输 -> 强校验 -> 最小粒度修复”，并按错误类决定重试、`NEEDS_REPAIR` 或 `BLOCKED`。
11. 状态、进度、计划、aria2 分轮日志、manifest 快照、校验报告和终态摘要全部保存在 `RUN_ROOT`。

远端 release 检查、下载后复核和已验证文件跳过是强制安全门；将 `CHECK_REMOTE_RELEASE`、`VERIFY_AFTER_DOWNLOAD` 或 `SKIP_VERIFIED_FILES` 设为 `0` 会以 `BLOCKED`（退出码 30）终止，不允许降级下载。

`current_release` 不是永久归档 URL。远端版本不再是 `2026_02` 时，脚本会停止；应先更新 release、重新生成清单并人工审核，不能静默下载新版本。

完整状态、错误类、退出码和证据目录见 `download_contract.md`；服务器运行与恢复命令见 `runbook.md`；设计取舍见 `decisions.md`。

## 4. 来源

- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/>
- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/idmapping/>
- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/reference_proteomes/>
- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/>
