# Phytozome

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | JGI Data Portal 新 API；凭证来自环境变量。 |
| 固定版本 | 由 frozen_file_manifest.tsv 固定；无冻结清单时脚本默认拒绝 live API |
| 固定入口 | https://files.jgi.doe.gov/phytozome_file_list/?api_version=2 |
| manifest 中心 | 冻结 file_id/file_name/file_size/md5sum/download_url manifest |
| metadata 同步 | species_ids.txt 或 API filter 驱动，同步注释/功能文件 |
| 校验策略 | 优先用 API md5sum 强校验；缺 MD5 时用 file_size + gzip/非空弱校验 |
| 差异报告 | 报告 API directory 失败条目；live API 仅用于生成候选 frozen manifest |

## 2. 脚本说明

脚本：download_phytozome.sh；需先由 species_ids.example.txt 复制 species_ids.txt，并生成/审核 frozen_file_manifest.tsv。

## 3. 来源

- https://phytozome-next.jgi.doe.gov/
- https://files.jgi.doe.gov/apidoc/
- https://files-download.jgi.doe.gov/apidoc/
