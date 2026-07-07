# IMG/M 手动导出说明

## 1. 结论

IMG/M 不写自动下载脚本。IMG/M 有公开 metadata API（例如 `genomesMetadata.cgi`、`binMetadata.cgi`），但没有公开 FTP 或可直接批量导出序列/注释文件的稳定下载 API。该库需要 JGI/IMG 登录、项目级 data policy 确认和 web cart 导出；当前任务只保留手动操作说明。

## 2. 可自动核对但不自动下载的入口

| 入口 | 用途 | 本任务处理 |
|---|---|---|
| `https://img.jgi.doe.gov/cgi-bin/m/main.cgi?section=FindGenomes&page=genomesMetadata.cgi` | genomes metadata 查询 | 可用于导出前核对 dataset id |
| `https://img.jgi.doe.gov/cgi-bin/m/main.cgi?section=FindGenomes&page=binMetadata.cgi` | MAG/bin metadata 查询 | 可用于导出前核对 bin id |
| IMG/M web cart | 批量文件导出 | 需要人工登录与 data policy 确认 |

## 3. 手动流程

1. 打开 https://img.jgi.doe.gov/ 并登录 JGI 账号。
2. 在 IMG/M 中按研究需要筛选 MAG / environmental microbial datasets。
3. 将目标 dataset 加入 cart。
4. 在 cart/export 页面选择功能注释表、pathway、COG/KO/Pfam/CAZy 等字段。
5. 导出 TSV/CSV 后保存到服务器目录，例如 `/data3/p252701008/genomes/img_m/manual_exports/`。
6. 同步保存 cart 导出时的筛选条件、dataset id 列表、导出时间和 data policy 确认记录。

## 4. 必须保留的 metadata

| 文件 | 作用 |
|---|---|
| `dataset_ids.tsv` | IMG/M dataset id 与名称 |
| `export_filters.md` | cart 筛选条件 |
| `functional_annotations.tsv.gz` | 功能注释主表 |
| `pathway_annotations.tsv.gz` | 代谢通路注释 |
| `policy_confirmation.md` | data policy 确认记录 |

## 5. 校验

IMG/M web cart 导出通常没有公开 MD5。导出后执行 gzip 压缩，并用 `gzip -t` 与非空检查做弱校验。
