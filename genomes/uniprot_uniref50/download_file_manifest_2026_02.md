# UniProt 2026_02 下载文件清单

## 1. 完整路径文件

所有逐文件路径位于：

- `download_file_manifest_2026_02.tsv`

TSV 每行对应一个下载目标，字段为：

| 字段 | 含义 |
|---|---|
| `scope` | `required` 必须下载；`conditional` 仅在需要离线 UniParc 来源/历史审计时下载 |
| `tier` | 下载阶段，`P0` 至 `P4` |
| `dataset` | 数据资源名称 |
| `release` | 目标 UniProt release |
| `remote_url` | 官方下载 URL 或分页 API 入口 |
| `relative_path` | 建议的本地相对路径 |
| `bytes` | 官方文件大小；API 生成目标为空 |
| `md5` | 官方 MD5；manifest、MD5 sidecar 和 API 生成目标为空 |
| `source_kind` | 文件来源类型 |
| `notes` | 版本、分页或条件性说明 |

## 2. 数量与容量

| 范围 | 目标数 | 已知压缩体量 |
|---|---:|---:|
| 必需下载 | 13,323 | 1,034.012 GB，另加 Proteomes REST JSON 快照 |
| 条件性 UniParc XML | 201 | 675.809 GB |
| 合计 | 13,524 | 1,709.821 GB，另加 Proteomes REST JSON 快照 |

必需目标包含：

| 数据集 | 文件数 |
|---|---:|
| UniProtKB complete FASTA/DAT/metadata | 10 |
| UniProtKB complete docs | 104 |
| UniRef50 / 90 / 100 | 7 / 7 / 6 |
| ID mapping | 3 |
| Reference Proteomes | 4 |
| Pan Proteomes | 12,789 |
| Proteomes REST 快照 | 1 个分页生成目标 |
| Genome annotation tracks | 73 |
| Proteomics mapping | 50 |
| Variants | 38 |
| UniProt-GOA all | 7 |
| Semantic RDF | 20 |
| UniParc metadata + active FASTA | 204 |

## 3. 重要边界

1. Pan Proteomes 包含 3,195 个物种目录；每个目录列出 `RELEASE.metalink`、FASTA、matrix 和 stats 四个文件，另有 9 个顶层文件。
2. `genome_annotation_tracks` 顶层仍列出小鼠、大鼠和酵母目录，但这些目录在 `2026_02` 中为空；当前 73 个实际文件均来自人类轨道及顶层 metadata。
3. Proteomes REST 是分页 API，不是单个静态远端文件。下载器必须跟随 `Link` header 合并所有页面，并记录查询和时间戳。
4. `current_release` URL 会在下一次发布时漂移。执行下载时必须断言 metalink version 为 `2026_02` 并校验清单中的 MD5；版本不匹配时应立即停止。
5. 清单未重复加入 UniProtKB XML、`idmapping_selected`、GOA GCRP、taxonomic divisions 或整库 RDF entry shards，因为它们分别是所选 DAT、全量 idmapping、GOA all、complete 或 XML/DAT 数据的替代格式/子集/分区副本。
6. `conditional` 的 UniParc XML 仅用于离线查询 UniParc-only 或历史序列的完整来源关系；普通序列比对使用必需层中的 UniParc active FASTA。

## 4. 筛选路径

列出全部必需官方 URL：

```bash
awk -F '\t' '!/^#/ && $1 == "required" {print $5}' download_file_manifest_2026_02.tsv
```

列出条件性 UniParc XML URL：

```bash
awk -F '\t' '!/^#/ && $1 == "conditional" {print $5}' download_file_manifest_2026_02.tsv
```

列出必需本地相对路径：

```bash
awk -F '\t' '!/^#/ && $1 == "required" {print $6}' download_file_manifest_2026_02.tsv
```

## 5. 重新生成

```bash
./generate_download_file_manifest.sh
```

生成器只读取官方目录、HTTP headers 和 `RELEASE.metalink`，不下载数据库正文。它会检查 release、文件数、字段格式和 URL 唯一性。
