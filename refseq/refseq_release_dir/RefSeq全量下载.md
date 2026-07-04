# RefSeq release 全量下载与校验

> 修订日期：2026-07-02
> 运行目标：Ubuntu/Linux 服务器
> 核心设计：远端目录镜像 + aria2 断点续传 + 官方 MD5/弱校验双轨完整性检查

---

## 1. 文件清单

| 文件 | 用途 |
|---|---|
| `download_refseq.sh` | RefSeq release 下载主脚本；严格镜像远端目录结构，负责下载、续传、跳过已完整文件和下载后校验 |
| `verify_refseq_truly_full.sh` | 综合复核脚本；读取 `RUN_ROOT/manifests` 中的 manifest，执行 MD5、gzip/非空弱校验、文件统计和采样 |
| `verify_md5_parallel.py` | 并行 MD5 复核脚本；只校验有官方 MD5 的 `target_files_<RUN_ID>.tsv` |

---

## 2. 下载范围

### 2.1 本地目录结构

`LOCAL_ROOT=/data3/p252701008/refseq_release` 对应远端
`https://ftp.ncbi.nlm.nih.gov/refseq/release/`。脚本写入文件时保留远端相对路径，例如：

| 远端路径 | 本地路径 |
|---|---|
| `complete/complete.1.genomic.gbff.gz` | `/data3/p252701008/refseq_release/complete/complete.1.genomic.gbff.gz` |
| `release-catalog/RefSeq-release235.catalog.gz` | `/data3/p252701008/refseq_release/release-catalog/RefSeq-release235.catalog.gz` |
| `release-statistics/*.txt` | `/data3/p252701008/refseq_release/release-statistics/*.txt` |

运行日志、下载计划、manifest 不放在 `LOCAL_ROOT`，统一放在：

```bash
RUN_ROOT="/data3/p252701008/refseq_release_runlogs"
```

### 2.2 三类下载开关

| 开关 | 默认值 | 下载内容 |
|---|---:|---|
| `DOWNLOAD_COMPLETE` | `1` | 递归下载 `complete/` 下的全部文件和子目录，不按后缀过滤 |
| `DOWNLOAD_TAXON_DIRS` | `0` | 递归下载 `TAXON_DIRS` 中列出的分类目录；全量下载目录内全部文件，不按后缀过滤 |
| `DOWNLOAD_AUXILIARY` | `1` | 下载根目录说明文件、核心 release catalog、官方 MD5 清单、`release-statistics/` 顶层统计文件 |

默认配置会下载 `complete/` 和辅助信息，不下载物种分类目录。真正全量镜像分类目录时需要把：

```bash
DOWNLOAD_TAXON_DIRS=1
```

### 2.3 分类目录

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
| `complete` | 单独开关控制；递归下载目录内全部内容 |

### 2.4 文件类型边界

当前 `download_refseq.sh` 对 `complete/` 和分类目录采用**远端 listing 全收集**策略：只要远端目录 listing 中出现文件，就写入下载计划；不再维护 `genomic/protein/rna/bna` 等后缀白名单。因此：

| 类别 | 当前行为 |
|---|---|
| `genomic.*` | 下载 |
| `protein.*` | 下载 |
| `rna.*` | 下载 |
| `bna.gz` | 下载 |
| 其他远端 listing 中的文件 | 下载 |
| 子目录 | `complete/` 和分类目录递归进入；`release-statistics/` 不递归进入 `archive/` |

### 2.5 GFF3 边界

RefSeq release FTP **不提供** `genomic.gff3.gz`。D5 Track 3 结构注释若需要 GFF3，应另走：

| 路线 | 适用场景 |
|---|---|
| NCBI Datasets | 按 assembly/accession 批量拉取 `genomic.gff` |
| `genomes/refseq/` assembly 目录 | 按物种/assembly 取每个基因组的 GFF |

本目录脚本不涉及 GFF3，也不在验证阶段检查 GFF3。

---

## 3. 完整性校验策略

### 3.1 官方 MD5 的角色

下载脚本始终先下载官方清单：

```bash
release-catalog/release235.files.installed
```

这个文件不一定覆盖远端 listing 中的每个目标文件。因此脚本把目标拆成两类：

| 类别 | manifest | 校验方式 | 下载行为 |
|---|---|---|---|
| 有官方 MD5 | `target_files_<RUN_ID>.tsv` | 下载前跳过判断、aria2 `checksum=md5=...`、下载后 `md5sum --check` | 正常下载或跳过 |
| 无官方 MD5 | `unverified_files_<RUN_ID>.tsv` | 下载前/后用远端大小 + gzip CRC 或非空检查 | 正常下载，不因缺 MD5 丢弃 |

关键点：**MD5 不是决定下载范围的依据**。下载范围由远端目录 listing 决定；MD5 只承担完整性校验和跳过已完成文件的任务。

### 3.2 本轮运行输出

每次运行都会生成一个 `RUN_ID`，格式类似：

```text
20260702T132418Z.1820503
```

主要输出位于 `RUN_ROOT`：

| 文件 | 路径模式 | 内容 |
|---|---|---|
| 下载计划 | `plans/download_plan_<RUN_ID>.tsv` | `group relative_path url local_dir out_name` |
| complete aria2 输入 | `plans/aria_complete_<RUN_ID>.txt` | complete 分组实际交给 aria2 的下载任务 |
| taxon aria2 输入 | `plans/aria_taxon_<RUN_ID>.txt` | 分类目录分组实际交给 aria2 的下载任务 |
| auxiliary aria2 输入 | `plans/aria_auxiliary_<RUN_ID>.txt` | 辅助信息分组实际交给 aria2 的下载任务 |
| 官方 MD5 manifest | `manifests/target_files_<RUN_ID>.tsv` | `md5<TAB>relative_path` |
| 无官方 MD5 manifest | `manifests/unverified_files_<RUN_ID>.tsv` | `relative_path<TAB>reason` |
| md5sum 校验文件 | `manifests/md5_check_<RUN_ID>.txt` | 供 `md5sum --check` 使用 |
| 状态文件 | `state_<RUN_ID>.tsv` | 已启用 aria2 下载分组的下载状态；早期失败时可能为空，不代表最终 MD5/弱校验状态 |
| 下载日志 | `logs/download_<RUN_ID>.log` | 主流程日志 |
| aria2 日志 | `logs/aria2_<group>_<RUN_ID>.log` | aria2 详细日志 |

manifest 注释头包含：

```text
# release<TAB>235
# base_url<TAB>https://ftp.ncbi.nlm.nih.gov/refseq/release
# local_root<TAB>/data3/p252701008/refseq_release
# run_id<TAB><RUN_ID>
# columns<TAB>...
```

### 3.3 已有文件跳过规则

生成 aria2 输入文件前，脚本会检查本地已有文件：

| 情况 | 处理 |
|---|---|
| 存在 `.aria2` 续传状态 | 不跳过，交给 aria2 继续续传 |
| 有官方 MD5 且本地 MD5 匹配 | 跳过 |
| 有官方 MD5 但本地 MD5 不匹配 | 移入 `RUN_ROOT/垃圾箱`，重新下载 |
| 无官方 MD5 且远端大小匹配，gzip 文件 `gzip -t` 通过 | 跳过 |
| 无官方 MD5 且远端大小匹配，非 gzip 文件非空 | 跳过 |
| 大小不匹配、gzip CRC 失败、空文件 | 移入 `RUN_ROOT/垃圾箱`，重新下载 |

### 3.4 下载后校验

| 开关 | 默认值 | 作用 |
|---|---:|---|
| `VERIFY_MD5_AFTER_DOWNLOAD` | `1` | aria2 全部完成后，对有官方 MD5 的文件执行 `md5sum --check --quiet` |
| `VERIFY_UNVERIFIED_AFTER_DOWNLOAD` | `1` | 对无官方 MD5 的文件执行大小 + gzip CRC 或非空弱校验 |
| `SKIP_VERIFIED_FILES` | `1` | 生成 aria2 输入前跳过已确认完整的本地文件 |

---

## 4. 服务器使用方法

### 4.1 环境准备

```bash
sudo apt-get update
sudo apt-get install -y aria2 curl gawk grep coreutils gzip tmux
```

`ShellCheck` 只用于可选静态检查；未安装不影响下载脚本执行。下载脚本强制依赖的是 `curl`、`aria2c`、`awk`、`sort`、`md5sum`。

磁盘空间：脚本默认 `MIN_DISK_GB=2000`，因此压缩文件下载目录至少需要预留 2000 GB；含解压和中间处理建议预留 6 TB。若确实要低于 2000 GB 运行，需要编辑 `download_refseq.sh` 顶部的 `MIN_DISK_GB`。

```bash
df -h /data
```

### 4.2 修改下载路径

编辑 `download_refseq.sh` 顶部配置：

```bash
RELEASE="235"
BASE_URL="https://ftp.ncbi.nlm.nih.gov/refseq/release"
LOCAL_ROOT="/data3/p252701008/refseq_release"
RUN_ROOT="/data3/p252701008/refseq_release_runlogs"
```

### 4.3 启动下载

```bash
chmod +x download_refseq.sh verify_refseq_truly_full.sh

tmux new -s refseq
nohup bash ./download_refseq.sh 1>nohup_download.log 2>&1 &
echo $! > download.pid

tail -f nohup_download.log
```

推荐 aria2 初始参数。当前脚本顶部是直接赋值，调整参数需要编辑 `download_refseq.sh` 顶部配置；运行前在 shell 里临时设置同名环境变量不会覆盖这些值。

```bash
ARIA2_CONNECTIONS=4
ARIA2_MAX_CONCURRENT=8
ARIA2_SPLIT=4
ARIA2_MIN_SPLIT_SIZE="192M"
ARIA2_SUMMARY_INTERVAL=120
```

脚本内部日志和清单：

| 类型 | 路径模式 |
|---|---|
| 主流程日志 | `${RUN_ROOT}/logs/download_<RUN_ID>.log` |
| 错误日志 | `${RUN_ROOT}/logs/error_<RUN_ID>.log` |
| 下载计划 | `${RUN_ROOT}/plans/download_plan_<RUN_ID>.tsv` |
| 目标清单 | `${RUN_ROOT}/manifests/target_files_<RUN_ID>.tsv` |
| 无官方 MD5 清单 | `${RUN_ROOT}/manifests/unverified_files_<RUN_ID>.tsv` |
| 状态文件 | `${RUN_ROOT}/state_<RUN_ID>.tsv` |
| aria2 日志 | `${RUN_ROOT}/logs/aria2_<group>_<RUN_ID>.log` |

### 4.4 断点续传

`aria2c --continue=true` 已启用。下载中断后直接重跑：

```bash
nohup bash ./download_refseq.sh 1>nohup_download_resume.log 2>&1 &
echo $! > download_resume.pid
```

脚本会重新读取远端目录、重新生成本轮 manifest，并继续补齐未完成文件。已有完整文件会在写 aria2 输入前被跳过；未完成文件的 `.aria2` 续传状态会保留。

---

## 5. 验证

### 5.1 主下载脚本内置校验

`download_refseq.sh` 默认已经在下载完成后执行两类校验：

| 校验 | 默认开关 | 覆盖范围 |
|---|---:|---|
| 官方 MD5 强校验 | `VERIFY_MD5_AFTER_DOWNLOAD=1` | `target_files_<RUN_ID>.tsv` 中的文件 |
| 无官方 MD5 弱校验 | `VERIFY_UNVERIFIED_AFTER_DOWNLOAD=1` | `unverified_files_<RUN_ID>.tsv` 中的文件 |

因此正常跑完且退出码为 0 时，本轮目标集已经完成一次自动校验。下面两个脚本用于后续复核、补查或并行加速。

### 5.2 Shell 综合验证

默认自动选择最新 `target_files_<RUN_ID>.tsv`：

```bash
bash ./verify_refseq_truly_full.sh
```

指定目录和某次运行：

```bash
bash ./verify_refseq_truly_full.sh \
  /data3/p252701008/refseq_release \
  /data3/p252701008/refseq_release_runlogs \
  20260702T132418Z.1820503
```

验证流程：

| 步骤 | 内容 |
|---|---|
| Step 1 | MD5 逐文件校验 `target_files_<RUN_ID>.tsv`，不中止，全部跑完 |
| Step 1b | 无官方 MD5 文件弱校验：gzip 文件跑 `gzip -t`，非 gzip 文件检查非空 |
| Step 2 | 文件数量统计矩阵（按目录 × 类型） |
| Step 3 | 序列数采样（每目录前 3 个 `genomic.fna.gz`），含 gzip 损坏检测 |
| Step 4 | 磁盘使用汇总 |

输出报告：

| 报告 | 路径 |
|---|---|
| 验证总结 | `${RUN_ROOT}/logs/verify_report_<RUN_ID>.txt` |
| MD5 详情 | `${RUN_ROOT}/logs/md5_detail_report_<RUN_ID>.txt` |
| MD5 失败简表 | `${RUN_ROOT}/logs/md5_failed_<RUN_ID>.txt` |
| MD5 缺失简表 | `${RUN_ROOT}/logs/md5_missing_<RUN_ID>.txt` |
| 无官方 MD5 详情 | `${RUN_ROOT}/logs/unverified_detail_report_<RUN_ID>.txt` |
| 验证日志 | `${RUN_ROOT}/logs/verify_<RUN_ID>.log` |

最终退出码：MD5、缺失文件、路径安全、gzip CRC、非 gzip 空文件任一失败 -> exit 1。

### 5.3 Python 并行 MD5 验证

```bash
python3 ./verify_md5_parallel.py
```

指定某次运行：

```bash
python3 ./verify_md5_parallel.py --run-id 20260702T132418Z.1820503
```

直接指定 manifest：

```bash
python3 ./verify_md5_parallel.py \
  --manifest /data3/p252701008/refseq_release_runlogs/manifests/target_files_20260702T132418Z.1820503.tsv
```

注意：Python 并行脚本只校验有官方 MD5 的文件，不覆盖 `unverified_files_<RUN_ID>.tsv`。无官方 MD5 文件仍用 Shell 综合验证脚本复核。

调整并行进程数：

```bash
MD5_WORKERS=16 python3 ./verify_md5_parallel.py
```

---

## 6. 异常处理

### 6.1 下载阶段

| 情况 | 脚本行为 | 错误信息包含 |
|---|---|---|
| 磁盘空间不足 | exit 1 | 当前剩余 GB、阈值 GB |
| MD5 catalog 下载失败 | exit 1 | URL、目标路径、原因 |
| 目录列表拉取失败 | exit 1 | URL、网络/代理/NCBI 服务提示 |
| manifest 生成失败 | exit 1 | 具体 manifest 路径和错误描述 |
| aria2c 下载失败 | 当前分组记 `FAILED`，主流程最终 exit 1 | 退出码 + 含义、aria2 日志路径、异常摘录 |
| 文件无官方 MD5 条目 | 写入 `unverified_files_<RUN_ID>.tsv`，继续下载 | 文件路径、原因 |
| 本地已有文件 MD5 不匹配 | 移入 `RUN_ROOT/垃圾箱` 后重新下载 | expected/actual MD5 |
| 本地已有文件大小或 gzip CRC 异常 | 移入 `RUN_ROOT/垃圾箱` 后重新下载 | 远端大小、本地大小或 gzip 错误 |

aria2c 退出码映射表以 `download_refseq.sh` 中 `report_aria_failure()` 为准，错误日志会额外摘录 `error/failed/exception/abort/timeout/403/404/503` 等关键行。

常见 NCBI 下载问题：

| 现象 | 判断 | 处理 |
|---|---|---|
| `HTTP/1.1 503 Service Unavailable` | 远端临时拒绝/过载/限流 | 降低 `ARIA2_MAX_CONCURRENT`，稍后重跑 |
| aria2 控制台长期 `DL:0B` | 当前连接没有拿到有效数据 | 查看 `aria2_<group>_<RUN_ID>.log` 的 HTTP 状态 |
| 大量 `.aria2` 文件 | 有未完成续传任务 | 正常现象；重跑脚本会继续续传 |

### 6.2 验证阶段

| 情况 | 处理 |
|---|---|
| `target_files_<RUN_ID>.tsv` 不存在 | exit 1，提示检查 `RUN_ROOT/RUN_ID` |
| `unverified_files_<RUN_ID>.tsv` 不存在 | exit 1，提示检查 `RUN_ROOT/RUN_ID` |
| MD5 不匹配 | 记录到 `md5_failed_<RUN_ID>.txt` + `md5_detail_report_<RUN_ID>.txt`，继续校验 |
| 目标文件缺失 | 记录到 `md5_missing_<RUN_ID>.txt`，继续校验 |
| gzip CRC 失败（无官方 MD5） | 记录到 `unverified_detail_report_<RUN_ID>.txt`，继续校验 |
| 非 gzip 无官方 MD5 文件为空 | 记录到 `unverified_detail_report_<RUN_ID>.txt`，继续校验 |
| 序列采样遇到 gzip 损坏 | 显示 `[WARN] gzip 损坏`，跳过序列计数 |
| GFF3 缺失 | 预期行为，不校验 |

### 6.3 修复操作

| 异常类型 | 修复方法 |
|---|---|
| MD5 不匹配 | 重跑 `download_refseq.sh`；脚本会识别异常文件并移入 `RUN_ROOT/垃圾箱` |
| 目标文件缺失 | 直接重跑下载脚本补齐 |
| gzip CRC 失败 | 重跑 `download_refseq.sh`；脚本会重新下载无法确认完整性的文件 |
| 分组 `FAILED` | 降低并发或等待远端恢复后重跑下载脚本 |

---

## 7. 文件安全策略

- 脚本**不使用 `rm`、`rm -rf`** 等删除命令
- 下载前识别出的异常本地旧文件不删除，只移入 `${RUN_ROOT}/垃圾箱/`
- 主下载脚本的下载后校验发现问题时写入错误日志并返回非零退出码；复核脚本会生成详细报告。两者都不在下载后自动移动文件
- 垃圾箱内文件名带异常原因、`RUN_ID` 和原相对路径，不会覆盖
- `LOCAL_ROOT` 只保存 RefSeq release 镜像内容，不写运行日志和 manifest
- 需手动清理垃圾箱时，由用户确认后操作

---

## 8. 当前版本关键点

| 主题 | 当前实现 |
|---|---|
| 下载入口 | `download_refseq.sh` |
| 本地镜像目录 | `LOCAL_ROOT=/data3/p252701008/refseq_release` |
| 运行产物目录 | `RUN_ROOT=/data3/p252701008/refseq_release_runlogs` |
| 下载范围 | `complete/` 和分类目录按远端 listing 全量收集，不按后缀过滤 |
| 辅助信息 | 下载核心 release catalog、官方 MD5 清单和 `release-statistics/` 顶层文件；跳过 `archive/` |
| 大 catalog 下载 | `RefSeq-release235.catalog.gz` 走 aria2 |
| 官方 MD5 | 用于跳过、aria2 checksum、下载后强校验 |
| 无官方 MD5 文件 | 正常下载，写入 `unverified_files_<RUN_ID>.tsv`，用大小 + gzip/非空弱校验 |
| 断点续传 | `.aria2` 存在时不跳过，继续交给 aria2 |
| 异常文件 | 下载前完整性检查发现的异常旧文件不删除，移动到 `RUN_ROOT/垃圾箱`；下载后校验/复核阶段只报告问题 |
| 复核脚本 | `verify_refseq_truly_full.sh` 自动发现最新 manifest；`verify_md5_parallel.py` 并行复核官方 MD5 |
