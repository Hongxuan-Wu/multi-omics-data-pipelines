# RefSeq 数据处理说明

RefSeq 侧的目标是提供基因组、物种、菌株层面的标准参照信息，并通过 BioSample、BioProject、TaxID 等字段与 SRA 关联。

Release 目录全量下载与校验流程见：

- `refseq_release_dir/refseq_release_download.md`

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

## 7. 后续需要补齐

- 写 `build_refseq_core.py` 或等价脚本。
- 生成 `refseq_assembly_core.parquet`。
- 用 BioSample 与 SRA XML `sample_core.parquet` 做首轮关联验证。
