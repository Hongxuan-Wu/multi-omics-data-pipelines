#!/usr/bin/env bash
set -Eeuo pipefail

input_file=""
follow_metalink=""
for arg in "$@"; do
  case "${arg}" in
    --input-file=*) input_file="${arg#*=}" ;;
    --follow-metalink=*) follow_metalink="${arg#*=}" ;;
  esac
done

[[ -n "${input_file}" && -r "${input_file}" ]] || {
  printf 'fake aria2: missing readable --input-file\n' >&2
  exit 2
}
[[ "${follow_metalink}" == "false" ]] || {
  printf 'fake aria2: --follow-metalink=false is required\n' >&2
  exit 2
}
: "${FAKE_ARIA_COUNTER:?FAKE_ARIA_COUNTER is required}"
: "${FAKE_ARIA_SOURCE:?FAKE_ARIA_SOURCE is required}"
: "${FAKE_ARIA_ARCHIVE:?FAKE_ARIA_ARCHIVE is required}"

attempt=0
if [[ -s "${FAKE_ARIA_COUNTER}" ]]; then
  attempt="$(awk 'NR == 1 {print $1}' "${FAKE_ARIA_COUNTER}")"
fi
attempt=$((attempt + 1))
printf '%s\n' "${attempt}" > "${FAKE_ARIA_COUNTER}"

local_dir="$(awk -F '=' '/^  dir=/ {print substr($0, index($0, "=") + 1); exit}' "${input_file}")"
out_name="$(awk -F '=' '/^  out=/ {print substr($0, index($0, "=") + 1); exit}' "${input_file}")"
[[ -n "${local_dir}" && -n "${out_name}" ]] || {
  printf 'fake aria2: input contains no target\n' >&2
  exit 2
}

mkdir -p "${local_dir}" "${FAKE_ARIA_ARCHIVE}"
target="${local_dir}/${out_name}"
sidecar="${target}.aria2"
mode="${FAKE_ARIA_MODE:-fail-once}"

if [[ "${mode}" == "wait-for-signal" ]]; then
  printf 'partial-waiting-for-signal\n' > "${target}"
  : > "${sidecar}"
  printf 'fake aria2 waiting for termination\n' >&2
  exec sleep "${FAKE_ARIA_SLEEP_SECONDS:-30}"
fi

if [[ "${mode}" == "complete-but-nonzero" ]]; then
  if [[ -e "${target}" ]]; then
    mv -- "${target}" "${FAKE_ARIA_ARCHIVE}/payload.before_nonzero.attempt${attempt}"
  fi
  if [[ -e "${sidecar}" ]]; then
    mv -- "${sidecar}" "${FAKE_ARIA_ARCHIVE}/sidecar.before_nonzero.attempt${attempt}"
  fi
  cp -- "${FAKE_ARIA_SOURCE}" "${target}"
  printf 'simulated wrapper failure after complete payload\n' >&2
  exit 1
fi

if [[ "${mode}" == "always-fail" || ("${mode}" == "fail-once" && "${attempt}" -eq 1) ]]; then
  printf 'partial-attempt-%s\n' "${attempt}" > "${target}"
  : > "${sidecar}"
  printf 'errorCode=29 HTTP status=503 Got EOF from the server\n' >&2
  exit 1
fi

if [[ -e "${target}" ]]; then
  mv -- "${target}" "${FAKE_ARIA_ARCHIVE}/payload.before_success.attempt${attempt}"
fi
if [[ -e "${sidecar}" ]]; then
  mv -- "${sidecar}" "${FAKE_ARIA_ARCHIVE}/sidecar.before_success.attempt${attempt}"
fi
cp -- "${FAKE_ARIA_SOURCE}" "${target}"
printf 'Download complete: %s\n' "${target}"
