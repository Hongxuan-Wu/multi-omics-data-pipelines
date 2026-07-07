# UniProt UniRef50 2026_01

## 1. 下载方案

| 项 | 结论 |
|---|---|
| API/CLI 优先判断 | UniProt 提供 REST API，但完整历史批量文件以固定 FTP/HTTPS 归档 release 目录下载。 |
| 固定版本 | 2026_01 |
| 固定入口 | https://ftp.uniprot.org/pub/databases/uniprot/previous_releases/release-2026_01/uniref/ |
| manifest 中心 | 归档目录 `RELEASE.metalink` 内含版本、大小、MD5 与镜像 URL；脚本断言 metalink version=2026_01 |
| metadata 同步 | 同步 `uniref50.release_note` 与 `RELEASE.metalink`；主数据为归档 `uniref2026_01.tar.gz`，其中包含该 release 的 UniRef 批量文件 |
| 解包策略 | 下载并校验归档包后，脚本提取 `uniref50.fasta.gz`、`uniref50.xml.gz`、`uniref50.release_note`、`uniref50.dtd`、`uniref.xsd`、`README` 到 `uniref50_extracted/` |
| 校验策略 | 解析 `RELEASE.metalink` 的 MD5 强校验；无 MD5 映射文件走 gzip 或非空弱校验并进入未强校验 manifest；提取后的 UniRef50 文件再执行 gzip 或非空弱校验 |
| 差异报告 | 报告 metalink/listing 中存在但未纳入计划的文件，以及计划文件未出现在 listing 的情况 |

## 2. 脚本说明

脚本：download_uniprot_uniref50.sh。

## 3. 来源

- https://www.uniprot.org/api-documentation
- https://ftp.uniprot.org/pub/databases/uniprot/previous_releases/release-2026_01/uniref/
