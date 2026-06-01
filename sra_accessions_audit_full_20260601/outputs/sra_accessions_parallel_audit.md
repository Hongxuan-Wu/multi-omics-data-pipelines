# SRA_Accessions 并行审计报告

- 输入文件: `/data/p252701008/datasets/SRA/NCBI_SRA_Metadata_Full_20260516/SRA_Accessions`
- JSON 结果: `/home/m252202014/sra_accessions_audit_full_20260601/outputs/sra_accessions_parallel_audit.json`
- 代码路径: `/home/m252202014/sra_accessions_audit_full_20260601/code/sra_accessions_chunk_audit.cpp`
- 合并脚本: `/home/m252202014/sra_accessions_audit_full_20260601/code/merge_sra_accessions_chunks.py`
- 分片数: `32`
- 总行数(含表头): `148211049`
- 数据行数(不含表头): `148211048`
- 字段数: `20`
- 表头: `Accession, Submission, Status, Updated, Published, Received, Type, Center, Visibility, Alias, Experiment, Sample, Study, Loaded, Spots, Bases, Md5sum, BioSample, BioProject, ReplacedBy`

## Accession 前缀分布
- `OTHER`: `140313900`
- `ERA`: `5542197`
- `SRA`: `2329786`
- `DRA`: `25165`

## Type 分布
- `RUN`: `50013612`
- `EXPERIMENT`: `44607471`
- `SAMPLE`: `44540766`
- `SUBMISSION`: `7897148`
- `STUDY`: `807530`
- `ANALYSIS`: `344521`

## Status 分布
- `live`: `131929435`
- `unpublished`: `11084693`
- `suppressed`: `5194233`
- `withdrawn`: `2687`

## Visibility 分布
- `public`: `139153756`
- `controlled_access`: `9057292`

## 关键字段非缺失计数
- `Experiment`: `42295745`
- `Sample`: `82027321`
- `Study`: `82139095`
- `Loaded`: `50358133`
- `BioSample`: `123423527`
- `BioProject`: `82141907`

## 前缀 × Type
- `DRA`: SUBMISSION=25165
- `ERA`: SUBMISSION=5542197
- `OTHER`: RUN=50013612, EXPERIMENT=44607471, SAMPLE=44540766, STUDY=807530, ANALYSIS=344521
- `SRA`: SUBMISSION=2329786
