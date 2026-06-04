# sra-metadata——SRA元数据包下载、分析及应用

## 目录结构

```text
.
├── sra_accessions_audit_full_20260601/       # SRA_Accessions.tab 并行审计（full 版）
├── sra_annotations/                          # 示例与注释
├── sra_xml_index_cpp/                        # SRA XML 实体关系索引 C++ 流水线
├── sra-metadata数据下载及分析.md              # 下载元数据包、分析元数据
├── sra-metadata数据包预处理.md                # 构建duck数据库
├── sra-metadata数据调用方式.md                # 用python调用构建好的数据库
├── TSS数据处理.md                             # 顶层设计：RefSeq↔SRA 关联方案 —— 这个应该分成几块去描述，metadata的下载、数据包的分析、预处理、tss数据处理方法（别人给的算法）等等，现在是乱的。
└── readme.md                                 # 说明文档（本文件）
```
