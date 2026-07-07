# IMG/M

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | 有公开 metadata API，但没有公开 FTP/直接批量文件下载 API；按 web cart 手动导出。 |
| 固定版本 | 手动导出时记录 cart freeze |
| 固定入口 | https://img.jgi.doe.gov/ |
| manifest 中心 | cart 导出的 dataset_ids.tsv；metadata API 可辅助核对 genomes/bin id |
| metadata 同步 | 导出 dataset ids、filters、policy 记录 |
| 校验策略 | gzip/非空弱校验 |
| 差异报告 | 由人工记录导出文件清单和缺失项 |

## 2. 脚本说明

文档：manual_export_img_m.md。

## 3. 来源

- https://img.jgi.doe.gov/
