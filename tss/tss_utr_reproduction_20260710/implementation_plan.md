# PEGS-Compatible S1 TSS/UTR Reproduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 以公司指定的 PEGS 固定提交补齐 transcript preparation 和 PASA alignment 数据，安全、可审计地从 9 份 RNA-seq 复现 `S1.genome_new.gff3` 的候选 UTR 注释过程。

**Architecture:** 不直接执行 PEGS 的服务器专用调度器，而实现一个 PEGS-compatible staged runner。公司流程图中的显式参数优先；PEGS `rnaseq2gene.py`/`add_utr.py` 提供缺失的数据变换、PASA 阈值和前后依赖；每个阶段只写不可变 run/attempt 目录，并在结构、哈希和工具版本门禁通过后原子发布完成标记。

**Tech Stack:** Bash 5、Perl 5、Python 3.11（独立 conda prefix）、fastp 0.23.1、STAR 2.7.9a、StringTie 2.2.0、gffread 0.12.7、CD-HIT 4.8.1、SeqClean（PASA 2.5.2 固定副本）、blast-legacy 2.2.26、PASA 2.5.2、minimap2 2.31、samtools 1.23.1、SQLite 3.53.3、AGAT 0.8.0、Git。

## Global Constraints

- PEGS 固定为 commit `043a69d6ad272affda6efdc40990ad3140899c63`；不得跟随浮动 `main`。
- 公司流程图显式参数优先于 PEGS；PEGS 参数优先于软件默认值。
- fastp 固定基础参数为 `-n 0 -q 20 -f 3 -F 3 -t 3 -T 3`；当前 `FASTP_POLICY_STATUS=blocked`，未经用户明确批准不得开始九样本正式运行。
- StringTie 单样本必须使用 run-local `S1.genome.gff` 副本作为 `-G` guide；不添加 `-e`、`-t`、`--rf` 或 `--fr`。
- transcript preparation 顺序固定为 `gffread -> cd-hit-est 0.98 -> PEGS rename_id.py -> SeqClean UniVec`。
- PASA alignment 固定使用 minimap2，阈值为 aligned 75、identity 85、perfect splice boundary 0、subcluster 50。
- PASA update 固定只执行一轮，使用 alignment SQLite 的独立副本和同一份 clean transcript FASTA。
- AGAT 固定为 `agat_sp_keep_longest_isoform.pl` 0.8.0。
- 原始 FASTQ 仅允许 fastp 读取；FASTA/GFF 必须先复制或 reflink 到 run-local `reference/`。
- 公司 `S1.genome_new.gff3` 只用于 compare 阶段，不得出现在 fastp、STAR、StringTie、transcript preparation 或 PASA 命令中。
- 不覆盖已有文件，不清空 attempt，不使用删除命令；失败产物保留或移动到 run-local `trash/`。
- `work/`、`logs/`、`results/`、`trash/`、第三方工具、数据库和大过程文件必须由 `tss/.gitignore` 屏蔽。
- 所有 Python 调用必须通过 `tss/tools/pegs/env` 的 conda prefix；不使用 base 或系统 Python。
- 长时间正式任务使用 `nohup bash ... >log 2>&1 &`，保存 PID、命令、开始时间和日志路径。
- 每个任务先写失败测试，再实现，再运行 focused tests，再提交；提交信息使用中文。

---

## 0. Current Baseline and Supersession

### 0.1 已完成并保留

| 范围 | 提交 | 状态 |
| --- | --- | --- |
| 旧设计与首次实施计划 | `ad54836` | 已归档，设计结论被 PEGS 新证据替代 |
| 配置、样本表、ignore 契约 | `fbc9b68`、`749446d` | 保留，Task 1 扩展 |
| run layout、状态与失败隔离 | `334d6e2`、`1c014b1`、`a1db0f4` | 保留，Task 3 修正 marker 原子性 |
| 初版 preflight | `f322fdc` | 未通过独立审查，Task 3 修复后才算完成 |

旧 `implementation_plan.md` 已移至 `archive/implementation_plan_pre_pegs_20260710.md`。旧 Task 4-14 不再执行，尤其废止 GMAP+BLAT alignment 和 90/95 PASA 过滤阈值。

### 0.2 Canonical File Map

```text
tss/tss_utr_reproduction_20260710/
├── README.md
├── design.md
├── implementation_plan.md
├── archive/
├── config/
│   ├── pipeline.env
│   ├── samples.tsv
│   ├── pegs_sources.sha256
│   ├── toolchain.expected.tsv
│   ├── toolchain.lock.tsv
│   ├── pegs_alignAssembly.config.in
│   └── pegs_annotCompare.config.in
├── scripts/
│   ├── install_pegs_toolchain.sh
│   ├── build_safe_seqclean.sh
│   ├── verify_toolchain.sh
│   ├── preflight.sh
│   ├── snapshot_inputs.sh
│   ├── check_fastq_pairs.pl
│   ├── check_fastp_json.pl
│   ├── run_fastp.sh
│   ├── filter_reference.pl
│   ├── run_star.sh
│   ├── parse_star_logs.pl
│   ├── estimate_strandedness.pl
│   ├── run_stringtie.sh
│   ├── validate_gtf.pl
│   ├── prepare_pegs_transcripts.sh
│   ├── check_fasta.pl
│   ├── summarize_seqclean.pl
│   ├── render_pasa_configs.sh
│   ├── run_pasa_align.sh
│   ├── check_pasa_db.pl
│   ├── run_pasa_update.sh
│   ├── parse_pasa_updates.pl
│   ├── run_agat_finalize.sh
│   ├── compare_annotations.pl
│   ├── export_candidate_tss.pl
│   ├── postflight.sh
│   ├── run_pipeline.sh
│   └── lib/common.sh
└── tests/
```

### 0.3 Stage Interfaces

| Script | Consumes | Produces |
| --- | --- | --- |
| `preflight.sh` | config、tool lock、samples、原始输入 | run-local reference、input manifest、`preflight.done` |
| `run_fastp.sh` | 9 对原始 FASTQ | clean FASTQ、JSON/HTML、`fastp_summary.tsv` |
| `run_star.sh` | clean FASTQ、reference copy | index、9 BAM、bedGraph、STAR metrics |
| `run_stringtie.sh` | 9 BAM、GFF guide | 9 GTF、strict merge list、merged GTF |
| `prepare_pegs_transcripts.sh` | merged GTF、genome | raw/dedup/renamed/clean FASTA、ID map、SeqClean report |
| `run_pasa_align.sh` | unclean/clean FASTA、genome | alignment SQLite、assemblies、alignment metrics |
| `run_pasa_update.sh` | alignment DB copy、clean FASTA、old GFF | PASA updated GFF3、update events |
| `run_agat_finalize.sh` | PASA updated GFF3 | longest/normalized/final GFF3 |
| `compare_annotations.pl` | final GFF3、company GFF3 | feature/ID/coordinate/event comparison |
| `export_candidate_tss.pl` | final GFF3 | candidate UTR/TSS TSV |

---

### Task 1: Replace Configuration Contracts with PEGS-Aware Contracts

**Files:**
- Modify: `tss/tss_utr_reproduction_20260710/config/pipeline.env`
- Create: `tss/tss_utr_reproduction_20260710/config/pegs_sources.sha256`
- Create: `tss/tss_utr_reproduction_20260710/config/toolchain.expected.tsv`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh`

**Interfaces:**
- Consumes: current absolute project paths and `design.md` source lock.
- Produces: sourceable config with exact PEGS/tool paths and an expected toolchain contract used by installer and preflight.

- [ ] **Step 1: Extend the failing config test**

Add assertions for exact values:

```text
PEGS_COMMIT=043a69d6ad272affda6efdc40990ad3140899c63
PEGS_SOURCE=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pegs/source
PEGS_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pegs/env
GFFREAD_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/gffread/env
CDHIT_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/cd-hit/env
BLAST_LEGACY_PREFIX=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/blast-legacy/env
SEQCLEAN_SAFE_DIR=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pegs/seqclean-safe
UNIVEC_DIR=/data/p252701008/projects/multi-omics-data-pipelines/tss/tools/pegs/data/univec
FASTP_POLICY_STATUS=blocked
FASTP_MAX_N=0
FASTP_QUAL=20
FASTP_TRIM_FRONT=3
FASTP_TRIM_TAIL=3
STRINGTIE_USE_GUIDE=1
CDHIT_IDENTITY=0.98
PASA_ALIGNER=minimap2
PASA_MIN_PERCENT_ALIGNED=75
PASA_MIN_AVG_PER_ID=85
PASA_PERFECT_SPLICE_BP=0
PASA_SUBCLUSTER_OVERLAP=50
MIN_FREE_GB=300
```

Test that paths are absolute, numeric values are strict decimal integers except `CDHIT_IDENTITY`, `FASTP_POLICY_STATUS` is `blocked|approved`, and `FASTP_MAX_N` cannot be nonzero while status is blocked. Require obsolete inference keys `STAR_GENOME_SA_INDEX_NBASES`, `PASA_MAX_INTRON_LENGTH` and `PASA_TOP_ALIGNMENTS` to be absent; PEGS leaves those values at fixed-tool defaults.

- [ ] **Step 2: Run the test and confirm RED**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
```

Expected: FAIL on missing `PEGS_COMMIT` or `FASTP_TRIM_FRONT`.

- [ ] **Step 3: Add source hashes and expected toolchain rows**

`pegs_sources.sha256` must contain exactly:

```text
be7a5c745ceb2f57de28b61eb1b9990070990550f30792dfdb34091879164806  pegs/rnaseq2gene.py
a477bf8500f043b4bd26f5c9df3732835a9bfaf2db7d8f182d2c6091c5c806c3  pegs/add_utr.py
283e92a035f062bdc886700f80dc4482b6751f5424d0638e366c3e6a14eaf8cd  pegs/config.py
e720401f15015aa1d4dbc9fc08d7711a8ac2f357f038a382d004e0d6c38d614a  scripts/rename_pasa_gtf.py
```

`toolchain.expected.tsv` columns and rows:

```text
component	expected_version	provider
pegs	043a69d6ad272affda6efdc40990ad3140899c63	github
python	3.11	conda-forge
fastp	0.23.1	bioconda
STAR	2.7.9a	bioconda
stringtie	2.2.0	bioconda
gffread	0.12.7	bioconda
cd-hit	4.8.1	bioconda
blast-legacy	2.2.26	bioconda
pasa	2.5.2	bioconda
minimap2	2.31	bioconda
samtools	1.23.1	bioconda
sqlite	3.53.3	conda-forge
transdecoder	6.0.0	bioconda
agat	0.8.0	bioconda
```

- [ ] **Step 4: Update `pipeline.env` and pass tests**

Preserve existing resource/sample/run keys, add the exact keys above, and keep the production policy blocked.

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
bash -n tss/tss_utr_reproduction_20260710/config/pipeline.env
```

Expected: `[PASS] config contracts` and no syntax output.

- [ ] **Step 5: Commit**

```bash
git add tss/tss_utr_reproduction_20260710/config tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
git commit -m "config(tss): 切换为PEGS兼容工具链契约"
```

---

### Task 2: Install and Lock the PEGS Supplemental Toolchain

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/install_pegs_toolchain.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/build_safe_seqclean.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/verify_toolchain.sh`
- Create: `tss/tss_utr_reproduction_20260710/config/toolchain.lock.tsv`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_toolchain_contract.sh`
- Modify: `tss/.gitignore` only if any new tool/data path is not already ignored.

**Interfaces:**
- Consumes: Task 1 config, current five installed tools, network during installation.
- Produces: pinned PEGS source, four independent prefixes/data roots, safe SeqClean scripts, actual binary/source lock.

- [ ] **Step 1: Write the failing toolchain test**

Test that installer text contains exact versions and never contains a deletion command; test that verification rejects a fake PEGS commit and a modified `rnaseq2gene.py`; test that all created tool paths fall under `tss/tools/` and are ignored by Git.

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_toolchain_contract.sh
```

Expected: FAIL because installer and verifier do not exist.

- [ ] **Step 2: Implement no-overwrite installation**

The installer must fail if a target prefix exists but does not pass verification. For absent paths, execute exact environment creation semantics:

```bash
conda create -y -p "$PEGS_PREFIX" -c conda-forge --strict-channel-priority python=3.11
conda create -y -p "$GFFREAD_PREFIX" -c conda-forge -c bioconda --strict-channel-priority gffread=0.12.7
conda create -y -p "$CDHIT_PREFIX" -c conda-forge -c bioconda --strict-channel-priority cd-hit=4.8.1
conda create -y -p "$BLAST_LEGACY_PREFIX" -c conda-forge -c bioconda --strict-channel-priority blast-legacy=2.2.26
git clone https://github.com/zxgsy520/pegs.git "$PEGS_SOURCE"
git -C "$PEGS_SOURCE" switch --detach "$PEGS_COMMIT"
```

Download NCBI `UniVec` and `UniVec_Core` to unique temporary names under `$UNIVEC_DIR`, calculate SHA-256, and publish only when final names do not exist. Never replace an existing database snapshot. From `$UNIVEC_DIR`, build the legacy BLAST nucleotide indexes required by SeqClean:

```bash
run_conda "$BLAST_LEGACY_PREFIX" formatdb -p F -i "$UNIVEC_DIR/UniVec"
run_conda "$BLAST_LEGACY_PREFIX" formatdb -p F -i "$UNIVEC_DIR/UniVec_Core"
```

Require `.nhr`, `.nin` and `.nsq` sidecars for both databases; do not rebuild an existing indexed snapshot.

- [ ] **Step 3: Build safe SeqClean from locked PASA sources**

Require these source hashes before transformation:

```text
0c00c7c3074690bd9c8d544b4c59234c789ea38ac19658dbb73104c94a4cee98  seqclean
22e46caa69c2964984472beca7022a69f798469f65fed086c7cee02637540178  seqclean.psx
```

Create new safe files without modifying the PASA installation:

```bash
sed '75d;127d' "$PASA_HOME/bin/seqclean" > "$SEQCLEAN_SAFE_DIR/seqclean"
sed '151d;213d;246d' "$PASA_HOME/bin/seqclean.psx" > "$SEQCLEAN_SAFE_DIR/seqclean.psx"
chmod 0755 "$SEQCLEAN_SAFE_DIR/seqclean" "$SEQCLEAN_SAFE_DIR/seqclean.psx"
```

Verify the safe copies contain neither Perl file-unlink calls nor an external recursive-cleanup invocation. These removed lines only clean previous/log/intermediate files; all intermediates remain in unique attempts.

- [ ] **Step 4: Implement actual lock generation**

`verify_toolchain.sh --write-lock config/toolchain.lock.tsv` writes columns:

```text
component	version	entrypoint	sha256	source
```

It must include PEGS commit plus the four source hashes, Python, five main tools, gffread, CD-HIT, blast-legacy, safe SeqClean scripts, both UniVec FASTA files and all six legacy BLAST index sidecars, minimap2, samtools, SQLite and TransDecoder. Sort rows by component and write through an atomic no-overwrite helper.

- [ ] **Step 5: Run real functional probes**

```bash
bash tss/tss_utr_reproduction_20260710/scripts/install_pegs_toolchain.sh
bash tss/tss_utr_reproduction_20260710/scripts/verify_toolchain.sh --check-lock tss/tss_utr_reproduction_20260710/config/toolchain.lock.tsv
conda run --no-capture-output -p "$PEGS_PREFIX" python "$PEGS_SOURCE/pegs/rnaseq2gene.py" --help
conda run --no-capture-output -p "$PEGS_PREFIX" python "$PEGS_SOURCE/pegs/add_utr.py" --help
```

Expected: exact lock match and both PEGS help calls exit 0. Functional use of PEGS orchestration is not implied.

- [ ] **Step 6: Run focused tests and commit tracked files**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_toolchain_contract.sh
git check-ignore tss/tools/pegs/source/pegs/add_utr.py
git diff --check
git add tss/.gitignore tss/tss_utr_reproduction_20260710/scripts/install_pegs_toolchain.sh tss/tss_utr_reproduction_20260710/scripts/build_safe_seqclean.sh tss/tss_utr_reproduction_20260710/scripts/verify_toolchain.sh tss/tss_utr_reproduction_20260710/config/toolchain.lock.tsv tss/tss_utr_reproduction_20260710/tests/test_toolchain_contract.sh
git commit -m "build(tss): 锁定PEGS及补充依赖"
```

---

### Task 3: Repair and Extend Preflight

**Files:**
- Modify: `tss/tss_utr_reproduction_20260710/scripts/lib/common.sh`
- Modify: `tss/tss_utr_reproduction_20260710/scripts/preflight.sh`
- Modify: `tss/tss_utr_reproduction_20260710/scripts/snapshot_inputs.sh`
- Modify: `tss/tss_utr_reproduction_20260710/scripts/check_fastq_pairs.pl`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_common.sh`
- Modify: `tss/tss_utr_reproduction_20260710/tests/test_preflight.sh`

**Interfaces:**
- Consumes: Task 1 config, Task 2 lock, samples and immutable resources.
- Produces: accepted `preflight.done` only after all input/tool/reference gates pass.

- [ ] **Step 1: Add RED tests for the five review findings**

Cover exact failures:

1. `MIN_FREE_GB=299` is rejected before `df` result can pass; `300` is accepted when fake free space equals 300 GiB.
2. wrong minimap2/samtools/SQLite/TransDecoder/PEGS version or hash is rejected.
3. forced output-hash failure leaves no final marker.
4. MD5 file beside another same-basename FASTQ cannot validate the samples.tsv path.
5. plain text named `.gz`, truncated gzip trailer and CRC corruption are rejected.

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_common.sh
bash tss/tss_utr_reproduction_20260710/tests/test_preflight.sh
```

Expected: at least one new assertion fails on the current `f322fdc` implementation.

- [ ] **Step 2: Make stage markers failure-atomic**

`mark_stage_done STAGE OUTPUT...` must:

1. calculate config/tool/input/output hashes before opening the marker destination;
2. write a unique run-local temporary marker;
3. flush and close successfully;
4. publish with `rename_noreplace`;
5. leave no final marker on any failure.

Extend `stage_is_complete` to require `toolchain_lock_sha256`.

- [ ] **Step 3: Enforce the fixed 300 GiB floor and exact tool lock**

Reject configured values below 300:

```bash
(( MIN_FREE_GB >= 300 )) || die "MIN_FREE_GB must be at least 300"
required_kb=$((MIN_FREE_GB * 1024 * 1024))
```

Call `verify_toolchain.sh --check-lock` before large input scanning. Do not merely record package versions.

- [ ] **Step 4: Verify actual FASTQ paths and strict gzip streams**

Parse each `.md5` as one expected digest plus basename, require basename match, then calculate MD5 directly on the samples.tsv absolute FASTQ path. Do not invoke checksum verification from the checksum file directory.

Open gzip streams with:

```perl
IO::Uncompress::Gunzip->new($path, Transparent => 0, Strict => 1, MultiStream => 1)
```

Check read errors and `close()` status for both mates after the final record.

- [ ] **Step 5: Extend reference/PEGS preflight**

Verify the PEGS commit and `pegs_sources.sha256`; verify UniVec and safe SeqClean hashes from tool lock; preserve existing 10,370-gene and GFF/FASTA coordinate checks. Blocked `smoke/full` must still exit 42 before run layout, tool invocation, MD5 or FASTQ scanning.

- [ ] **Step 6: Run tests, real blocked probe, and re-review**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_common.sh
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
bash tss/tss_utr_reproduction_20260710/tests/test_toolchain_contract.sh
bash tss/tss_utr_reproduction_20260710/tests/test_preflight.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/preflight.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/check_fastq_pairs.pl
```

Expected: all PASS; real blocked probe exits 42 and creates no run directories. Obtain an independent read-only review of `a1db0f4..HEAD`; resolve every High/Medium finding before completion.

- [ ] **Step 7: Commit**

```bash
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests
git commit -m "fix(tss): 收紧PEGS预检与输入完整性门禁"
```

---

### Task 4: Implement PEGS-Compatible fastp with an Exact-Mode Gate

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/check_fastp_json.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/fastp_zero.json`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/fastp_pass.json`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_fastp_gate.sh`

**Interfaces:**
- Consumes: approved fastp policy, samples.tsv and original FASTQ.
- Produces: 9 sample directories, clean paired FASTQ, JSON/HTML, `fastp_summary.tsv`, `fastp.done`.

- [ ] **Step 1: Write JSON and command-contract RED tests**

Require TSV columns:

```text
sample	input_reads	output_reads	input_pairs	output_pairs	pass_fraction	q20_rate	q30_rate	gc_content	too_many_n_reads
```

Reject zero output, odd read count, input/output pair mismatch and pass fraction below 0.50. Require `run_fastp.sh` to include `-n`, `-q`, `-f`, `-F`, `-t`, `-T`, JSON and HTML. Smoke mode may add only `--reads_to_process 50000`.

- [ ] **Step 2: Confirm RED**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_fastp_gate.sh
```

Expected: FAIL because parser/runner do not exist.

- [ ] **Step 3: Implement the exact command**

For each S1-S9:

```bash
run_conda "$FASTP_PREFIX" fastp \
  --in1 "$R1" --in2 "$R2" \
  --out1 "$ATTEMPT/clean_R1.fastq.gz" \
  --out2 "$ATTEMPT/clean_R2.fastq.gz" \
  --thread "$THREADS" \
  -n "$FASTP_MAX_N" -q "$FASTP_QUAL" \
  -f "$FASTP_TRIM_FRONT" -F "$FASTP_TRIM_FRONT" \
  -t "$FASTP_TRIM_TAIL" -T "$FASTP_TRIM_TAIL" \
  --json "$ATTEMPT/fastp.json" \
  --html "$ATTEMPT/fastp.html"
```

Reject any call unless `FASTP_POLICY_STATUS=approved`, except `--company-exact-audit`, which is limited to 50,000 pairs and cannot publish `fastp.done`.

- [ ] **Step 4: Validate and publish outputs**

Require both files nonempty, strict gzip integrity, equal pair counts, JSON gate pass and no pre-existing final sample output. Publish sample outputs only after all sample checks pass; publish stage marker after all nine summaries exist.

- [ ] **Step 5: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_fastp_gate.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/check_fastp_json.pl
git add tss/tss_utr_reproduction_20260710/scripts/check_fastp_json.pl tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh tss/tss_utr_reproduction_20260710/tests
git commit -m "feat(tss): 增加PEGS版fastp与非空门禁"
```

---

### Task 5: Implement Reference Filtering and STAR

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/filter_reference.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_star.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/parse_star_logs.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/estimate_strandedness.pl`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_star_stage.sh`

**Interfaces:**
- Consumes: reference copy and 9 fastp sample outputs.
- Produces: filtered reference, STAR index, 9 sorted BAM/bedGraph/log sets, STAR and strandedness summaries.

- [ ] **Step 1: Write RED tests**

Test FASTA fixture filtering at 1,999/2,000 bp; reject duplicate IDs and empty output. Require STAR index to use filtered run-local FASTA and mapping commands to contain `zcat`, `bedGraph`, `SortedByCoordinate` and `intronMotif`; reject resource paths and unapproved options.

- [ ] **Step 2: Implement deterministic PEGS 2 kb filtering**

`filter_reference.pl --min-length 2000 INPUT OUTPUT REPORT` streams records, preserves header/sequence bytes for retained contigs and writes `seqid length retained`. For S1, require 86 retained, 0 removed and filtered SHA-256 equal to reference-copy SHA-256.

- [ ] **Step 3: Implement STAR index and per-sample mapping**

Index:

```bash
run_conda "$STAR_PREFIX" STAR \
  --runMode genomeGenerate \
  --genomeDir "$RUN_ROOT/star/index" \
  --genomeFastaFiles "$RUN_ROOT/reference/S1.genome.filtered.fasta" \
  --runThreadN "$THREADS"
```

Mapping:

```bash
run_conda "$STAR_PREFIX" STAR \
  --runThreadN "$THREADS" \
  --genomeDir "$RUN_ROOT/star/index" \
  --readFilesIn "$CLEAN_R1" "$CLEAN_R2" \
  --readFilesCommand zcat \
  --outWigType bedGraph \
  --outSAMtype BAM SortedByCoordinate \
  --outSAMstrandField intronMotif \
  --outFileNamePrefix "$ATTEMPT/"
```

- [ ] **Step 4: Add BAM and metric gates**

Use PASA-prefix samtools for `quickcheck`, header contig match and mapped read count. Parse STAR `Log.final.out` into exact numeric columns. Estimate strandedness from up to 1,000,000 informative R1 alignments, report only; never alter StringTie flags.

- [ ] **Step 5: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_star_stage.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_star.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/filter_reference.pl
perl -c tss/tss_utr_reproduction_20260710/scripts/parse_star_logs.pl
perl -c tss/tss_utr_reproduction_20260710/scripts/estimate_strandedness.pl
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests/test_star_stage.sh
git commit -m "feat(tss): 增加PEGS参考过滤与STAR比对"
```

---

### Task 6: Implement Guided Per-Sample StringTie and Strict Nine-Sample Merge

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/validate_gtf.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_stringtie.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_stringtie_stage.sh`

**Interfaces:**
- Consumes: 9 STAR BAM and run-local GFF guide.
- Produces: 9 validated GTF, `merge.list`, `S1.merged.gtf`, `stringtie_summary.tsv`.

- [ ] **Step 1: Write RED command and merge-list tests**

Require nine separate StringTie invocations, each with `-G "$RUN_ROOT/reference/S1.genome.gff"`; forbid `-e`, `-t`, `--rf`, `--fr`; require S1-S9 exact order and exactly nine newline-terminated absolute GTF paths.

- [ ] **Step 2: Implement single-sample assembly**

```bash
run_conda "$STRINGTIE_PREFIX" stringtie "$BAM" \
  -G "$RUN_ROOT/reference/S1.genome.gff" \
  -o "$ATTEMPT/$SAMPLE.stringtie.gtf" \
  -p "$THREADS"
```

`validate_gtf.pl` checks nine columns, transcript/exon presence, transcript_id/gene_id, reference seqid and coordinate bounds.

- [ ] **Step 3: Implement the union**

Generate the strict list from samples.tsv, not a glob. Then:

```bash
run_conda "$STRINGTIE_PREFIX" stringtie --merge \
  -p "$THREADS" \
  -o "$ATTEMPT/S1.merged.gtf" \
  "$ATTEMPT/merge.list"
```

Validate merged transcript count greater than 0 and record per-sample/merged gene, transcript and exon counts.

- [ ] **Step 4: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_stringtie_stage.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_stringtie.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/validate_gtf.pl
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests/test_stringtie_stage.sh
git commit -m "feat(tss): 增加引导式StringTie九样本并集"
```

---

### Task 7: Implement PEGS Transcript Preparation

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/check_fasta.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/summarize_seqclean.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/prepare_pegs_transcripts.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/transcripts.gtf`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/transcripts.genome.fa`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/vector.fa`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_transcript_prepare.sh`

**Interfaces:**
- Consumes: merged GTF, filtered genome, PEGS source, gffread/CD-HIT/legacy BLAST/safe SeqClean/UniVec.
- Produces: raw, deduplicated, renamed and clean FASTA; CD-HIT cluster; rename map/log; SeqClean report/metrics.

- [ ] **Step 1: Write RED end-to-end fixture test**

Fixture must contain two duplicate transcripts, one unique transcript, one vector-contaminated terminal segment and one short/low-complexity case. Build a run-local legacy BLAST index for the vector fixture, then assert deterministic counts through each step and `transngs1..N` IDs. Assert all outputs remain in a unique attempt and no source/input file changes.

- [ ] **Step 2: Implement GTF-to-FASTA and CD-HIT**

```bash
run_conda "$GFFREAD_PREFIX" gffread \
  -w "$ATTEMPT/S1.transcript.fasta" \
  -g "$RUN_ROOT/reference/S1.genome.filtered.fasta" \
  "$RUN_ROOT/stringtie/S1.merged.gtf"

run_conda "$CDHIT_PREFIX" cd-hit-est \
  -i "$ATTEMPT/S1.transcript.fasta" \
  -o "$ATTEMPT/S1.unitranscript.fasta" \
  -c 0.98 -d 0 -T "$THREADS" -M 64000
```

Record that `0.98` is the syntax correction for PEGS `0.98b`.

- [ ] **Step 3: Use the pinned PEGS ID-renaming script**

```bash
run_conda "$PEGS_PREFIX" python \
  "$PEGS_SOURCE/scripts/rename_id.py" \
  "$ATTEMPT/S1.unitranscript.fasta" \
  -p transngs \
  > "$ATTEMPT/trans.rename.fasta" \
  2> "$ATTEMPT/rename_id.log"
```

Parse the log into `rename_id_map.tsv`; require one-to-one rows and sequential IDs.

- [ ] **Step 4: Run safe SeqClean with both NCBI databases**

Run from `$ATTEMPT/seqclean/` with PATH ordered as safe scripts, PASA binaries, legacy BLAST, then inherited PATH:

```bash
PATH="$SEQCLEAN_SAFE_DIR:$PASA_HOME/bin:$BLAST_LEGACY_PREFIX/bin:$PATH" \
  "$SEQCLEAN_SAFE_DIR/seqclean" \
  "$ATTEMPT/trans.rename.fasta" \
  -c "$THREADS" \
  -v "$UNIVEC_DIR/UniVec_Core,$UNIVEC_DIR/UniVec"
```

Move no files during execution; publish the clean FASTA and report only after checks. Retain all SeqClean intermediates.

- [ ] **Step 5: Add FASTA and report gates**

`check_fasta.pl` validates unique IDs, `[ACGTNacgtn]+`, nonempty sequence and length distribution. `summarize_seqclean.pl` reports valid, trashed, trimmed and reason counts. Require clean IDs to be a subset of renamed IDs and at least one clean transcript.

- [ ] **Step 6: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_transcript_prepare.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/prepare_pegs_transcripts.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/check_fasta.pl
perl -c tss/tss_utr_reproduction_20260710/scripts/summarize_seqclean.pl
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests
git commit -m "feat(tss): 增加PEGS转录本去冗余与清洗"
```

---

### Task 8: Render Exact PEGS/PASA Configurations

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/config/pegs_alignAssembly.config.in`
- Create: `tss/tss_utr_reproduction_20260710/config/pegs_annotCompare.config.in`
- Create: `tss/tss_utr_reproduction_20260710/scripts/render_pasa_configs.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_pasa_configs.sh`

**Interfaces:**
- Consumes: absolute attempt SQLite path.
- Produces: alignment and annotation config with no unresolved token.

- [ ] **Step 1: Write RED rendering tests**

Require absolute SQLite path, exact key/value set, no `<__...__>` or `@DATABASE@`, no GMAP/BLAT settings, no `PASA_ADMIN_EMAIL`/`PASA_ADMIN_DB`, and no explicit `MIN_FL_ORF_SIZE`, `TRUST_FL_STATUS` or `STOMP_HIGH_PERCENTAGE_OVERLAPPING_GENE`.

- [ ] **Step 2: Create the alignment template**

```text
DATABASE=@DATABASE@
validate_alignments_in_db.dbi:--MIN_PERCENT_ALIGNED=75
validate_alignments_in_db.dbi:--MIN_AVG_PER_ID=85
validate_alignments_in_db.dbi:--NUM_BP_PERFECT_SPLICE_BOUNDARY=0
subcluster_builder.dbi:-m=50
```

- [ ] **Step 3: Create the annotation template**

```text
DATABASE=@DATABASE@
RUN_TRANS_DECODER=1
cDNA_annotation_comparer.dbi:--MIN_PERCENT_OVERLAP=50
cDNA_annotation_comparer.dbi:--MIN_PERCENT_PROT_CODING=40
cDNA_annotation_comparer.dbi:--MIN_PERID_PROT_COMPARE=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_LENGTH_FL_COMPARE=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_LENGTH_NONFL_COMPARE=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_ALIGN_LENGTH=70
cDNA_annotation_comparer.dbi:--MIN_PERCENT_OVERLAP_GENE_REPLACE=80
cDNA_annotation_comparer.dbi:--MAX_UTR_EXONS=2
cDNA_annotation_comparer.dbi:--GENETIC_CODE=universal
```

- [ ] **Step 4: Implement safe rendering, test and commit**

Reject relative DB paths and existing destinations. Replace exactly one token and verify source template SHA before rendering.

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_pasa_configs.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/render_pasa_configs.sh
git add tss/tss_utr_reproduction_20260710/config/pegs_* tss/tss_utr_reproduction_20260710/scripts/render_pasa_configs.sh tss/tss_utr_reproduction_20260710/tests/test_pasa_configs.sh
git commit -m "feat(tss): 固定PEGS版PASA配置"
```

---

### Task 9: Implement PASA Alignment Assembly with minimap2

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/check_pasa_db.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_pasa_align.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_pasa_align.sh`

**Interfaces:**
- Consumes: renamed unclean FASTA, SeqClean FASTA, filtered genome and alignment config.
- Produces: immutable alignment attempt with SQLite, assemblies and metrics.

- [ ] **Step 1: Write RED safety/command tests**

Require full PASA launcher path, `-C -R -T`, separate `-u`/`-t`, `--ALIGNERS minimap2`, no GMAP/BLAT, run-local genome and CWD, and no company GFF3. Reject an existing DB destination.

- [ ] **Step 2: Implement first-attempt command**

```bash
run_conda "$PASA_PREFIX" "$PASA_HOME/Launch_PASA_pipeline.pl" \
  -c "$ATTEMPT/pegs_alignAssembly.config" \
  -C -R \
  -g "$RUN_ROOT/reference/S1.genome.filtered.fasta" \
  -T \
  -u "$RUN_ROOT/transcript_prepare/trans.rename.fasta" \
  -t "$RUN_ROOT/transcript_prepare/trans.rename.fasta.clean" \
  --CPU "$THREADS" \
  --ALIGNERS minimap2
```

Run with CWD `$ATTEMPT`. A retry creates a new attempt seeded only from immutable upstream inputs; it never modifies a prior attempt.

- [ ] **Step 3: Implement database and assembly gates**

`check_pasa_db.pl` calls run-local SQLite and requires `PRAGMA quick_check` result `ok`, tables `cdna_info`, `alignment`, `align_link`, `clusters`, `asmbl_link`, nonzero valid alignments and assemblies, and clean transcript IDs represented in DB or classified with an explicit failure reason.

Require nonempty `*.pasa_assemblies.gff3` and `*.pasa_assemblies.gtf`; validate their seqids and coordinates.

- [ ] **Step 4: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_pasa_align.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_pasa_align.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/check_pasa_db.pl
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests/test_pasa_align.sh
git commit -m "feat(tss): 增加minimap2版PASA比对数据库"
```

---

### Task 10: Implement PASA Annotation Compare and UTR Update

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/parse_pasa_updates.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_pasa_update.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_pasa_update.sh`

**Interfaces:**
- Consumes: accepted alignment SQLite, clean transcript FASTA, original GFF/genome copies, rendered configs.
- Produces: independent update SQLite, unique updated GFF3 and event summary.

- [ ] **Step 1: Write RED isolation tests**

Assert update DB path differs from alignment DB; alignment DB hash is unchanged; both configs point to update DB; old GFF is run-local; company GFF3 absent; only one `-A` run; output discovery is limited to files created by the current attempt.

- [ ] **Step 2: Seed the update attempt without overwrite**

Use `cp --reflink=auto` to a new destination, then byte-compare and hash. Render both configs against the copied DB. Record source alignment DB hash before and after update.

- [ ] **Step 3: Load the old annotation**

```bash
run_conda "$PASA_PREFIX" \
  "$PASA_HOME/scripts/Load_Current_Gene_Annotations.dbi" \
  -c "$ATTEMPT/pegs_alignAssembly.config" \
  -g "$RUN_ROOT/reference/S1.genome.filtered.fasta" \
  -P "$RUN_ROOT/reference/S1.genome.gff"
```

Require 10,370 loaded genes before update.

- [ ] **Step 4: Run one annotation update**

```bash
run_conda "$PASA_PREFIX" "$PASA_HOME/Launch_PASA_pipeline.pl" \
  --CPU "$THREADS" \
  -c "$ATTEMPT/pegs_annotCompare.config" \
  -A \
  -g "$RUN_ROOT/reference/S1.genome.filtered.fasta" \
  -t "$RUN_ROOT/transcript_prepare/trans.rename.fasta.clean"
```

Find exactly one current-attempt `*.gene_structures_post_PASA_updates.*.gff3`; publish it as `S1.pasa.updated.gff3` only after structure validation.

- [ ] **Step 5: Parse update events**

Report unchanged, UTR extension, exon adjustment, CDS change, merge, split, novel and rejected events with original/new IDs. Require updated GFF3 gene/mRNA presence and all Parent references resolvable.

- [ ] **Step 6: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_pasa_update.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_pasa_update.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/parse_pasa_updates.pl
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests/test_pasa_update.sh
git commit -m "feat(tss): 增加PASA注释比较与UTR更新"
```

---

### Task 11: Implement AGAT Finalization, Comparison and Candidate TSS Export

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_agat_finalize.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/compare_annotations.pl`
- Create: `tss/tss_utr_reproduction_20260710/scripts/export_candidate_tss.pl`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/annotation_old.gff3`
- Create: `tss/tss_utr_reproduction_20260710/tests/fixtures/annotation_new.gff3`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_finalize_compare.sh`

**Interfaces:**
- Consumes: PASA updated GFF3, genome copy and company target at compare time.
- Produces: final GFF3, structural comparison TSV/Markdown and candidate TSS/UTR TSV.

- [ ] **Step 1: Write RED structural tests**

Fixtures cover positive/negative strand TSS, multi-exon UTR, attribute-order-only difference, feature-order-only difference, changed CDS, gene merge and 1-3 bp UTR. Require format-only differences not counted as structural mismatch.

- [ ] **Step 2: Implement AGAT longest-isoform and normalization**

```bash
run_conda "$AGAT_PREFIX" agat_sp_keep_longest_isoform.pl \
  --gff "$RUN_ROOT/pasa_update/S1.pasa.updated.gff3" \
  --output "$ATTEMPT/S1.longest.gff3"

run_conda "$AGAT_PREFIX" agat_convert_sp_gxf2gxf.pl \
  --gff "$ATTEMPT/S1.longest.gff3" \
  --output "$ATTEMPT/S1.normalized.gff3"
```

Validate structure and publish without overwrite to `results/$RUN_ID/S1.genome_reproduced.gff3`.

- [ ] **Step 3: Implement normalized structural comparison**

Parse GFF3 into normalized records keyed by feature type, seqid, strand, start/end, ID and Parent. Emit feature counts, ID overlap, coordinate exact match, boundary deltas, merge/split candidates, UTR lengths and short UTR counts. Keep raw line/attribute ordering in a separate format-difference section.

- [ ] **Step 4: Export candidate TSS**

For each mRNA, emit:

```text
transcript_id	gene_id	seqid	strand	candidate_tss	five_prime_utr_count	five_prime_utr_length	evidence_class
```

Positive strand uses minimum mRNA coordinate; negative strand uses maximum. `evidence_class` is exactly `short_read_rnaseq_candidate`.

- [ ] **Step 5: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_finalize_compare.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_agat_finalize.sh
perl -c tss/tss_utr_reproduction_20260710/scripts/compare_annotations.pl
perl -c tss/tss_utr_reproduction_20260710/scripts/export_candidate_tss.pl
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests
git commit -m "feat(tss): 增加AGAT定稿与候选TSS比较"
```

---

### Task 12: Implement the Stage Driver and Postflight Audit

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/scripts/postflight.sh`
- Create: `tss/tss_utr_reproduction_20260710/scripts/run_pipeline.sh`
- Create: `tss/tss_utr_reproduction_20260710/tests/test_driver.sh`
- Modify: `tss/tss_utr_reproduction_20260710/README.md`

**Interfaces:**
- Consumes: all stage scripts and `--run-id/--mode/--threads/--resume/--stop-after`.
- Produces: ordered execution, resume decisions, final manifest and run status.

- [ ] **Step 1: Write RED driver tests**

Use fake stage executables to verify exact order:

```text
preflight fastp star stringtie transcript_prepare pasa_align pasa_update agat compare postflight
```

Cover new run, stop-after every stage, valid resume, config/tool/input/output hash mismatch, failed prior stage, blocked fastp and existing final result.

- [ ] **Step 2: Implement CLI and stage dispatch**

CLI:

```text
run_pipeline.sh --run-id ID --mode audit|smoke|full --threads N [--resume] [--stop-after STAGE]
```

`audit` ends after preflight/tool checks. `smoke/full` require approved fastp. Driver sources only `pipeline.env`, validates run ID, and calls stage scripts by absolute project path.

- [ ] **Step 3: Implement postflight**

Recompute original manifest and require byte equality with preflight manifest. Validate every marker hash, result path, tool lock and final GFF3. Write `reports/$RUN_ID/run_manifest.tsv` and `run_status.tsv`; publish success only after postflight.

- [ ] **Step 4: Update operator README**

README must show source lock, stage commands, current blocked state, exact stop boundary, output locations, resume rules and the fact that PEGS original scripts are not run directly.

- [ ] **Step 5: Test and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_driver.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/run_pipeline.sh
bash -n tss/tss_utr_reproduction_20260710/scripts/postflight.sh
git add tss/tss_utr_reproduction_20260710/scripts tss/tss_utr_reproduction_20260710/tests/test_driver.sh tss/tss_utr_reproduction_20260710/README.md
git commit -m "feat(tss): 增加PEGS阶段驱动与运行审计"
```

---

### Task 13: Run Full Static Verification and Independent Review

**Files:**
- Modify only files required by validated findings.
- Create: `tss/tss_utr_reproduction_20260710/reports/static_verification.md`

**Interfaces:**
- Consumes: Tasks 1-12 implementation.
- Produces: reviewed implementation ready for the fastp decision gate.

- [ ] **Step 1: Run every focused test**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_config_contracts.sh
bash tss/tss_utr_reproduction_20260710/tests/test_toolchain_contract.sh
bash tss/tss_utr_reproduction_20260710/tests/test_common.sh
bash tss/tss_utr_reproduction_20260710/tests/test_preflight.sh
bash tss/tss_utr_reproduction_20260710/tests/test_fastp_gate.sh
bash tss/tss_utr_reproduction_20260710/tests/test_star_stage.sh
bash tss/tss_utr_reproduction_20260710/tests/test_stringtie_stage.sh
bash tss/tss_utr_reproduction_20260710/tests/test_transcript_prepare.sh
bash tss/tss_utr_reproduction_20260710/tests/test_pasa_configs.sh
bash tss/tss_utr_reproduction_20260710/tests/test_pasa_align.sh
bash tss/tss_utr_reproduction_20260710/tests/test_pasa_update.sh
bash tss/tss_utr_reproduction_20260710/tests/test_finalize_compare.sh
bash tss/tss_utr_reproduction_20260710/tests/test_driver.sh
```

- [ ] **Step 2: Run syntax, ignore and source scans**

Check every `.sh` with `bash -n`, every `.pl` with PASA-prefix Perl `-c`, no banned resource writes, no company target before compare, no old GMAP/BLAT route, and all representative process files ignored.

- [ ] **Step 3: Run functional toolchain smoke**

Use tiny fixtures to invoke fastp, STAR, StringTie, gffread, CD-HIT, PEGS rename script, safe SeqClean, PASA/minimap2 SQLite initialization and AGAT. Record command, exit code, versions, outputs and hashes in `static_verification.md`.

- [ ] **Step 4: Obtain independent code review**

Review the full implementation range against `design.md` with emphasis on data deletion, overwrite, PEGS fidelity, transcript ID continuity, database isolation and target leakage. Fix all High/Medium findings and repeat review until Approved.

- [ ] **Step 5: Commit**

```bash
git add tss/tss_utr_reproduction_20260710
git commit -m "test(tss): 完成PEGS复现流程静态验证"
```

**Stop:** Task 13 is the last task allowed without a new explicit fastp policy decision.

---

### Task 14: Execute the fastp Company-Exact Audit and Decision Gate

**Files:**
- Create under ignored paths: `work/<AUDIT_RUN_ID>/fastp_company_exact/`
- Create: `tss/tss_utr_reproduction_20260710/reports/<AUDIT_RUN_ID>/fastp_decision.md`
- Modify: `tss/tss_utr_reproduction_20260710/config/pipeline.env` only after explicit user approval.

**Interfaces:**
- Consumes: S1-S9 first 50,000 pairs and exact `-n 0 -q 20 -f/F/t/T 3`.
- Produces: nine exact-mode JSON summaries and a decision document; optionally an approved config commit.

- [ ] **Step 1: Run company-exact audit for all nine samples**

```bash
bash tss/tss_utr_reproduction_20260710/scripts/run_fastp.sh \
  --run-id "$AUDIT_RUN_ID" \
  --mode smoke \
  --threads 8 \
  --company-exact-audit
```

This audit cannot publish a stage marker or feed STAR.

- [ ] **Step 2: Write the decision report**

For each sample report input/output pairs, position-9 N fraction, Q20/Q30, too-many-N count and exact command. State whether all outputs are zero after PEGS trim=3.

- [ ] **Step 3: Stop for explicit approval**

Present only evidence and the minimal candidate `FASTP_MAX_N=1`. Do not edit production config until the user explicitly approves a value.

- [ ] **Step 4: If approved, make one isolated config commit**

Change only:

```text
FASTP_POLICY_STATUS=approved
FASTP_MAX_N=1
```

Record approval text/time in `fastp_decision.md`, rerun config tests, then:

```bash
git add tss/tss_utr_reproduction_20260710/config/pipeline.env tss/tss_utr_reproduction_20260710/reports
git commit -m "config(tss): 批准PEGS数据兼容fastp策略"
```

If approval is not given, the reproducibility conclusion is “company-exact pipeline is not executable on the supplied FASTQ,” and Tasks 15-16 do not run.

---

### Task 15: Execute the Nine-Sample Full Run with Stage Reviews

**Files:**
- Create under ignored paths: `work/<FULL_RUN_ID>/`, `logs/<FULL_RUN_ID>/`, `results/<FULL_RUN_ID>/`, `trash/<FULL_RUN_ID>/`
- Create tracked small reports under: `reports/<FULL_RUN_ID>/`

**Interfaces:**
- Consumes: approved policy and reviewed implementation.
- Produces: complete final GFF3 and stage QC reports.

- [ ] **Step 1: Start and review fastp only**

```bash
nohup bash tss/tss_utr_reproduction_20260710/scripts/run_pipeline.sh \
  --run-id "$FULL_RUN_ID" --mode full --threads 16 --stop-after fastp \
  > "tss/tss_utr_reproduction_20260710/logs/$FULL_RUN_ID/driver.fastp.log" 2>&1 &
```

Record PID. Continue only when 9 outputs pass gzip/pair/pass-fraction gates and input manifest is unchanged.

- [ ] **Step 2: Resume through STAR and review**

Resume with `--stop-after star`. Review 9 BAM quickchecks, mapped counts, splice junctions, mismatch rates, bedGraph files, strandedness report and disk use.

- [ ] **Step 3: Resume through StringTie and review**

Resume with `--stop-after stringtie`. Review nine GTF, exact guide path, strict merge list, merged transcript/exon counts and coordinate validity.

- [ ] **Step 4: Resume through transcript preparation and review**

Resume with `--stop-after transcript_prepare`. Review raw/dedup/renamed/clean counts, CD-HIT clusters, one-to-one ID map, SeqClean reasons, UniVec hashes and clean transcript length distribution.

- [ ] **Step 5: Resume through PASA alignment and review**

Resume with `--stop-after pasa_align`. Review minimap2 command, 75/85 thresholds, SQLite quick check, transcript ID continuity, valid/failed alignments and assembly counts.

- [ ] **Step 6: Finish update, AGAT, comparison and postflight**

Resume without `--stop-after`. Require alignment DB hash unchanged, one update round, unique updated GFF3, final structure pass and before/after input manifest equality.

- [ ] **Step 7: Record run completion commit**

Track only small reports and manifests; verify generated GFF3 remains ignored.

```bash
git add tss/tss_utr_reproduction_20260710/reports
git commit -m "data(tss): 记录PEGS九样本复现运行结果"
```

---

### Task 16: Produce the Final Reproduction and Scientific Validation Report

**Files:**
- Create: `tss/tss_utr_reproduction_20260710/reports/<FULL_RUN_ID>/reproduction_report.md`
- Create: `tss/tss_utr_reproduction_20260710/reports/<FULL_RUN_ID>/feature_counts.tsv`
- Create: `tss/tss_utr_reproduction_20260710/reports/<FULL_RUN_ID>/coordinate_comparison.tsv`
- Create: `tss/tss_utr_reproduction_20260710/reports/<FULL_RUN_ID>/candidate_tss.tsv`
- Create: `tss/tss_utr_reproduction_20260710/reports/<FULL_RUN_ID>/utr_summary.tsv`
- Modify: `tss/tss_utr_reproduction_20260710/README.md`

**Interfaces:**
- Consumes: accepted full run and company target.
- Produces: final audit conclusion with known/inferred/hypothesized labels.

- [ ] **Step 1: Assemble provenance and stage QC**

Report input hashes, PEGS commit, tool lock, exact commands, fastp deviation, all stage counts, PASA event summary and AGAT changes.

- [ ] **Step 2: Compare against the company baseline**

Explicitly compare against 10,367 genes, 10,367 mRNAs, 15,477 exons, 15,272 CDS, 3,051 five-prime UTR and 2,922 three-prime UTR. Report exact feature-coordinate matches, boundary deltas, 2,972 known mRNA-boundary changes, 1,957 known CDS changes and the 3 known merge events without treating them as tuning targets.

- [ ] **Step 3: State the scientific conclusion**

Separate:

- reproduced candidate UTR annotations;
- candidate TSS derived from mRNA boundaries;
- differences caused by fastp compatibility, StringTie, transcript cleaning, PASA and AGAT;
- uncertainty from the unknown historical PEGS commit and historical UniVec snapshot;
- evidence that cannot be validated without 5'-end-specific experiments.

- [ ] **Step 4: Update README status and verify report links**

README must point to final GFF3 location, report directory and current result status. All Markdown links must resolve; no ignored large file is staged.

- [ ] **Step 5: Final verification and commit**

```bash
bash tss/tss_utr_reproduction_20260710/tests/test_driver.sh
git diff --check
git status --short
git add tss/tss_utr_reproduction_20260710/README.md tss/tss_utr_reproduction_20260710/reports
git commit -m "docs(tss): 完成PEGS复现与TSS候选验证报告"
```

## Final Acceptance Checklist

- [ ] PEGS source commit and four source hashes match.
- [ ] Five company tools and all PEGS supplemental dependencies pass real calls.
- [ ] Task 3 independent review findings are all closed.
- [ ] No original input or company target changes.
- [ ] 9 samples are processed independently before the strict union.
- [ ] CD-HIT/SeqClean counts and transcript ID mapping are complete.
- [ ] PASA uses minimap2 and the 75/85/0/50 PEGS filters.
- [ ] PASA update uses an independent DB and one annotation round.
- [ ] Final AGAT GFF3 is structurally valid.
- [ ] Every large/intermediate artifact is ignored.
- [ ] Exact-mode fastp failure and any approved deviation are explicit.
- [ ] Candidate TSS is not described as experimentally validated TSS.
- [ ] Final result can be traced to source, config, input, tool and stage hashes.
