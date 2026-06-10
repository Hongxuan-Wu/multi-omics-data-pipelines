# SRA metadata 数据下载

本文档只说明 SRA metadata 原始数据从哪里下载、下载到哪里、服务器上当前使用哪些路径。下载后的分析和字段解释见 `sra-metadata数据分析.md`。

## 1. 数据来源

NCBI SRA metadata FTP：

```text
https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/
```

SRA 数据库入口：

```text
https://www.ncbi.nlm.nih.gov/sra/
```

当前项目使用的核心原始数据：

| 数据 | 文件 | 用途 |
|---|---|---|
| SRA XML full metadata | `NCBI_SRA_Metadata_Full_20260516.tar.gz` | RUN/EXPERIMENT/SAMPLE/STUDY XML 全量快照 |
| SRA_Accessions | `SRA_Accessions` / `SRA_Accessions.tab` | 全库 accession 统一索引 TSV |
| SRA datalist | `NCBI_SRA_Datalist_20260516` | SRA 文件列表辅助数据 |

## 2. H100 当前路径

原始 XML full snapshot：

```text
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516.tar.gz
```

SRA_Accessions 原始入口：

```text
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/raw/SRA_Accessions
```

整理后的统一入口：

```text
/data3/m252202014/NCBI_data/SRA
```

## 3. 4090 当前路径

4090 上曾用于 SRA_Accessions Parquet 构建和早期 XML 试验的目录：

```text
/data/shared/SRA
/data/shared/sra_parquet
```

4090 上主要原始文件包括：

```text
/data/shared/SRA/NCBI_SRA_Metadata_Full_20260516
/data/shared/SRA/NCBI_SRA_Metadata_Full_20260516.tar.gz
/data/shared/SRA/NCBI_SRA_Datalist_20260516
/data/shared/SRA/NCBI_SRA_Datalist_20260516.gz
```

## 4. 下载命令

### 4.1 curl

```bash
# 全量 XML metadata
curl -C - -o NCBI_SRA_Metadata_Full_20260516.tar.gz \
  "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/NCBI_SRA_Metadata_Full_20260516.tar.gz"

# 全库 accession 索引
curl -C - -o SRA_Accessions.tab \
  "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/SRA_Accessions.tab"
```

### 4.2 aria2c

```bash
aria2c -x 16 -s 16 -c -o NCBI_SRA_Metadata_Full_20260516.tar.gz \
  "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/NCBI_SRA_Metadata_Full_20260516.tar.gz"

aria2c -x 16 -s 16 -c -o SRA_Accessions.tab \
  "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/SRA_Accessions.tab"
```

## 5. 基础校验命令

```bash
# 查看表头和前几行
head -10 /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions

# 统计行数，减 1 后为数据行数
wc -l /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions

# 查看 XML 目录数量
find /data3/shared/sra/NCBI_SRA_Metadata_Full_20260516 -mindepth 1 -maxdepth 1 -type d | wc -l
```

当前 `SRA_Accessions` 审计结果：

```text
data_lines = 148,211,048
total_lines_including_header = 148,211,049
```

当前 XML full snapshot 目录数：

```text
7,609,455
```

## 6. 下载后的下一步

下载完成后不要直接做生物学筛选，应先构建两个索引：

1. `SRA_Accessions` Parquet 索引：用于状态、可见性、Spots/Bases、BioSample/BioProject 等硬过滤。
2. `SRA XML full streaming v1` 索引：用于实验设计、文库策略、平台、sample attributes、实体关系和 XML 回源验证。

索引构建见：

```text
SRA_Accessions索引构建与使用.md
SRA_XML全量索引构建与使用.md
```
