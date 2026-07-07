# MycoCosm

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | JGI Data Portal 新 API；凭证来自环境变量。 |
| 固定版本 | 由 frozen_file_manifest.tsv 固定；无冻结清单时脚本默认拒绝 live API |
| 固定入口 | https://files.jgi.doe.gov/mycocosm_file_list/?api_version=2 |
| manifest 中心 | 冻结 file_id/file_name/file_size/md5sum/download_url manifest |
| metadata 同步 | species_ids.txt 或 group/query 驱动，同步 GFF/protein/CDS/CAZy/SMURF |
| 校验策略 | 优先用 API md5sum 强校验；缺 MD5 时用 file_size + gzip/非空弱校验 |
| 差异报告 | 报告查询条件和遗漏风险；live API 仅用于生成候选 frozen manifest |

## 2. 脚本说明

脚本：download_mycocosm.sh；需先补 species_ids.txt，并生成/审核 frozen_file_manifest.tsv。

## 3. 来源

- https://mycocosm.jgi.doe.gov/mycocosm/home
- https://files.jgi.doe.gov/apidoc/
- https://files-download.jgi.doe.gov/apidoc/
