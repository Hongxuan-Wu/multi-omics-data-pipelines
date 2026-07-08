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
data root: /data3/p252701008/refseq_genomes
run root:  /data3/p252701008/refseq_genomes_runlogs
logs:      refseq/genomes_dir/logs
```

当前统一 `fetch.txt` 路径：

```text
/data3/p252701008/refseq_genomes/contexts/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/merged_refseq_dataset/ncbi_dataset/fetch.txt
```

真实数据下载目录：

```text
/data3/p252701008/refseq_genomes/contexts/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/merged_refseq_dataset/ncbi_dataset/data
```

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
rehydrate max workers=30; progress_interval_seconds=60
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

nohup bash -lc 'set -a && source .codex/.env && set +a && export PATH="/home/p252701008/.conda/envs/ncbi_datasets/bin:$PATH" && bash refseq/genomes_dir/download_refseq_genomes_api.sh rehydrate' \
  > refseq/genomes_dir/logs/nohup_refseq_genomes_rehydrate.log 2>&1 &
```

当前脚本默认：

```text
REHYDRATE_MAX_WORKERS=30
REHYDRATE_PROGRESS_INTERVAL_SECONDS=60
REHYDRATE_MAX_RETRIES=3
RETRY_SLEEP_SECONDS=30
FORCE_MERGE_FETCH=0
```

### 7.3 查看进度

主日志：

```bash
tail -f refseq/genomes_dir/logs/nohup_refseq_genomes_rehydrate.log
```

脚本会每 60 秒写一行进度：

```text
rehydrate progress: files=<done>/<total> (<percent>%), accession_dirs=<n>, data_size=<size>, data_dir=<path>
```

手动查看文件数和体积：

```bash
find /data3/p252701008/refseq_genomes/contexts/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/merged_refseq_dataset/ncbi_dataset/data -type f | wc -l
du -sh /data3/p252701008/refseq_genomes/contexts/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/merged_refseq_dataset/ncbi_dataset/data
```

内部 `datasets rehydrate` 日志：

```text
/data3/p252701008/refseq_genomes_runlogs/logs/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/datasets_rehydrate_<RUN_ID>.log
```

`rehydrate --list` 预检摘要日志：

```text
/data3/p252701008/refseq_genomes_runlogs/logs/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/datasets_rehydrate_list_<RUN_ID>.log
```

该日志只保留命令、退出状态、`stdout_lines` 和 stderr 路径；完整 `--list` 明细不会落盘。

状态和 summary：

```text
/data3/p252701008/refseq_genomes_runlogs/status/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/state_<RUN_ID>.tsv
/data3/p252701008/refseq_genomes_runlogs/status/refseq_RefSeq_include_all_refseq_shards_size_1000_268328763/summary_<RUN_ID>.md
```

### 7.4 常见注意事项

- `--no-progressbar` 只关闭 `datasets` 终端进度条，不影响下载速度、并发数或下载内容。
- 后台运行时保留 `--no-progressbar`，避免 nohup 日志被进度条控制字符污染。
- `REHYDRATE_LIST_BEFORE_DOWNLOAD=1` 会保留下载前预检，但只记录 `--list` 行数摘要，不保存数百万行完整清单。
- 进度看主日志里的 `rehydrate progress` 行，或手动看文件数和数据目录体积。
- 修改 `REHYDRATE_MAX_WORKERS`、`NCBI_API_KEY` 后，已经运行中的进程不会自动继承，需要停止后重新启动。
- 如果 `datasets rehydrate` 失败，脚本会按 `REHYDRATE_MAX_RETRIES=3` 自动重试。
- 停止下载时，先停止 `datasets rehydrate` 子进程，再停止外层 `download_refseq_genomes_api.sh rehydrate` 进程。

## 8. 后续需要补齐

- 写 `build_refseq_core.py` 或等价脚本。
- 生成 `refseq_assembly_core.parquet`。
- 用 BioSample 与 SRA XML `sample_core.parquet` 做首轮关联验证。
