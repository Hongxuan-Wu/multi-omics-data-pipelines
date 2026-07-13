# UniProt 2026_02 下载方案

## 1. 目标与范围

| 项 | 结论 |
|---|---|
| Release | `2026_02` |
| 官方入口 | `https://ftp.uniprot.org/pub/databases/uniprot/current_release/` |
| 合同 | `download_file_manifest_2026_02.tsv` 中固定的 25 个目标 |
| 全量比对库 | Swiss-Prot 与 TrEMBL 的 FASTA 分开下载，二者共同构成 UniProtKB complete |
| 注释 | Swiss-Prot 与 TrEMBL DAT；另带 README 和 `RELEASE.metalink` |
| 统一建模 | UniRef50、UniRef90、UniRef100 FASTA |
| 多组学对齐 | `idmapping.dat.gz`、`sec_ac.txt`、Reference Proteomes tar/README/STATS |
| 总压缩体积 | 618,535,806,550 bytes（576.056 GiB） |

## 2. 下载器

脚本名 `download_uniprot_uniref50.sh` 为兼容既有调用而保留，内部已经是 UniProt 通用下载器。

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

示例：

```bash
# 默认 UniRef50
./download_uniprot_uniref50.sh

# 先下载高可信 Swiss-Prot，后续再下载 TrEMBL
./download_uniprot_uniref50.sh --dataset swissprot
./download_uniprot_uniref50.sh --dataset trembl

# UniProtKB complete、secondary accession 与跨库映射
./download_uniprot_uniref50.sh \
  --dataset uniprotkb,idmapping

# 先审阅全量计划
./download_uniprot_uniref50.sh --all --plan-only

# 下载全部目标
./download_uniprot_uniref50.sh --all
```

也可通过环境变量配置：

```bash
DOWNLOAD_DATASETS=uniref50,uniref90 \
LOCAL_ROOT=/data3/p252701008/genomes/uniprot_2026_02 \
RUN_ROOT=/data3/p252701008/genomes/uniprot_2026_02_runlogs \
nohup bash download_uniprot_uniref50.sh \
  1>uniprot_2026_02.log 2>&1 &
```

## 3. 执行与校验

1. 校验本地静态 manifest 的版本、25 文件合同、路径、大小、MD5、URL 和数据组。
2. 解析选择项并生成 TSV 下载计划，同时保存 manifest 快照。
3. 非 `--plan-only` 模式下，先下载所有所选 `RELEASE.metalink`，检查版本和字节数未漂移。
4. 对已存在文件按 MD5 或大小跳过；不匹配文件移入运行目录的 `trash`。
5. aria2 使用断点续传、固定输出路径和官方 MD5。
6. 下载后再次检查字节数；静态文件检查 MD5，metalink 检查 release version。
7. 下载计划、aria2 输入、日志、manifest 快照和校验报告全部保存在 `RUN_ROOT`。
8. aria2 失败时保留带 `.aria2` 的 partial；无 sidecar 的已落盘文件立即复核，不合格文件移入 `trash`。

远端 release 检查和下载后复核是强制安全门；将 `CHECK_REMOTE_RELEASE` 或 `VERIFY_AFTER_DOWNLOAD` 设为 `0` 会直接终止，不允许降级下载。

`current_release` 不是永久归档 URL。远端版本不再是 `2026_02` 时，脚本会停止；应先更新 release、重新生成清单并人工审核，不能静默下载新版本。

## 4. 来源

- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/>
- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/idmapping/>
- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/reference_proteomes/>
- <https://ftp.uniprot.org/pub/databases/uniprot/current_release/uniref/>
