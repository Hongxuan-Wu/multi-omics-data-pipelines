# MycoCosm

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | JGI Data Portal 新 API；凭证来自环境变量。 |
| 固定版本 | 由 frozen_file_manifest.tsv 固定；无冻结清单时脚本默认拒绝 live API |
| 固定入口 | https://files.jgi.doe.gov/mycocosm_file_list/?api_version=2 |
| manifest 中心 | 冻结 file_id/file_name/file_size/md5sum/download_url manifest |
| metadata 同步 | species_ids.txt 或 group/query 驱动，默认同步 GFF/CAZy/SMURF/annotation；protein/CDS FASTA 由开关控制 |
| 校验策略 | 优先用 API md5sum 强校验；缺 MD5 时用 file_size + gzip/非空弱校验 |
| 差异报告 | 报告查询条件和遗漏风险；live API 仅用于生成候选 frozen manifest |

## 2. 脚本说明

脚本：download_mycocosm.sh；需先补 species_ids.txt，并生成/审核 frozen_file_manifest.tsv。

序列下载开关：`DOWNLOAD_PROTEIN_CDS_SEQUENCES=0`。默认过滤 frozen/live manifest 中的 protein/CDS FASTA，保留真菌功能注释；需要 JGI 真菌蛋白或 CDS 序列时设为 `1`。

## 3. 来源

- https://mycocosm.jgi.doe.gov/mycocosm/home
- https://files.jgi.doe.gov/apidoc/
- https://files-download.jgi.doe.gov/apidoc/
