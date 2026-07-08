# RefSeq 数据处理说明

RefSeq 侧的目标是提供基因组、物种、菌株层面的标准参照信息，并通过 BioSample、BioProject、TaxID 等字段与 SRA 关联。

Release 目录全量下载与校验流程见：

- `refseq_release_dir/refseq_release_download.md`

NCBI Datasets CLI 工具用于 `genomes_dir/download_refseq_genomes_api.sh` 流程。官方 conda 包同时提供 `datasets` 和 `dataformat` 两个命令。

安装方式：

```bash
conda create -n ncbi_datasets
conda activate ncbi_datasets
conda install -c conda-forge ncbi-datasets-cli
```

## 1. 数据来源

当前已经固定下载的 RefSeq assembly summary：

```text
URL: https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt
H100: /data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
```

下载校验：

```text
downloaded_at: 2026-06-09 20:50 +08:00
file_size: 223M
line_count: 523,151
sha256: f089a1e4e895212a27e310a48e943ca6911a5a3d9e9b8ab6cb44815064096808
```

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

## 6. 下载与校验命令

H100 下载命令：

```bash
mkdir -p /data3/m252202014/NCBI_data/RefSeq/raw
curl -L --fail --retry 3 \
  -o /data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt \
  https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt
```

校验：

```bash
wc -l /data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
sha256sum /data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
head -n 2 /data3/m252202014/NCBI_data/RefSeq/raw/assembly_summary_refseq.txt
```

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

其中 `/dataN` 是上述候选盘之一。默认 `REHYDRATE_GZIP=1`，因此真实文件通常以 `.gz` 结尾；context 名称也会带 `gzip`，避免和未压缩下载结果混写。

### 7.1 环境与 API key

`datasets` 命令使用 conda 环境：

```text
/home/p252701008/.conda/envs/ncbi_datasets
```

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

### 7.2 启动 rehydrate 下载

启动前先确认没有旧下载进程：

```bash
ps -ef | grep -E 'download_refseq_genomes_api.sh rehydrate|datasets rehydrate' | grep -v grep
```

推荐 nohup 启动命令：

```bash
cd /data/p252701008/projects/multi-omics-data-pipelines
mkdir -p /data/p252701008/datasets/refseq_genomes_runlogs/logs

nohup bash -lc 'set -a && source .codex/.env && set +a && export PATH="/home/p252701008/.conda/envs/ncbi_datasets/bin:$PATH" && bash refseq/genomes_dir/download_refseq_genomes_api.sh rehydrate' \
  > /data/p252701008/datasets/refseq_genomes_runlogs/logs/nohup_refseq_genomes_rehydrate.log 2>&1 &
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
- `REHYDRATE_GZIP=1` 会把真实数据按 gzip 压缩格式落盘，目标校验会检查 `.gz` 文件存在且执行 `gzip -t`。
- gzip 模式下官方 `fetch.txt` 的 MD5 通常不再直接对应压缩后的本地文件，脚本会跳过直接 MD5 计算，保留目标存在性、文件类别和 gzip 完整性校验。
- 进度看主日志里的 `rehydrate progress` 行，或手动看文件数和数据目录体积。
- 修改 `REHYDRATE_MAX_WORKERS`、`NCBI_API_KEY` 后，已经运行中的进程不会自动继承，需要停止后重新启动。
- `rehydrate` 会按 `STORAGE_DISK_CANDIDATES` 的顺序遍历候选盘。`REHYDRATE_MAX_RETRIES=3` 表示每个空间达标候选盘内最多重试 3 次，不限制候选盘遍历数量。
- 停止下载时，先停止 `datasets rehydrate` 子进程，再停止外层 `download_refseq_genomes_api.sh rehydrate` 进程。

## 8. 后续需要补齐

- 写 `build_refseq_core.py` 或等价脚本。
- 生成 `refseq_assembly_core.parquet`。
- 用 BioSample 与 SRA XML `sample_core.parquet` 做首轮关联验证。
