# SRA metadata 数据包预处理

本文件保留为 SRA metadata 预处理入口说明。当前正式预处理主线已经拆分到以下两个文档：

```text
sra-metadata/SRA_Accessions索引构建与使用.md
sra-metadata/SRA_XML全量索引构建与使用.md
```

## SRA_Accessions 预处理

输入：

```text
SRA_Accessions
```

处理：

```text
DuckDB strict read_csv
-> 按 Type 分区写 Parquet
-> 生成 live/public/nonzero RUN 派生表
-> 写 QC 表和 conversion manifest
```

输出：

```text
/data/shared/sra_parquet
/data3/m252202014/NCBI_data/SRA/SRA_Accessions/index/sra_parquet
```

## SRA XML 预处理

输入：

```text
/data3/shared/sra/NCBI_SRA_Metadata_Full_20260516
```

处理：

```text
manifest
-> chunk parser
-> chunk_status
-> finalizer compact
-> global entity/relation rebuild
-> schema validation
-> XML back-check
```

输出：

```text
/data3/m252202014/SRA/outputs/sra_xml_index/full_runs/20260516_full_streaming_v1
```

## 注意

不要再把 `SRA_Accessions` 和 XML full snapshot 混成一个处理脚本。前者是 TSV 索引，后者是 XML 结构解析，两条链路的输入、输出、QC 和查询方式不同。
