# D1 RefSeq 全量下载脚本

> 修订日期：2026-07-01
> 运行目标：Ubuntu/Linux 服务器
> 核心设计：目标集 manifest + 混合 MD5 校验策略

---

## 1. 文件清单

| 文件 | 用途 |
|---|---|
| `download_refseq_truly_full.sh` | RefSeq release 全量下载主脚本，aria2c 并发，生成三文件输出 |
| `verify_refseq_truly_full.sh` | 串行完整性验证：MD5 + gzip CRC + 文件统计 + 采样 |
| `verify_md5_parallel.py` | 并行 MD5 校验（仅覆盖 target_files.tsv），适合大批量快速复核 |

---

## 2. 下载范围

### 2.1 分类目录（13 + 1）

| 目录 | 内容 |
|---|---|
| `bacteria` | 细菌 |
| `archaea` | 古菌 |
| `fungi` | 真菌 |
| `plant` | 植物 |
| `invertebrate` | 无脊椎动物 |
| `protozoa` | 原生生物 |
| `vertebrate_mammalian` | 哺乳动物 |
| `vertebrate_other` | 非哺乳脊椎动物 |
| `viral` | 病毒 |
| `mitochondrion` | 线粒体 |
| `plasmid` | 质粒 |
| `plastid` | 质体/叶绿体 |
| `other` | 其他 |
| `complete` | 仅下载 bna + complete.wp_protein（独有文件） |

### 2.2 文件类型（6 + 2）

| 后缀 | 格式 | 用途 |
|---|---|---|
| `genomic.fna.gz` | FASTA 核酸 | D1 Track 1 核苷酸 MLM 主数据 |
| `genomic.gbff.gz` | GenBank nucleotide flatfile | D4 CDS-蛋白对提取、密码子 Track 2 |
| `protein.faa.gz` | FASTA 蛋白 | D4 蛋白序列补充 |
| `protein.gpff.gz` | GenPept flatfile | 蛋白注释补充 |
| `rna.fna.gz` | FASTA RNA | D3 RNA 补充 |
| `rna.gbff.gz` | GenBank RNA flatfile | RNA 注释补充 |
| `bna.gz` | Binary ASN.1 | 仅 `complete/` 目录 |
| `complete.wp_protein.*` | 非冗余 WP 蛋白 | 仅 `complete/` 目录（faa + gpff） |

### 2.3 GFF3 边界

RefSeq release FTP **不提供** `genomic.gff3.gz`。D5 Track 3 结构注释若需要 GFF3，应另走：

| 路线 | 适用场景 |
|---|---|
| NCBI Datasets | 按 assembly/accession 批量拉取 `genomic.gff` |
| `genomes/refseq/` assembly 目录 | 按物种/assembly 取每个基因组的 GFF |

本目录脚本不涉及 GFF3，也不在验证阶段检查 GFF3。

---

## 3. 混合 MD5 校验策略

### 3.1 设计原理

NCBI RefSeq release FTP 的 MD5 catalog（`release-catalog/release235.files.installed`）并非覆盖所有文件。部分文件（尤其 complete 目录的 bna/wp_protein）在 catalog 中找不到对应条目。

脚本采用**宽松下载 + 显式未校验清单**策略，而非"无 MD5 就跳过文件"或"全有或全无"：

```
                    ┌─ catalog 中有 MD5 ──→ 写入 target_files.tsv
目标文件 ──查询 MD5──┤
                    └─ catalog 中无 MD5 ──→ 写入 unverified_files.tsv
                                            （仍正常下载，标记为 NO_MD5_IN_CATALOG）
```

### 3.2 三文件输出

| 文件 | 路径 | 内容 |
|---|---|---|
| `target_files.tsv` | `logs/target_files.tsv` | 有 MD5 的文件清单（`md5<TAB>relative_path`），用于 MD5 精确校验 |
| `unverified_files.tsv` | `logs/unverified_files.tsv` | 无 MD5 的文件清单（`relative_path<TAB>reason`），用于 gzip CRC 校验 |
| `state.txt` | `logs/state.txt` | 每个目录的下载状态记录 |

两个 manifest 均带注释头：
```
# release         235
# download_started  2026-07-01T10:00:00Z
# download_finished 2026-07-01T18:30:00Z
# base_url          https://ftp.ncbi.nlm.nih.gov/refseq/release
```

### 3.3 目录状态值

`state.txt` 中每个目录行可能的状态：

| 状态 | 含义 | 退出码影响 |
|---|---|---|
| `DONE` | 全部文件下载成功，MD5 全覆盖 | 正常 |
| `DONE_WITH_UNVERIFIED:N` | 全部文件下载成功，其中 N 个无 MD5 | 取决于 `STRICT_MD5` |
| `PARTIAL` | aria2c 下载失败（部分文件未完成） | exit 1 |
| `FAILED` | 目录列表拉取失败或 manifest 生成失败 | exit 1 |
| `SKIPPED` | 目录无匹配文件 | 正常 |

### 3.4 STRICT_MD5 环境变量

| 值 | 行为 |
|---|---|
| `0`（默认） | 存在 unverified 文件时仅打印警告，退出码为 0 |
| `1` | 存在 unverified 文件时直接 exit 1 |

```bash
# 宽松模式（默认）
nohup bash ./download_refseq_truly_full.sh 1>download.log 2>&1 &

# 严格模式
STRICT_MD5=1 nohup bash ./download_refseq_truly_full.sh 1>download.log 2>&1 &
```

---

## 4. 服务器使用方法

### 4.1 环境准备

```bash
sudo apt-get update
sudo apt-get install -y aria2 curl gawk grep coreutils gzip tmux
```

磁盘空间：压缩文件建议预留 1.5 TB；含解压和中间处理建议预留 6 TB。

```bash
df -h /data
```

### 4.2 修改下载路径

编辑 `download_refseq_truly_full.sh`：

```bash
LOCAL_ROOT="/data3/p252701008/refseq_release"   # 改成服务器上的实际存储路径
```

### 4.3 启动下载

```bash
chmod +x download_refseq_truly_full.sh verify_refseq_truly_full.sh

tmux new -s refseq
nohup bash ./download_refseq_truly_full.sh 1>nohup_download.log 2>&1 &
echo $! > download.pid

tail -f nohup_download.log
```

脚本内部日志：

| 日志 | 路径 |
|---|---|
| 下载日志 | `logs/download.log` |
| 错误日志 | `logs/error.log` |
| 目标清单 | `logs/target_files.tsv` |
| 未校验清单 | `logs/unverified_files.tsv` |
| 目录状态 | `logs/state.txt` |
| aria2 日志 | `logs/aria2_<dir>.log` |

### 4.4 断点续传

`aria2c --continue=true` 已启用。下载中断后直接重跑：

```bash
nohup bash ./download_refseq_truly_full.sh 1>nohup_download_resume.log 2>&1 &
echo $! > download_resume.pid
```

脚本会重新生成 manifest，并继续补齐未完成文件。旧 manifest 和 state.txt 自动移入 `垃圾箱/`。

---

## 5. 验证

### 5.1 Shell 串行验证（完整）

```bash
bash ./verify_refseq_truly_full.sh /data3/p252701008/refseq_release
```

验证流程：

| 步骤 | 内容 |
|---|---|
| Step 1 | MD5 逐文件校验（target_files.tsv），**不中止**，全部跑完 |
| Step 1b | 无 MD5 文件 gzip CRC 校验（unverified_files.tsv） |
| Step 2 | 文件数量统计矩阵（按目录 × 类型） |
| Step 3 | 序列数采样（每目录前 3 个 genomic.fna.gz），含 gzip 损坏检测 |
| Step 4 | 磁盘使用汇总 |

输出报告：

| 报告 | 路径 |
|---|---|
| 验证总结 | `logs/verify_report.txt` |
| MD5 详情 | `logs/md5_detail_report.txt` |
| MD5 失败简表 | `logs/md5_failed.txt` |
| MD5 缺失简表 | `logs/md5_missing.txt` |
| gzip CRC 详情 | `logs/unverified_detail_report.txt` |
| 验证日志 | `logs/verify.log` |

最终退出码：MD5 或 gzip CRC 任何一项失败 → exit 1。

### 5.2 Python 并行 MD5 验证（仅 target_files.tsv）

```bash
python3 ./verify_md5_parallel.py /data3/p252701008/refseq_release
```

注意：Python 并行脚本**只校验 target_files.tsv**（有 MD5 的文件），不覆盖 unverified_files.tsv。对 unverified 文件的 gzip CRC 校验需使用 Shell 串行验证脚本。

调整并行进程数：

```bash
MD5_WORKERS=16 python3 ./verify_md5_parallel.py /data3/p252701008/refseq_release
```

---

## 6. 异常处理

### 6.1 下载阶段

| 情况 | 脚本行为 | 错误信息包含 |
|---|---|---|
| 磁盘空间不足 | exit 1 | 当前剩余 GB、阈值 GB |
| MD5 catalog 下载失败 | exit 1 | URL、目标路径、原因 |
| 目录列表拉取失败 | 目录记 FAILED | URL、原因 |
| manifest 生成失败 | 目录记 FAILED | 具体错误描述 |
| aria2c 下载失败 | 目录记 PARTIAL，继续后续目录 | 退出码 + 含义、日志路径、末尾 20 行异常 |
| 文件无 MD5 catalog 条目 | 写入 unverified_files.tsv，继续下载 | 文件路径、目录内计数 |
| release catalog 下载失败 | [WARN]，不影响主流程 | URL |
| statistics 下载失败 | [WARN]，不影响主流程 | URL |

aria2c 退出码映射表（错误信息自动附注）：

| 退出码 | 含义 |
|---|---|
| 1 | 文件未找到 |
| 2 | 超时 |
| 3 | 磁盘空间不足 |
| 4 | 网络异常 |
| 5 | 下载未完成（校验失败） |
| 6 | 远程文件已变更 |
| 7-9 | aria2c 内部错误 |
| 22 | HTTP 错误（404/403/500） |
| 23 | 重定向过多 |

### 6.2 验证阶段

| 情况 | 处理 |
|---|---|
| `target_files.tsv` 不存在 | exit 1，提示先运行下载脚本 |
| MD5 不匹配 | 记录到 md5_failed.txt + md5_detail_report.txt，继续校验 |
| 目标文件缺失 | 记录到 md5_missing.txt，继续校验 |
| gzip CRC 失败（unverified） | 记录到 unverified_detail_report.txt，继续校验 |
| 序列采样遇到 gzip 损坏 | 显示 `[WARN] gzip 损坏`，跳过序列计数 |
| GFF3 缺失 | 预期行为，不校验 |

### 6.3 修复操作

| 异常类型 | 修复方法 |
|---|---|
| MD5 不匹配 | 将异常文件移入 `垃圾箱/` → 重跑下载脚本续传 |
| 目标文件缺失 | 直接重跑下载脚本补齐 |
| gzip CRC 失败 | 将异常文件移入 `垃圾箱/` → 重跑下载脚本续传 |
| 全部 PARTIAL/FAILED | 重跑下载脚本 → 补齐后运行验证脚本 |

---

## 7. 文件安全策略

- 脚本**不使用 `rm`、`rm -rf`** 等删除命令
- 旧 manifest、旧 state、临时文件均移入 `${LOCAL_ROOT}/垃圾箱/`
- 垃圾箱内文件带时间戳 + PID 后缀（如 `target_files.previous.20260701T100000Z.12345`），不会覆盖
- 需手动清理垃圾箱时，由用户确认后操作

---

## 8. 关键修复记录

### 8.1 Codex 修复（原始 5 项）

| 原问题 | 处理 |
|---|---|
| 日志输出污染函数返回值 | `log()` 输出到 stderr，函数 stdout 只返回文件路径 |
| `aria2c` input 格式错误 | 使用 URI 行 + 缩进 `out=filename` 格式 |
| 下载失败仍写 `DONE` | `aria2c` 失败时记录 `PARTIAL`，最终退出码非零 |
| 全量 MD5 catalog 导致误报缺失 | 下载阶段生成 `logs/target_files.tsv`，验证只读目标集 |
| 错误宣称 release FTP 有 GFF3 | 移除 `genomic.gff3.gz`，README 明确 GFF3 另走流程 |

### 8.2 二次修复（问题 1-10）

| # | 问题 | 处理 |
|---|---|---|
| 1 | `set -e` + 单目录失败后中止全部 | 改为记录 PARTIAL + 详细错误信息，继续后续目录 |
| 2 | 验证脚本 MD5 失败即中止 | MD5 校验失败后继续执行后续检查 |
| 3 | manifest 生成时每文件启动 awk | 改为 bash 关联数组 O(1) 查找 |
| 4 | GFF3 数据源缺失 | 暂不处理，Stage 2 前另建脚本 |
| 5 | complete wp_protein 下载范围 | pattern 同时匹配 faa 和 gpff，全部下载 |
| 6 | manifest 无版本标识 | header 写入 release、时间戳、base_url |
| 7 | 旧 state.txt 污染统计 | 每次启动前移入垃圾箱 |
| 8 | 临时文件残留 | 临时文件移入垃圾箱，不使用 rm |
| 9 | Shell 校验脚本误读 manifest header | 按字段跳过 `#` 开头行 |
| 10 | MD5 catalog 缺项误当作可跳过 | 目录记 FAILED，非零退出码 |

### 8.3 混合 MD5 策略（问题 11-14）

| # | 问题 | 处理 |
|---|---|---|
| 11 | 全有或全无策略导致有价值的文件被放弃 | 宽松下载 + 显式 unverified_files.tsv 双清单 |
| 12 | 无 MD5 文件无完整性验证手段 | 新增 gzip CRC 校验（`gzip -t`） |
| 13 | 严格模式与宽松模式无法切换 | 引入 `STRICT_MD5` 环境变量 |
| 14 | 未校验文件状态不可见 | `state.txt` 记录 `DONE_WITH_UNVERIFIED:N` |

### 8.4 错误信息可读性修复（问题 15-19）

| # | 问题 | 处理 |
|---|---|---|
| 15 | MD5 catalog 下载失败无错误信息 | 输出 URL、目标路径、原因、影响 |
| 16 | 目录列表拉取失败缺 URL | 输出完整 URL 和原因 |
| 17 | release catalog/statistics warning 模糊 | 输出完整 URL |
| 18 | aria2c 退出码无含义解释 | 新增退出码→含义映射表 |
| 19 | 序列采样对 gzip 损坏文件静默返回"0 序列" | 新增 `gzip -t` 预检，损坏文件标记 `[WARN]` |
