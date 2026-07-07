# ensembl 校验报告

## 1. 结论

本轮追加修复 Ensembl CHECKSUMS 策略：当前 release 的 `CHECKSUMS` 不等同于 MD5 manifest；GTF 仅在解析到真实 32 hex MD5 时使用官方 MD5 强校验，无官方 MD5 时不阻断计划生成，下载后走 `gzip -t` 或非空弱校验，并写入审计 manifest。未运行真实下载。

## 2. 流程验收

| 序号 | 步骤 | 状态 | 结论 |
|---:|---|---|---|
| 1 | 固定版本与入口 | 已完成 | Ensembl 116 / Ensembl Genomes 63 固定入口不变 |
| 2 | manifest/listing | 已修复 | FTP listing、species metadata 与每个 species 目录 CHECKSUMS 纳入计划/manifest |
| 3 | 空计划保护 | 已修复 | 总计划为 0 或 GTF payload 为 0 时 `die` |
| 4 | 差异报告 | 已修复 | division 根 listing、species listing、CHECKSUMS 缺失/不可读、GTF 无官方 MD5 均写入 `DIFF_REPORT` |
| 5 | aria2 checksum | 已修复 | 只有解析到真实 32 hex MD5 的目标写入 `checksum=md5=...`；无官方 MD5 的 GTF 继续写入下载计划但不写 checksum 行 |
| 6 | 下载后校验 | 已修复 | GTF 有官方 MD5 时执行 `md5sum --check`；无官方 MD5 时执行 `weak_verify_file`，即 gzip 文件 `gzip -t`、非 gzip 文件非空校验；metadata/CHECKSUMS 同样走 weak policy |
| 7 | 静态语法检查 | 待目标环境确认 | 本机未完成 Bash 语法解析；需在 Linux 服务器执行 `bash -n genomes/ensembl/download_ensembl.sh` |
