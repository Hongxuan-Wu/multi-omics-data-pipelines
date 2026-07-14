# UniProt Operational Hardening Implementation Plan

> Implementation record for the 2026-07-14 UniProt reliability hardening.

**Goal:** Harden the existing UniProt 2026_02 downloader with auditable lifecycle state, complete CLI controls, automatic recovery, progress reporting, explicit failure semantics, and offline fault-injection tests.

**Architecture:** Keep the approved 25-file manifest and the existing no-argument UniRef50 default. Add UniProt-local lifecycle orchestration around the existing manifest, aria2, and verification functions; do not modify `refseq/` or `genomes/common/common.sh`. All real transfer paths remain disabled in tests through local fixtures and a fake aria2 executable.

**Tech Stack:** Bash 5, GNU coreutils, aria2 interface, TSV state files, Markdown reports.

## Global Constraints

- Do not modify any file under `refseq/`.
- Do not modify `genomes/common/common.sh` or change its API.
- Keep all committed changes under `genomes/uniprot/`.
- Do not change the UniProt 2026_02 approved 25-file manifest or its SHA-256 contract.
- Do not start a real UniProt download or write to `/data3` during validation.
- Never delete artifacts; invalid data and partial control artifacts are moved to `trash`.
- Preserve no-argument behavior: select UniRef50 and run the complete download workflow.
- Preserve `--plan-only` as a network-free action.

---

### Task 1: Freeze the operational behavior with failing tests

**Files:**
- Create: `genomes/uniprot/test_operational_contract.sh`
- Create: `genomes/uniprot/tests/fixtures/fake_aria2c.sh`
- Modify: `genomes/uniprot/test_manifest_contract.sh`

**Interfaces:**
- Consumes: `download_uniprot.sh` as an executable and sourceable Bash module.
- Produces: tests for CLI validation, safe paths, state output, read-only verification, locking, error classification, retry/resume, terminal reports, and idempotency.

- [x] **Step 1: Write CLI and lifecycle tests**

Assert that help documents `--verify-only`, `--status`, retry, progress, lock, aria2, disk, root, and manifest options. Assert argument errors exit `2`, blocked preflight errors exit `30`, and missing/corrupt required files in read-only verification exit `20` without moving payloads.

- [x] **Step 2: Write transfer fault-injection tests**

Use `fake_aria2c.sh` to fail the first attempt with a retained `.aria2` sidecar, succeed on the second attempt, and prove the final file is verified. Add an always-fail mode that must produce a repair plan and exit `20` after the configured retry budget.

- [x] **Step 3: Run the new test and verify RED**

Run:

```bash
bash genomes/uniprot/test_operational_contract.sh
```

Expected: FAIL because the lifecycle options and functions do not yet exist.

### Task 2: Add runtime state, traps, locking, and CLI validation

**Files:**
- Modify: `genomes/uniprot/download_uniprot.sh`

**Interfaces:**
- Produces: `write_state`, `write_progress_snapshot`, `write_summary_report`, `acquire_run_lock`, `release_run_lock`, `on_unhandled_error`, `on_signal`, and complete CLI parsing.

- [x] **Step 1: Add early and runtime error traps**

Install an initialization-safe `ERR` trap before sourcing the v1 common library. After runtime initialization, record stage, line, command, exit code, and terminal status without exposing credentials.

- [x] **Step 2: Add state and report paths**

Create per-run state, progress, verification, repair-plan, and summary files plus atomically updated `latest_status.tsv`, `latest_progress.tsv`, and `latest_summary.md` under `RUN_ROOT`.

- [x] **Step 3: Add safe root and lock checks**

Canonicalize roots, reject `/`, equal roots, nested roots, control characters, and unwritable paths. Acquire a nonblocking exclusive lock for mutating download/repair workflows.

- [x] **Step 4: Add CLI controls and exit semantics**

Support `--verify-only`, `--status`, `--summary`, `--download-attempts`, `--retry-wait`, `--progress-interval`, `--lock-wait`, `--connections`, `--max-concurrent`, `--split`, `--min-split-size`, `--aria-max-tries`, `--aria-retry-wait`, `--summary-interval`, and `--min-disk-gb`. Use exits `0`, `2`, `20`, `30`, `130`, and `143` as documented.

- [x] **Step 5: Run the operational tests**

Run `bash genomes/uniprot/test_operational_contract.sh`; expect CLI, path, state, and lock sections to pass while transfer recovery remains RED.

### Task 3: Add monitored transfer and automatic recovery

**Files:**
- Modify: `genomes/uniprot/download_uniprot.sh`
- Test: `genomes/uniprot/test_operational_contract.sh`

**Interfaces:**
- Produces: `run_aria2_attempt`, `classify_transfer_failure`, `monitor_transfer_progress`, `build_repair_plan`, and `run_download_with_recovery`.

- [x] **Step 1: Implement per-attempt aria2 logs**

Retain one transport log per attempt, include the effective concurrency and retry settings in the main log, and copy a targeted error tail into `error.log` on failure.

- [x] **Step 2: Implement progress snapshots**

While aria2 runs, atomically update file and byte progress, elapsed time, rolling 10/30/60-minute speeds, ETA, attempt, and last error class. Stop the monitor with the parent process.

- [x] **Step 3: Implement failure classification**

Classify 429 as `RATE_LIMITED`; timeout, DNS, TLS, EOF, 408, and 5xx as `TRANSIENT_NETWORK`; 404/410 as `REMOTE_PERMANENT`; disk errors as `STORAGE_BLOCKED`; 401/403 as `AUTH_CONFIG`; unmatched errors as `INTERNAL_INVARIANT`.

- [x] **Step 4: Implement bounded recovery rounds**

After each failed transport, preserve sidecar partials, quarantine invalid complete files, rebuild the pending input and repair plan, back off, and retry. A nonzero aria2 result followed by complete verification is success; exhausted retryable targets end as `NEEDS_REPAIR` with exit `20`.

- [x] **Step 5: Verify GREEN**

Run the operational and existing manifest tests. Expected: both PASS without network access.

### Task 4: Complete documentation and repository contracts

**Files:**
- Create: `genomes/uniprot/download_contract.md`
- Create: `genomes/uniprot/decisions.md`
- Create: `genomes/uniprot/runbook.md`
- Modify: `genomes/uniprot/download_scheme.md`
- Modify: `genomes/uniprot/validation_report.md`
- Modify: `genomes/uniprot/uniprot_research_summary.md`

**Interfaces:**
- Produces: a self-contained operational contract, decision record, verified run commands, and static gates for the new lifecycle.

- [x] **Step 1: Document boundaries and completion semantics**

Record the fixed release, 25 required files, exclusions, storage estimate, official checksum coverage, release-manifest substitute checks, minimum repair unit, and exact complete/needs-repair/blocked definitions.

- [x] **Step 2: Document operation commands**

Provide plan, preflight-equivalent plan review, background start, status, read-only verify, resume/repair, log inspection, controlled stop, and final summary commands. Clearly state that `--all` means all approved 25 targets, not all official UniProt products.

- [x] **Step 3: Update UniProt-local contracts**

Require the operational test, documents, state functions, retry settings, lock, status mode, and prohibition on destructive deletion commands without modifying repository-wide tests.

### Task 5: Full verification and local commit

**Files:**
- Verify all modified files.

- [x] **Step 1: Run focused tests**

```bash
bash genomes/uniprot/test_manifest_contract.sh
bash genomes/uniprot/test_operational_contract.sh
bash genomes/tests/test_static_contracts.sh
```

- [x] **Step 2: Run static and hygiene gates**

Run Bash syntax checks for all UniProt scripts, stale-name scans, forbidden deletion scans, `git diff --check`, and review the complete staged diff.

- [x] **Step 3: Confirm protected scope**

Verify that `refseq/`, `genomes/common/common.sh`, and the approved manifest TSV are unchanged.

- [x] **Step 4: Create a local Chinese Git commit**

Stage only the UniProt implementation, plan, tests, fixtures, and documentation. Commit locally and do not push.
