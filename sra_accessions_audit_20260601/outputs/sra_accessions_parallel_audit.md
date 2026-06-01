# SRA_Accessions 并行审计报告

- 输入文件: `/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_20260516/SRA_Accessions`
- JSON 结果: `/home/m252202014/sra_accessions_audit_20260601/outputs/sra_accessions_parallel_audit.json`
- 代码路径: `/home/m252202014/sra_accessions_audit_20260601/code/sra_accessions_chunk_audit.cpp`
- 合并脚本: `/home/m252202014/sra_accessions_audit_20260601/code/merge_sra_accessions_chunks.py`
- 分片数: `16`
- 总行数(含表头): `148216547`
- 数据行数(不含表头): `148216546`
- 字段数: `20`
- 表头: `Accession, Submission, Status, Updated, Published, Received, Type, Center, Visibility, Alias, Experiment, Sample, Study, Loaded, Spots, Bases, Md5sum, BioSample, BioProject, ReplacedBy`

## Accession 前缀分布
- `OTHER`: `140319454`
- `ERA`: `5542197`
- `SRA`: `2329730`
- `DRA`: `25165`

## Type 分布
- `RUN`: `50011150`
- `EXPERIMENT`: `44608637`
- `SAMPLE`: `44547642`
- `SUBMISSION`: `7897092`
- `STUDY`: `807504`
- `ANALYSIS`: `344521`

## Status 分布
- `live`: `131031850`
- `unpublished`: `12000420`
- `suppressed`: `5181589`
- `withdrawn`: `2687`

## Visibility 分布
- `public`: `139168738`
- `controlled_access`: `9047808`

## 关键字段非缺失计数
- `Experiment`: `42047646`
- `Sample`: `81526632`
- `Study`: `81659595`
- `Loaded`: `50355671`
- `BioSample`: `122509315`
- `BioProject`: `81657883`

## 前缀 × Type
- `DRA`: SUBMISSION=25165
- `ERA`: SUBMISSION=5542197
- `OTHER`: RUN=50011150, EXPERIMENT=44608637, SAMPLE=44547642, STUDY=807504, ANALYSIS=344521
- `SRA`: SUBMISSION=2329730
