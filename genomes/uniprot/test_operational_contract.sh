#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOADER="${SCRIPT_DIR}/download_uniprot.sh"
FAKE_ARIA2="${SCRIPT_DIR}/tests/fixtures/fake_aria2c.sh"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected=${expected} actual=${actual}"
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  [[ -f "${file}" ]] || fail "${label}: missing file ${file}"
  grep -Eq -- "${pattern}" "${file}" || fail "${label}: ${file} missing ${pattern}"
}

assert_function_exists() {
  local name="$1"
  declare -F "${name}" >/dev/null || fail "missing function: ${name}"
}

bash -n "${DOWNLOADER}"
bash -n "${FAKE_ARIA2}"

(
  source "${DOWNLOADER}"
  for function_name in \
    validate_safe_roots init_runtime_state write_state write_progress_snapshot \
    write_summary_report acquire_run_lock release_run_lock classify_transfer_failure \
    run_aria2_attempt monitor_transfer_progress build_repair_plan \
    verify_selected_files run_download_with_recovery; do
    assert_function_exists "${function_name}"
  done
)

test_root="$(mktemp -d /tmp/uniprot_operational_contract.XXXXXX)"
help_file="${test_root}/help.txt"
"${DOWNLOADER}" --help > "${help_file}"
for option in \
  verify-only status summary download-attempts retry-wait progress-interval \
  lock-wait connections max-concurrent split min-split-size aria-max-tries \
  aria-retry-wait summary-interval min-disk-gb local-root run-root manifest; do
  assert_file_contains "${help_file}" "--${option}" "help option ${option}"
done
assert_file_contains "${help_file}" 'exit.*20|20.*NEEDS_REPAIR' "help exit 20"
assert_file_contains "${help_file}" 'exit.*30|30.*BLOCKED' "help exit 30"

set +e
"${DOWNLOADER}" --download-attempts 0 --plan-only \
  > "${test_root}/invalid.stdout" 2> "${test_root}/invalid.stderr"
invalid_status=$?
set -e
assert_eq 2 "${invalid_status}" "invalid retry count exit"

set +e
PLAN_ONLY=invalid "${DOWNLOADER}" \
  > "${test_root}/invalid-env.stdout" 2> "${test_root}/invalid-env.stderr"
invalid_env_status=$?
set -e
assert_eq 30 "${invalid_env_status}" "invalid environment mode exit"

for invalid_option in '--connections 17' '--min-split-size 1K' '--min-split-size 1025M'; do
  read -r -a invalid_parts <<< "${invalid_option}"
  set +e
  "${DOWNLOADER}" "${invalid_parts[@]}" --plan-only \
    > "${test_root}/invalid-aria.stdout" 2> "${test_root}/invalid-aria.stderr"
  invalid_aria_status=$?
  set -e
  assert_eq 2 "${invalid_aria_status}" "invalid aria option ${invalid_option} exit"
done

set +e
"${DOWNLOADER}" --plan-only --local-root / --run-root "${test_root}/unsafe-run" \
  > "${test_root}/unsafe.stdout" 2> "${test_root}/unsafe.stderr"
unsafe_status=$?
set -e
assert_eq 30 "${unsafe_status}" "unsafe root exit"

set +e
"${DOWNLOADER}" --plan-only --local-root "${test_root}/nested" \
  --run-root "${test_root}/nested/run" \
  > "${test_root}/nested.stdout" 2> "${test_root}/nested.stderr"
nested_status=$?
set -e
assert_eq 30 "${nested_status}" "nested roots exit"

plan_data="${test_root}/plan-data"
plan_run="${test_root}/plan-run"
"${DOWNLOADER}" --plan-only --local-root "${plan_data}" --run-root "${plan_run}" \
  > "${test_root}/plan.stdout" 2> "${test_root}/plan.stderr"
assert_file_contains "${plan_run}/status/latest_status.tsv" $'\tPLANNED\t0\t' "plan latest status"
[[ -f "${plan_run}/reports/latest_summary.md" ]] || fail "plan latest summary is missing"
[[ ! -e "${plan_data}" ]] || fail "plan-only created the payload root"

"${DOWNLOADER}" --status --local-root / --run-root "${plan_run}" \
  > "${test_root}/status.stdout" 2> "${test_root}/status.stderr"
assert_file_contains "${test_root}/status.stdout" $'\tPLANNED\t0\t' "status query"
"${DOWNLOADER}" --summary --local-root / --run-root "${plan_run}" \
  > "${test_root}/summary.stdout" 2> "${test_root}/summary.stderr"
assert_file_contains "${test_root}/summary.stdout" 'State: `PLANNED`' "summary query"

verify_data="${test_root}/verify-data"
verify_run="${test_root}/verify-run"
set +e
"${DOWNLOADER}" --verify-only --local-root "${verify_data}" --run-root "${verify_run}" \
  > "${test_root}/verify.stdout" 2> "${test_root}/verify.stderr"
verify_status=$?
set -e
assert_eq 20 "${verify_status}" "verify-only missing data exit"
assert_file_contains "${verify_run}/status/latest_status.tsv" $'\tNEEDS_REPAIR\t20\t' "verify latest status"
assert_file_contains "${verify_run}/reports/latest_summary.md" 'NEEDS_REPAIR' "verify summary status"
[[ ! -e "${verify_data}" ]] || fail "verify-only created the payload root"
trash_entries="$(find "${verify_run}/trash" -mindepth 1 -maxdepth 1 -print | wc -l | awk '{print $1}')"
assert_eq 0 "${trash_entries}" "verify-only must not quarantine payloads"

set +e
SKIP_VERIFIED_FILES=0 "${DOWNLOADER}" --plan-only \
  --local-root "${test_root}/skip-data" --run-root "${test_root}/skip-run" \
  > "${test_root}/skip.stdout" 2> "${test_root}/skip.stderr"
skip_status=$?
set -e
assert_eq 30 "${skip_status}" "disabled idempotent skip gate exit"

classification_root="${test_root}/classification"
mkdir -p "${classification_root}"
printf 'HTTP 429 Retry-After: 120\n' > "${classification_root}/429.log"
printf 'HTTP status=503 Got EOF from the server\n' > "${classification_root}/503.log"
printf 'HTTP status=404\n' > "${classification_root}/404.log"
printf 'No space left on device\n' > "${classification_root}/disk.log"
printf 'HTTP status=403\n' > "${classification_root}/auth.log"
printf 'Checksum error: digest mismatch\n' > "${classification_root}/checksum.log"
(
  source "${DOWNLOADER}"
  assert_eq RATE_LIMITED "$(classify_transfer_failure "${classification_root}/429.log")" "429 classification"
  assert_eq TRANSIENT_NETWORK "$(classify_transfer_failure "${classification_root}/503.log")" "503 classification"
  assert_eq REMOTE_PERMANENT "$(classify_transfer_failure "${classification_root}/404.log")" "404 classification"
  assert_eq STORAGE_BLOCKED "$(classify_transfer_failure "${classification_root}/disk.log")" "disk classification"
  assert_eq AUTH_CONFIG "$(classify_transfer_failure "${classification_root}/auth.log")" "auth classification"
  assert_eq VALIDATION_FAILED "$(classify_transfer_failure "${classification_root}/checksum.log")" "checksum classification"
)

lock_root="${test_root}/lock"
marker="${lock_root}/holder.ready"
mkdir -p "${lock_root}"
(
  source "${DOWNLOADER}"
  LOCAL_ROOT="${lock_root}/data"
  RUN_ROOT="${lock_root}/different-run-root"
  RUN_ID="holder"
  init_runtime_paths
  common_init_dirs
  init_runtime_state
  LOCK_WAIT_SECONDS=0
  acquire_run_lock
  : > "${marker}"
  sleep 2
) > "${lock_root}/holder.stdout" 2> "${lock_root}/holder.stderr" &
holder_pid=$!
for _ in $(seq 1 100); do
  [[ -f "${marker}" ]] && break
  sleep 0.02
done
[[ -f "${marker}" ]] || fail "lock holder did not start"
set +e
(
  source "${DOWNLOADER}"
  LOCAL_ROOT="${lock_root}/data"
  RUN_ROOT="${lock_root}/run"
  RUN_ID="contender"
  init_runtime_paths
  common_init_dirs
  init_runtime_state
  LOCK_WAIT_SECONDS=0
  acquire_run_lock
) > "${lock_root}/contender.stdout" 2> "${lock_root}/contender.stderr"
contender_status=$?
set -e
assert_eq 30 "${contender_status}" "concurrent lock exit"
shopt -s nullglob
lock_files=("${lock_root}"/.uniprot_download_*.lock)
shopt -u nullglob
assert_eq 1 "${#lock_files[@]}" "stable data-root lock file count"
assert_file_contains "${lock_files[0]}" '^run_id=holder$' "lock holder metadata"
wait "${holder_pid}"

payload="${test_root}/verified-payload.dat"
printf 'verified UniProt fixture payload\n' > "${payload}"
payload_bytes="$(stat -c '%s' "${payload}")"
payload_md5="$(md5sum "${payload}" | awk '{print $1}')"

run_recovery_case() {
  local case_name="$1"
  local fake_mode="$2"
  local expected_status="$3"
  local expected_attempts="${4:-2}"
  local minimum_repair_plans="${5:-1}"
  local case_root="${test_root}/${case_name}"
  local case_plan="${case_root}/fixture-plan.tsv"
  local local_file="${case_root}/data/fixture.dat"
  mkdir -p "${case_root}/data" "${case_root}/run" "${case_root}/fake-archive"
  {
    printf 'dataset\trelative_path\turl\tlocal_file\tbytes\tmd5\tsource_kind\tnotes\n'
    printf 'fixture\tfixture.dat\thttps://fixture.invalid/fixture.dat\t%s\t%s\t%s\tstatic_file\tfixture\n' \
      "${local_file}" "${payload_bytes}" "${payload_md5}"
  } > "${case_plan}"

  set +e
  (
    source "${DOWNLOADER}"
    LOCAL_ROOT="${case_root}/data"
    RUN_ROOT="${case_root}/run"
    RUN_ID="${case_name}"
    SELECTED_LABEL="fixture"
    TARGET_COUNT=1
    TARGET_BYTES="${payload_bytes}"
    MIN_DISK_GB=1
    MIN_DISK_GB_WAS_SET=1
    DOWNLOAD_MAX_ATTEMPTS=2
    DOWNLOAD_RETRY_WAIT_SECONDS=0
    PROGRESS_INTERVAL_SECONDS=0
    ARIA2_BIN="${FAKE_ARIA2}"
    ARIA2_MAX_TRIES=1
    ARIA2_RETRY_WAIT_SECONDS=0
    export FAKE_ARIA_COUNTER="${case_root}/fake-counter.txt"
    export FAKE_ARIA_SOURCE="${payload}"
    export FAKE_ARIA_ARCHIVE="${case_root}/fake-archive"
    export FAKE_ARIA_MODE="${fake_mode}"
    init_runtime_paths
    common_init_dirs
    init_runtime_state
    PLAN_FILE="${case_plan}"
    run_download_with_recovery
  ) > "${case_root}/case.stdout" 2> "${case_root}/case.stderr"
  case_status=$?
  set -e
  assert_eq "${expected_status}" "${case_status}" "${case_name} exit"
  assert_eq "${expected_attempts}" "$(awk 'NR == 1 {print $1}' "${case_root}/fake-counter.txt")" "${case_name} attempts"
  repair_plans="$(find "${case_root}/run/plans" -maxdepth 1 -type f -name 'repair_plan_*.tsv' -print | wc -l | awk '{print $1}')"
  [[ "${repair_plans}" -ge "${minimum_repair_plans}" ]] || fail "${case_name} repair plan missing"

  if [[ "${expected_status}" == "0" ]]; then
    assert_eq "${payload_md5}" "$(md5sum "${local_file}" | awk '{print $1}')" "${case_name} final md5"
    if [[ "${fake_mode}" == "fail-once" ]]; then
      assert_file_contains "${case_root}/run/status/latest_status.tsv" 'TRANSIENT_NETWORK' "${case_name} failure event"
    fi
    (
      source "${DOWNLOADER}"
      LOCAL_ROOT="${case_root}/data"
      RUN_ROOT="${case_root}/run"
      RUN_ID="idempotent"
      SELECTED_LABEL="fixture"
      init_runtime_paths
      common_init_dirs
      PLAN_FILE="${case_plan}"
      write_aria_input
      assert_eq 0 "${DOWNLOAD_COUNT}" "idempotent pending count"
    ) > "${case_root}/idempotent.stdout" 2> "${case_root}/idempotent.stderr"
  else
    [[ -f "${local_file}.aria2" ]] || fail "${case_name} resumable sidecar missing"
  fi
}

run_recovery_case recovery-success fail-once 0
run_recovery_case recovery-exhausted always-fail 20
run_recovery_case recovery-nonzero-complete complete-but-nonzero 0 1 0

interrupt_root="${test_root}/interruption"
interrupt_plan="${interrupt_root}/fixture-plan.tsv"
interrupt_file="${interrupt_root}/data/fixture.dat"
mkdir -p "${interrupt_root}/data" "${interrupt_root}/run" "${interrupt_root}/fake-archive"
{
  printf 'dataset\trelative_path\turl\tlocal_file\tbytes\tmd5\tsource_kind\tnotes\n'
  printf 'fixture\tfixture.dat\thttps://fixture.invalid/fixture.dat\t%s\t%s\t%s\tstatic_file\tfixture\n' \
    "${interrupt_file}" "${payload_bytes}" "${payload_md5}"
} > "${interrupt_plan}"
(
  source "${DOWNLOADER}"
  LOCAL_ROOT="${interrupt_root}/data"
  RUN_ROOT="${interrupt_root}/run"
  RUN_ID="interruption"
  SELECTED_LABEL="fixture"
  TARGET_COUNT=1
  TARGET_BYTES="${payload_bytes}"
  MIN_DISK_GB=1
  MIN_DISK_GB_WAS_SET=1
  DOWNLOAD_MAX_ATTEMPTS=3
  DOWNLOAD_RETRY_WAIT_SECONDS=0
  PROGRESS_INTERVAL_SECONDS=0
  ARIA2_BIN="${FAKE_ARIA2}"
  export FAKE_ARIA_COUNTER="${interrupt_root}/fake-counter.txt"
  export FAKE_ARIA_SOURCE="${payload}"
  export FAKE_ARIA_ARCHIVE="${interrupt_root}/fake-archive"
  export FAKE_ARIA_MODE="wait-for-signal"
  export FAKE_ARIA_SLEEP_SECONDS=30
  init_runtime_paths
  common_init_dirs
  init_runtime_state
  PLAN_FILE="${interrupt_plan}"
  run_download_with_recovery
) > "${interrupt_root}/case.stdout" 2> "${interrupt_root}/case.stderr" &
interrupt_pid=$!
for _ in $(seq 1 200); do
  [[ -f "${interrupt_file}.aria2" ]] && break
  sleep 0.02
done
[[ -f "${interrupt_file}.aria2" ]] || fail "interruption fixture did not start"
kill -TERM "${interrupt_pid}"
set +e
wait "${interrupt_pid}"
interrupt_status=$?
set -e
assert_eq 143 "${interrupt_status}" "SIGTERM exit"
assert_file_contains "${interrupt_root}/run/status/latest_status.tsv" $'\tINTERRUPTED\t143\t' "interruption state"
[[ -f "${interrupt_file}.aria2" ]] || fail "interruption removed resumable sidecar"

printf '[PASS] UniProt operational contracts\n'
