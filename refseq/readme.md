# RefSeq 数据处理与下载说明

> 维护基线：2026-07-13
>
> 当前结论：RefSeq genomes 快照已完成；生产下载逻辑封版，后续优先执行自检和读取状态，不再直接修改已验证默认参数。

RefSeq 侧提供基因组、物种和菌株层面的标准参照信息，并通过 BioSample、BioProject、TaxID 等字段与 SRA 关联。

## 导航

- [0. 当前状态与入口](#0-当前状态与入口)
- [1. 数据来源](#1-数据来源)
- [2. 原始字段](#2-原始字段)
- [3. 处理目标](#3-处理目标)
- [4. 推荐输出表](#4-推荐输出表)
- [5. 与 SRA 关联的主键优先级](#5-与-sra-关联的主键优先级)
- [6. 新建时间快照时刷新 assembly summary](#6-新建时间快照时刷新-assembly-summary)
- [7. RefSeq genomes API 下载流程](#7-refseq-genomes-api-下载流程)
- [8. 下游建设任务](#8-下游建设任务)

## 0. 当前状态与入口

### 0.1 文件职责

| 文件 | 状态 | 用途 |
|---|---|---|
| `genomes_dir/download_refseq_genomes_api.sh` | **唯一生产入口** | 基于 `assembly_summary_refseq.txt` 和 NCBI Datasets 的全量 assembly 下载、断点续跑与严格校验 |
| `genomes_dir/tests/test_*.sh` | 生产测试 | 锁定 shard、rehydrate、gzip、JSONL、多盘切换和异常 shard 修复行为 |
| `check_refseq.sh` | 维护入口 | 离线执行 Shell/Python 语法、全部 RefSeq 测试和 Git 空白检查 |
| `refseq_release_dir/download_refseq.sh` | 独立归档流程 | 已禁用的 release 235 历史下载实现；与 assembly 级 genomes 数据库不是同一数据集，当前服务器未保留其默认运行目录 |
| `refseq_release_dir/verify_refseq_truly_full.sh` | 可选复核 | 对 release 镜像执行 MD5 与弱校验综合复核 |
| `refseq_release_dir/verify_md5_parallel.py` | 可选复核 | 并行复核 release 中有官方 MD5 的文件 |
| `genomes_dir/download_refseq_genomes_ftp.sh` | 历史备用脚本 | 递归镜像 `genomes/refseq` FTP 树，不用于当前数据库 |
| `resources/*.py` | 历史研究脚本 | 保留早期实验流程和硬编码路径，仅供追溯，不作为生产入口 |

### 0.2 已完成的 genomes 快照

| 项目 | 当前值 |
|---|---|
| Context | `refseq_RefSeq_include_all_gzip_refseq_shards_size_5000_4067231603` |
| Assembly summary | `refseq/resources/assembly_summary_refseq.txt` |
| Assembly summary 行数 | `530,098` |
| Manifest accessions | `530,057` |
| Shards | `107`，每 shard 最多 `5,000` accessions |
| Fetch targets | `3,711,948` |
| 已存在且非空 | `3,711,941` |
| 官方永久不可用 | `7`，全部属于 `GCF_036905835.1` |
| 下载状态 | 所有仍可从 NCBI 获取的目标已下载完毕，无需继续 rehydrate |

严格 `verify` 仍会对这 7 个目标返回非 0，这是预期行为：脚本不会把 NCBI 已下架的数据静默计为完整。下游必须排除 `GCF_036905835.1`，或标记为 `remote_unavailable` / `suppressed`。

### 0.3 维护原则

- 使用当前快照时，不修改 `SHARD_SIZE`、过滤条件、gzip 模式或 context；直接读取现有数据目录。
- 只有建立新的 RefSeq 时间快照时才刷新 assembly summary，并让脚本生成新的 context；新旧 context 不混用。
- 不直接运行历史脚本；当前 assembly 下载统一使用 API 生产入口。
- 任何代码或文档调整后先执行统一自检：

```bash
conda activate refseq_tools
bash refseq/check_refseq.sh
```

RefSeq release FTP 全量下载与校验流程见 `refseq_release_dir/refseq_release_download.md`。

## 1. 数据来源

当前生产脚本使用以下本地快照，文件本身由 `refseq/.gitignore` 排除，不提交 Git：

```text
source_url: https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt
local_path: /data/p252701008/projects/multi-omics-data-pipelines/refseq/resources/assembly_summary_refseq.txt
local_mtime: 2026-07-08 20:13:36 +08:00
size_bytes: 235,955,682
line_count: 530,098
sha256: 5bcc213e4e492c337c0768d4d6d3d51d3df0139bf0e449ac24d1560fd5dc3056
assembly_summary_context_token: 2073201968_235955682
pipeline_context_id: 4067231603
```

旧 H100 路径 `/data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt` 不是当前生产输入，不要用它覆盖已完成 context 的来源表。

该文件第一行为说明注释，第二行为字段表头，后续为 RefSeq assembly 记录。

## 2. 原始字段

RefSeq 侧至少需要保留：

```text
assembly_accession
bioproject
biosample
wgs_master
refseq_category
taxid
species_taxid
organism_name
infraspecific_name
isolate
version_status
assembly_level
release_type
genome_rep
seq_rel_date
asm_name
asm_submitter
gbrs_paired_asm
paired_asm_comp
ftp_path
excluded_from_refseq
relation_to_type_material
asm_not_live_date
assembly_type
group
genome_size
genome_size_ungapped
gc_percent
replicon_count
scaffold_count
contig_count
annotation_provider
annotation_name
annotation_date
total_gene_count
protein_coding_gene_count
non_coding_gene_count
pubmed_id
```

## 3. 处理目标

处理后的 RefSeq 表应满足：

- 每个 `assembly_accession` 一行。
- `biosample`、`bioproject`、`taxid`、`species_taxid` 标准化为空值或字符串，不混用占位符。
- 保留 `version_status`，默认优先使用 `latest`。
- 保留 `assembly_level`，后续可优先使用 Complete Genome / Chromosome。
- 保留 `ftp_path`，用于下载 genome fasta、gff、gbff 等文件。

## 4. 推荐输出表

```text
refseq_assembly_core.parquet
```

建议字段：

```text
assembly_accession
biosample
bioproject
taxid
species_taxid
organism_name
strain_or_isolate
refseq_category
version_status
assembly_level
release_type
genome_rep
seq_rel_date
asm_name
asm_submitter
ftp_path
```

## 5. 与 SRA 关联的主键优先级

优先级：

1. `BioSample` / `biosample`
2. `BioProject` / `bioproject`
3. `taxid` / `species_taxid`

原则：

- BioSample 是样本级主键，优先级最高。
- BioProject 是项目级主键，只能辅助，不能单独作为精确样本 join。
- TaxID 是物种或分类层级，只适合扩大候选集或做背景过滤，不能证明同一样本。

## 6. 新建时间快照时刷新 assembly summary

当前数据库已经完成，不需要刷新来源表。只有明确建立新时间快照时才执行本节；下载新文件后先校验，再把旧文件移入 `trash`，避免覆盖后无法追溯。

```bash
set -Eeuo pipefail

cd /data/p252701008/projects/multi-omics-data-pipelines

snapshot_id="$(date -u '+%Y%m%dT%H%M%SZ')"
current_file="refseq/resources/assembly_summary_refseq.txt"
new_file="${current_file}.partial.${snapshot_id}"
archive_file="refseq/resources/trash/assembly_summary_refseq.${snapshot_id}.txt"

curl -L --fail --retry 5 --retry-delay 10 \
  -o "${new_file}" \
  https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt

[[ -s "${new_file}" ]]
awk -F '\t' '
  NR == 2 {
    if ($1 != "#assembly_accession" || NF < 38) exit 10
    for (i = 1; i <= NF; i++) {
      if ($i == "ftp_path") has_ftp_path = 1
    }
    if (!has_ftp_path) exit 11
  }
  NR > 2 && ($1 !~ /^GCF_[0-9]+\.[0-9]+$/ || NF < 38) { exit 12 }
  END { if (NR < 100000) exit 13 }
' "${new_file}"
printf 'assembly summary validation passed\n'

wc -l "${new_file}"
sha256sum "${new_file}"
cksum "${new_file}"
head -n 2 "${new_file}"

mkdir -p refseq/resources/trash
if [[ -f "${current_file}" ]]; then
  ln -- "${current_file}" "${archive_file}"
fi
mv -- "${new_file}" "${current_file}"
```

校验会检查表头、`ftp_path` 字段、全部 accession 格式、每行最低字段数和最低记录数；任一条件失败都会在替换前退出。旧文件先通过同文件系统硬链接保留到 `trash`，随后同目录 `mv` 原子替换当前路径。

来源表内容变化会生成新的 context。不要用新来源表配合旧 context，也不要覆盖已完成 context 下的 manifest、shard 或 fetch 文件。

## 7. RefSeq genomes API 下载流程

脚本：

```text
refseq/genomes_dir/download_refseq_genomes_api.sh
```

当前流程使用 NCBI Datasets CLI 的大规模下载模式：

```text
manifest/shard -> dehydrated links -> unpack -> merge fetch.txt -> rehydrate -> verify
```

关键运行目录：

```text
default data root: /data1/p252701008/refseq_genomes
run root:          /data/p252701008/datasets/refseq_genomes_runlogs
nohup log dir:     /data/p252701008/datasets/refseq_genomes_runlogs/logs
```

真实数据存储盘候选顺序：

| 顺序 | 数据根目录 |
|------|------------|
| 1 | `/data1/p252701008/refseq_genomes` |
| 2 | `/data2/p252701008/refseq_genomes` |
| 3 | `/data4/p252701008/refseq_genomes` |
| 4 | `/data5/p252701008/refseq_genomes` |
| 5 | `/data3/p252701008/refseq_genomes` |

脚本会尝试创建每个候选盘下的 `p252701008/refseq_genomes`。`rehydrate` 阶段按候选顺序选择剩余空间不低于 200 GB 的盘；运行中若当前盘低于 200 GB，会停止当前 `datasets rehydrate`，重算未完成目标后切到下一个可用候选盘继续。

当前统一 `fetch.txt` 路径：

```text
/data1/p252701008/refseq_genomes/contexts/<context>/merged_refseq_dataset/ncbi_dataset/fetch.txt
```

真实数据下载目录：

```text
/dataN/p252701008/refseq_genomes/contexts/<context>/rehydrate_refseq_dataset/ncbi_dataset/data
```

其中 `/dataN` 是上述候选盘之一。默认 `REHYDRATE_GZIP=1`，因此序列和注释文件通常以 `.gz` 结尾；`sequence_report.jsonl` 等 JSONL 元数据保持未压缩格式。context 名称也会带 `gzip`，避免和未压缩下载结果混写。

### 7.1 环境与 API key

NCBI Datasets CLI 使用独立环境。官方 conda 包同时提供 `datasets` 和 `dataformat`：

```bash
conda create -n ncbi_datasets
conda activate ncbi_datasets
conda install -c conda-forge ncbi-datasets-cli
```

当前 CLI 路径：

```text
/home/p252701008/.conda/envs/ncbi_datasets
```

当前 `ncbi_datasets` 环境只包含 CLI 二进制，不包含 Python。统一自检和 `verify_md5_parallel.py` 使用独立的非 base Python 环境：

```bash
conda create -n refseq_tools python=3.11
conda activate refseq_tools
```

上述自检和并行 MD5 脚本只依赖 Python 标准库，无需额外安装 Python 包。

NCBI API key 放在本地环境文件，不提交 Git：

```text
.codex/.env
```

文件内容格式：

```bash
NCBI_API_KEY=<your_ncbi_api_key>
```

脚本日志中看到下面两行，表示 API key 和并发配置生效：

```text
rehydrate max workers=30; progress_interval_seconds=60; gzip=1; storage_min_free_gb=200
api key mode: env_exported=yes
```

### 7.2 Action 与运行命令

当前 context 已下载结束，不应再次启动 `all` 或 `rehydrate`。以下命令保留给新快照或真实缺失修复。

| Action | 作用 | 常用场景 |
|---|---|---|
| `all` | manifest 到 verify 的完整流程 | 新 assembly summary 快照首次运行 |
| `manifest` | 重建 accession 和 shard 清单 | 新来源表或新筛选配置 |
| `download-links` | 下载 dehydrated shard 包 | 链接包缺失 |
| `unpack-links` | 解包 shard fetch | ZIP 已有但 fetch 未解包 |
| `repair-shards` | 补跑 `REPAIR_SHARDS` 指定 shard 并重建 fetch | 少量 shard 异常 |
| `merge-fetch` | 合并并校验所有 shard fetch | shard 已完整但统一 fetch 需要重建 |
| `rehydrate` | 续传真实数据并自动切换候选盘 | 存在可获取的下载目标缺失 |
| `verify` | accession、目标存在性、gzip 和可用 MD5 校验 | 独立复核；当前快照会因 7 个 suppressed 目标返回非 0 |
| `summary` | 根据现有产物生成汇总 | 只查看状态，不下载 |

启动前先确认没有旧下载进程：

```bash
pgrep -af '[d]ownload_refseq_genomes_api.sh|datasets [r]ehydrate' || true
```

新快照完整运行：

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines
mkdir -p /data/p252701008/datasets/refseq_genomes_runlogs/logs

nohup bash -lc 'set -a && source .codex/.env && set +a && export PATH="/home/p252701008/.conda/envs/ncbi_datasets/bin:$PATH" && bash refseq/genomes_dir/download_refseq_genomes_api.sh all' \
  > /data/p252701008/datasets/refseq_genomes_runlogs/logs/nohup_refseq_genomes_all.log 2>&1 &
```

只续传 rehydrate：

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines
mkdir -p /data/p252701008/datasets/refseq_genomes_runlogs/logs

nohup bash -lc 'set -a && source .codex/.env && set +a && export PATH="/home/p252701008/.conda/envs/ncbi_datasets/bin:$PATH" && bash refseq/genomes_dir/download_refseq_genomes_api.sh rehydrate' \
  > /data/p252701008/datasets/refseq_genomes_runlogs/logs/nohup_refseq_genomes_rehydrate.log 2>&1 &
```

只生成当前已完成 context 的 summary：

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines

PIPELINE_CONTEXT_OVERRIDE='refseq_RefSeq_include_all_gzip_refseq_shards_size_5000_4067231603' \
  bash refseq/genomes_dir/download_refseq_genomes_api.sh summary
```

当前脚本默认：

```text
STORAGE_DISK_CANDIDATES=(/data1 /data2 /data4 /data5 /data3)
STORAGE_MIN_FREE_GB=200
SHARD_SIZE=5000
INCLUDE_FILES=all
FILTER_ASSEMBLY_LEVELS=all
REHYDRATE_MAX_WORKERS=30
REHYDRATE_GZIP=1
REHYDRATE_PROGRESS_INTERVAL_SECONDS=60
REHYDRATE_MAX_RETRIES=3
RETRY_SLEEP_SECONDS=30
FORCE_MERGE_FETCH=0
```

### 7.3 查看进度

主日志：

```bash
tail -f /data/p252701008/datasets/refseq_genomes_runlogs/logs/nohup_refseq_genomes_rehydrate.log
```

脚本会每 60 秒写一行进度：

```text
rehydrate progress: files=<done>/<total> (<percent>%), accession_dirs=<n>, data_size=<size>, data_dir=<path>
```

手动查看文件数和体积：

```bash
context="替换成实际 context 名称"
for disk in /data1 /data2 /data4 /data5 /data3; do
  data_dir="${disk}/p252701008/refseq_genomes/contexts/${context}/rehydrate_refseq_dataset/ncbi_dataset/data"
  [ -d "${data_dir}" ] || continue
  printf '%s\t' "${data_dir}"
  find "${data_dir}" -type f | wc -l
  du -sh "${data_dir}"
done
```

内部 `datasets rehydrate` 日志：

```text
/data/p252701008/datasets/refseq_genomes_runlogs/logs/<context>/datasets_rehydrate_<RUN_ID>.log
```

`rehydrate --list` 预检摘要日志：

```text
/data/p252701008/datasets/refseq_genomes_runlogs/logs/<context>/datasets_rehydrate_list_<RUN_ID>.log
```

该日志只保留命令、退出状态、`stdout_lines` 和 stderr 路径；完整 `--list` 明细不会落盘。

状态和 summary：

```text
/data/p252701008/datasets/refseq_genomes_runlogs/status/<context>/state_<RUN_ID>.tsv
/data/p252701008/datasets/refseq_genomes_runlogs/status/<context>/summary_<RUN_ID>.md
```

### 7.4 常见注意事项

- `--no-progressbar` 只关闭 `datasets` 终端进度条，不影响下载速度、并发数或下载内容。
- 后台运行时保留 `--no-progressbar`，避免 nohup 日志被进度条控制字符污染。
- `REHYDRATE_LIST_BEFORE_DOWNLOAD=1` 会保留下载前预检，但只记录 `--list` 行数摘要，不保存数百万行完整清单。
- `REHYDRATE_GZIP=1` 会把序列和注释文件按 gzip 压缩格式落盘，目标校验会检查 `.gz` 文件存在且执行 `gzip -t`；`sequence_report.jsonl` 等 JSONL 元数据保持未压缩格式，只检查存在性和非空。
- gzip 模式下官方 `fetch.txt` 的 MD5 通常不再直接对应压缩后的本地文件，脚本会跳过直接 MD5 计算，保留目标存在性、文件类别和 gzip 完整性校验。
- 进度看主日志里的 `rehydrate progress` 行，或手动看文件数和数据目录体积。
- 修改 `REHYDRATE_MAX_WORKERS`、`NCBI_API_KEY` 后，已经运行中的进程不会自动继承，需要停止后重新启动。
- `rehydrate` 会按 `STORAGE_DISK_CANDIDATES` 的顺序遍历候选盘。`REHYDRATE_MAX_RETRIES=3` 表示每个空间达标候选盘内最多重试 3 次，不限制候选盘遍历数量。
- 停止下载时，先停止 `datasets rehydrate` 子进程，再停止外层 `download_refseq_genomes_api.sh rehydrate` 进程。

### 7.5 已知的 NCBI suppressed accession

2026-07-13 全量复检确认 `GCF_036905835.1` 已被 NCBI 标记为 `suppressed`，原因是提交者要求移除该记录。NCBI 当前返回的关联状态时间为 `2026-07-08T12:12:07.134Z`（北京时间 2026-07-08 20:12:07）。

本地 `assembly_summary_refseq.txt` 快照中原本存在该 accession，且当时仍记录为：

```text
version_status=latest
ftp_path=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/036/905/835/GCF_036905835.1_ASM3690583v1/
excluded_from_refseq=na
asm_not_live_date=na
```

因此该 accession 进入 manifest 不是本地筛选错误，而是 NCBI 状态在快照生成后或各系统状态同步期间发生了变化。当前 7 个无法获取的目标全部属于该 accession：

- `sequence_report.jsonl` 返回空内容。
- genome、CDS、protein、GBFF、GFF3 和 GTF 共 6 个数据目标返回永久 `404 Not Found`。

本次快照的最终存在性结果为 `3,711,941 / 3,711,948` 个目标存在且非空；唯一异常 accession 即 `GCF_036905835.1`。下游调用时必须遵守以下规则：

- 不要将 `GCF_036905835.1` 当作完整可用的 RefSeq assembly；组装级数据库、矩阵和统计分母应排除该 accession，或明确标记为 `remote_unavailable` / `suppressed`。
- 对这 7 个目标重复运行 `rehydrate` 或切换数据盘无法解决；其他 accession 的缺失仍应视为真实完整性错误。
- 脚本目前保留严格行为：`verify` 会报告这 7 个目标并返回非 0，不会静默把官方不可用数据当作校验通过。
- 下次建立新快照时，先刷新官方 `assembly_summary_refseq.txt`，再用新的 context 重建 manifest、shard 和 fetch，避免混用旧链接。

完整缺失清单位于：

```text
/data/p252701008/datasets/refseq_genomes_runlogs/status/refseq_RefSeq_include_all_gzip_refseq_shards_size_5000_4067231603/missing_download_targets.tsv
```

### 7.6 下游读取约定

- 以合并后的 `fetch.txt` 第三列作为目标相对路径，不根据文件名猜测 accession 或文件类型。
- gzip 模式下，序列和注释目标在本地追加 `.gz`；`.jsonl` 元数据保持原文件名，不追加 `.gz`。
- 数据可能分布在五个候选盘，读取时按 `/data1`、`/data2`、`/data4`、`/data5`、`/data3` 顺序查找相同 context 下的相对路径。
- 只接受存在且非空的文件；`.gz` 文件在首次纳入下游索引前执行 `gzip -t`。
- `GCF_036905835.1` 必须在 assembly 级索引、训练样本和统计分母中排除或显式标记。
- 不把 `missing_download_targets.tsv` 中已确认的 7 个 suppressed 目标扩展成其他 accession 的通用豁免。

### 7.7 统一自检

代码或文档变更后执行：

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines
conda activate refseq_tools
bash refseq/check_refseq.sh
```

如需使用另一个非 base Conda 环境，可显式指定该环境中的 Python：

```bash
REFSEQ_PYTHON=/path/to/conda/env/bin/python bash refseq/check_refseq.sh
```

自检只读取仓库文件并在 `/tmp` 中运行测试夹具，不访问 NCBI、不启动下载、不修改现有数据库。

## 8. 下游建设任务

以下项目不属于下载脚本未完成项。当前 RefSeq genomes 下载流程已经封版；这些是后续数据库建模和 SRA 关联工作：

- 写 `build_refseq_core.py` 或等价脚本。
- 生成 `refseq_assembly_core.parquet`。
- 用 BioSample 与 SRA XML `sample_core.parquet` 做首轮关联验证。
