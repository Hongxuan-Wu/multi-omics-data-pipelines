# UniProt 2026_02 下载文件清单

## 1. 最终合同

| 项 | 值 |
|---|---|
| UniProt release | `2026_02` |
| 官方根目录 | `https://ftp.uniprot.org/pub/databases/uniprot/current_release/` |
| 下载目标数 | 25 |
| 官方压缩体积 | 618,535,806,550 bytes（618.536 GB；576.056 GiB） |
| 机器可读清单 | `download_file_manifest_2026_02.tsv` |
| 默认下载 | `uniref50`，共 3 个文件 |

| 数据组 | 文件数 | 压缩字节 | 用途 |
|---|---:|---:|---|
| `uniprotkb_complete` | 7 | 159,416,607,496 | Swiss-Prot/TrEMBL 序列与 DAT 注释 |
| `uniprotkb_accessions` | 2 | 49,569,006 | secondary accession 到当前 accession 的映射 |
| `uniref50` | 3 | 8,770,271,941 | 统一建模核心 |
| `uniref90` | 3 | 32,059,063,697 | 更细粒度扩展 |
| `uniref100` | 3 | 63,101,633,497 | 100% 层级代表序列 |
| `idmapping` | 3 | 14,058,085,387 | 跨数据库、多组学 ID 对齐 |
| `reference_proteomes` | 4 | 341,080,575,526 | 参考蛋白组、物种和组装上下文 |

下载器还提供两个不改变 manifest 的子集视图：`swissprot` 为 5 项（3 个 Swiss-Prot 正文加共享 README/metalink，801,331,647 bytes）；`trembl` 为 4 项（2 个 TrEMBL 正文加共享 README/metalink，158,615,287,888 bytes）。

## 2. 逐文件清单

以下路径均相对于官方根目录。

### 2.1 UniProtKB 全量序列与注释

1. `knowledgebase/complete/README`
2. `knowledgebase/complete/RELEASE.metalink`
3. `knowledgebase/complete/uniprot_sprot.fasta.gz`
4. `knowledgebase/complete/uniprot_sprot_varsplic.fasta.gz`
5. `knowledgebase/complete/uniprot_trembl.fasta.gz`
6. `knowledgebase/complete/uniprot_sprot.dat.gz`
7. `knowledgebase/complete/uniprot_trembl.dat.gz`
8. `knowledgebase/complete/docs/RELEASE.metalink`
9. `knowledgebase/complete/docs/sec_ac.txt`

### 2.2 统一建模数据

10. `uniref/uniref50/README`
11. `uniref/uniref50/RELEASE.metalink`
12. `uniref/uniref50/uniref50.fasta.gz`
13. `uniref/uniref90/README`
14. `uniref/uniref90/RELEASE.metalink`
15. `uniref/uniref90/uniref90.fasta.gz`
16. `uniref/uniref100/README`
17. `uniref/uniref100/RELEASE.metalink`
18. `uniref/uniref100/uniref100.fasta.gz`

### 2.3 多组学对齐数据

19. `knowledgebase/idmapping/README`
20. `knowledgebase/idmapping/RELEASE.metalink`
21. `knowledgebase/idmapping/idmapping.dat.gz`
22. `knowledgebase/reference_proteomes/README`
23. `knowledgebase/reference_proteomes/RELEASE.metalink`
24. `knowledgebase/reference_proteomes/STATS`
25. `knowledgebase/reference_proteomes/Reference_Proteomes_2026_02.tar.gz`

## 3. 重要边界

1. 25 个目标全部为 `required`；没有条件项、API 生成项或目录递归抓取项。
2. `uniprot_sprot.*` 与 `uniprot_trembl.*` 分开保存，因此既构成 UniProtKB complete，又能区分 reviewed 与 unreviewed。
3. DAT 文件承担完整条目注释；本方案不重复下载同内容的 XML。
4. `idmapping.dat.gz` 提供全量交叉引用；`sec_ac.txt` 补充历史/secondary accession 解析。
5. Reference Proteomes tar 包已覆盖该 release 的参考蛋白组分发内容，README、STATS 和 metalink 作为解释与校验元数据单独保留。
6. UniParc、GOA、RDF、Pan Proteomes、Proteomes REST、genome annotation tracks、variants 和 proteomics mapping 不在本合同内。
7. `current_release` 会在下一版发布时漂移。实际下载前必须检查所有所选 `RELEASE.metalink` 的 `<version>` 仍为 `2026_02`；不一致时停止。
8. 618.536 GB 仅为压缩文件体积，不含解压、索引、训练分片和冗余空间。

## 4. TSV 字段

| 字段 | 含义 |
|---|---|
| `scope` | 本合同固定为 `required` |
| `tier` | `P0` 核心数据；`P1` 映射与参考蛋白组 |
| `dataset` | 下载器可选择的数据组 |
| `release` | 固定为 `2026_02` |
| `remote_url` | 官方 HTTPS URL |
| `relative_path` | `LOCAL_ROOT` 下的安全相对路径 |
| `bytes` | 官方 metalink 中的字节数 |
| `md5` | 静态文件的官方 MD5；`RELEASE.metalink` 留空 |
| `source_kind` | `static_file` 或 `release_manifest` |
| `notes` | 校验来源或预期版本 |

## 5. 查询与执行

列出全部官方 URL：

```bash
awk -F '\t' '!/^#/ && $1 != "scope" {print $5}' download_file_manifest_2026_02.tsv
```

查看可选数据组：

```bash
./download_uniprot.sh --list-datasets
```

分别规划 Swiss-Prot 与 TrEMBL：

```bash
./download_uniprot.sh --dataset swissprot --plan-only
./download_uniprot.sh --dataset trembl --plan-only
```

默认生成 UniRef50 计划，不访问网络：

```bash
./download_uniprot.sh --plan-only
```

生成全量 25 文件计划：

```bash
./download_uniprot.sh --all --plan-only
```

## 6. 重新生成

```bash
./generate_download_file_manifest.sh
```

生成器只读取 7 个官方 `RELEASE.metalink`，不下载数据库正文。它会断言 release、逐数据组文件数、总文件数、字段格式、MD5 和 URL 唯一性；生成结果必须继续满足 25 文件与 618,535,806,550 bytes 的合同。
