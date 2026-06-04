# transcriptomics-pipelines 通用处理流程

## SRA Metadata 下载

[SRA数据库官网](https://www.ncbi.nlm.nih.gov/sra/?term=)

[数据来源 - https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/](https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/)

### 方法一

```bash
# 1. 全量元数据包 (~15GB)
curl -C - -o NCBI_SRA_Metadata_Full_20260516.tar.gz "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/NCBI_SRA_Metadata_Full_20260516.tar.gz"

# 2. 全库登录号索引 (~30GB)
curl -C - -o SRA_Accessions.tab "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/SRA_Accessions.tab"

# 3. 最新每日元数据包 (~6.5GB)
curl -C - -o NCBI_SRA_Metadata_20260528.tar.gz "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/NCBI_SRA_Metadata_20260528.tar.gz"
```

### 方法二

[【教程】Linux使用aria2c多线程满速下载](https://blog.csdn.net/sxf1061700625/article/details/136158389)

```bash
aria2c -x 16 -s 16 -c -o NCBI_SRA_Metadata_Full_20260516.tar.gz "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/NCBI_SRA_Metadata_Full_20260516.tar.gz"

aria2c -x 16 -s 16 -c -o SRA_Accessions.tab "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/SRA_Accessions.tab"

aria2c -x 16 -s 16 -c -o NCBI_SRA_Metadata_20260528.tar.gz "https://ftp.ncbi.nlm.nih.gov/sra/reports/Metadata/NCBI_SRA_Metadata_20260528.tar.gz"
```

## 常用命令

```bash
# 看头10行（含表头）
head -10 "/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_20260516/SRA_Accessions"

# 统计总条目数（减1行表头）
wc -l "/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_20260516/SRA_Accessions"
```
>>>>>>> main
