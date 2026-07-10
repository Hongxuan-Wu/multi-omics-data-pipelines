#!/usr/bin/env bash

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_PROJECT_ROOT="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${COMMON_PROJECT_ROOT}/config/pipeline.env}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

assert_absolute() {
    local path="$1"

    [[ "${path}" == /* ]] || die "路径必须为绝对路径：${path}"
}

[[ -f "${CONFIG_FILE}" ]] || {
    die "缺少配置文件：${CONFIG_FILE}"
    return 1
}

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

for prefix in "${CONDA_EXE}" "${FASTP_PREFIX}" "${STAR_PREFIX}" \
    "${STRINGTIE_PREFIX}" "${PASA_PREFIX}" "${AGAT_PREFIX}"; do
    assert_absolute "${prefix}"
done

WORK_ROOT="${PROJECT_ROOT}/work"
LOG_ROOT="${PROJECT_ROOT}/logs"
RESULT_ROOT="${PROJECT_ROOT}/results"
REPORT_ROOT="${PROJECT_ROOT}/reports"
TRASH_ROOT="${PROJECT_ROOT}/trash"

config_sha256() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        die "缺少配置文件：${CONFIG_FILE}"
        return 1
    fi

    sha256sum -- "${CONFIG_FILE}" | awk '{print $1}'
}

require_run_id() {
    [[ -n "${RUN_ID:-}" ]] || die "RUN_ID 未设置"
    [[ "${RUN_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "RUN_ID 含有不安全字符：${RUN_ID}"
}

assert_safe_output_path() {
    local resolved

    assert_absolute "$1" || return 1
    resolved="$(realpath -m "$1")"
    case "${resolved}" in
        "${RESOURCE_ROOT}"|"${RESOURCE_ROOT}/"*|"${TOOL_ROOT}"|"${TOOL_ROOT}/"*)
            die "输出路径落入只读目录：${resolved}"
            return 1
            ;;
    esac
    case "${resolved}" in
        "${PROJECT_ROOT}/work/"*|"${PROJECT_ROOT}/logs/"*|"${PROJECT_ROOT}/results/"*|"${PROJECT_ROOT}/reports/"*|"${PROJECT_ROOT}/trash/"*)
            ;;
        *)
            die "输出路径不在允许目录：${resolved}"
            return 1
            ;;
    esac
}

assert_process_output_path() {
    local resolved

    require_run_id || return 1
    assert_safe_output_path "$1" || return 1
    resolved="$(realpath -m "$1")"
    case "${resolved}" in
        "${WORK_ROOT}/${RUN_ID}/"*|"${LOG_ROOT}/${RUN_ID}/"*|"${RESULT_ROOT}/${RUN_ID}/"*|"${TRASH_ROOT}/${RUN_ID}/"*)
            ;;
        *)
            die "处理输出路径不属于当前 run：${resolved}"
            return 1
            ;;
    esac
}

assert_report_output_path() {
    local resolved size_bytes

    require_run_id || return 1
    assert_safe_output_path "$1" || return 1
    resolved="$(realpath -m "$1")"
    case "${resolved}" in
        "${REPORT_ROOT}/${RUN_ID}/"*)
            ;;
        *)
            die "报告输出路径不属于当前 run：${resolved}"
            return 1
            ;;
    esac

    if [[ -f "${resolved}" ]]; then
        size_bytes="$(stat -c '%s' -- "${resolved}")"
        if (( size_bytes > 10 * 1024 * 1024 )); then
            die "报告文件超过 10 MiB：${resolved}"
            return 1
        fi
    fi
}

set_run_paths() {
    RUN_ROOT="${WORK_ROOT}/${RUN_ID}"
    RUN_LOG_ROOT="${LOG_ROOT}/${RUN_ID}"
    RUN_RESULT_ROOT="${RESULT_ROOT}/${RUN_ID}"
    RUN_REPORT_ROOT="${REPORT_ROOT}/${RUN_ID}"
    RUN_TRASH_ROOT="${TRASH_ROOT}/${RUN_ID}"
    STATE_ROOT="${RUN_ROOT}/state"
    RUN_CONFIG_HASH_FILE="${STATE_ROOT}/config.sha256"
}

init_run_layout() {
    local config_hash existing_path run_exists=0

    require_run_id || return 1
    local -a run_paths=(
        "${WORK_ROOT}/${RUN_ID}"
        "${LOG_ROOT}/${RUN_ID}"
        "${RESULT_ROOT}/${RUN_ID}"
        "${REPORT_ROOT}/${RUN_ID}"
        "${TRASH_ROOT}/${RUN_ID}"
    )
    case "${RESUME:-0}" in
        0|1) ;;
        *)
            die "RESUME 必须为 0 或 1：${RESUME}"
            return 1
            ;;
    esac

    set_run_paths
    config_hash="$(config_sha256)" || return 1

    for existing_path in "${run_paths[@]}"; do
        if [[ -e "${existing_path}" ]]; then
            run_exists=1
        fi
    done

    if (( run_exists )); then
        if [[ "${RESUME:-0}" != "1" ]]; then
            die "run 已存在，拒绝覆盖：${RUN_ID}"
            return 1
        fi
        for existing_path in "${run_paths[@]}" \
            "${RUN_ROOT}/reference" \
            "${RUN_ROOT}/fastp" \
            "${RUN_ROOT}/star" \
            "${RUN_ROOT}/stringtie" \
            "${RUN_ROOT}/pasa_align" \
            "${RUN_ROOT}/pasa_update" \
            "${RUN_ROOT}/agat" \
            "${RUN_ROOT}/validation" \
            "${STATE_ROOT}"; do
            [[ -d "${existing_path}" ]] || {
                die "已有 run 布局不完整：${existing_path}"
                return 1
            }
        done
        [[ -f "${RUN_CONFIG_HASH_FILE}" ]] || {
            die "已有 run 缺少配置哈希：${RUN_ID}"
            return 1
        }
        [[ "$(<"${RUN_CONFIG_HASH_FILE}")" == "${config_hash}" ]] || {
            die "已有 run 的配置哈希不匹配：${RUN_ID}"
            return 1
        }
        return 0
    fi

    if [[ "${RESUME:-0}" == "1" ]]; then
        die "不能恢复不存在的 run：${RUN_ID}"
        return 1
    fi

    mkdir -p \
        "${RUN_ROOT}/reference" \
        "${RUN_ROOT}/fastp" \
        "${RUN_ROOT}/star" \
        "${RUN_ROOT}/stringtie" \
        "${RUN_ROOT}/pasa_align" \
        "${RUN_ROOT}/pasa_update" \
        "${RUN_ROOT}/agat" \
        "${RUN_ROOT}/validation" \
        "${STATE_ROOT}" \
        "${RUN_LOG_ROOT}" \
        "${RUN_RESULT_ROOT}" \
        "${RUN_REPORT_ROOT}" \
        "${RUN_TRASH_ROOT}"
    printf '%s\n' "${config_hash}" > "${RUN_CONFIG_HASH_FILE}"
}

rename_noreplace() {
    local source_path="$1"
    local destination="$2"
    local perl_bin="${PASA_PREFIX}/bin/perl"
    local status

    [[ -x "${perl_bin}" ]] || {
        die "PASA Perl 不可执行：${perl_bin}"
        return 1
    }

    if "${perl_bin}" -MConfig -MErrno=EEXIST -e '
use strict;
use warnings;

my ($source, $destination) = @ARGV;
my $arch = $Config{archname} // q{};
my $renameat2_number;

if ($arch =~ /\Ax86_64-linux(?:-|$)/) {
    $renameat2_number = 316;
} elsif ($arch =~ /\Aaarch64-linux(?:-|$)/) {
    $renameat2_number = 276;
} else {
    warn "unsupported Linux renameat2 architecture: $arch\n";
    exit 2;
}

my $result = syscall($renameat2_number, -100, $source, -100, $destination, 1);
exit 0 if $result == 0;

my $errno = 0 + $!;
my $error = "$!";
exit 17 if $errno == EEXIST;
warn "renameat2(RENAME_NOREPLACE) failed: errno=$errno: $error\n";
exit 1;
' -- "${source_path}" "${destination}"; then
        status=0
    else
        status=$?
    fi

    if (( status == 0 )); then
        if [[ ! -e "${source_path}" && ! -L "${source_path}" && \
            ( -e "${destination}" || -L "${destination}" ) ]]; then
            return 0
        fi
        die "renameat2 成功后源和目标状态异常：${source_path} -> ${destination}"
        return 1
    fi

    if (( status == 17 )); then
        if [[ ( -e "${source_path}" || -L "${source_path}" ) && \
            ( -e "${destination}" || -L "${destination}" ) ]]; then
            return 17
        fi
        die "renameat2 EEXIST 后源和目标状态异常：${source_path} -> ${destination}"
        return 1
    fi

    return "${status}"
}

move_to_trash() {
    local source_path="$1"
    local reason="$2"
    local basename timestamp destination status suffix=0

    require_run_id || return 1
    [[ -e "${source_path}" || -L "${source_path}" ]] || {
        die "待隔离路径不存在：${source_path}"
        return 1
    }
    [[ "${reason}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        die "失败原因含有不安全字符：${reason}"
        return 1
    }
    assert_process_output_path "${source_path}" || return 1

    basename="$(basename -- "${source_path}")"
    timestamp="$(date -u '+%Y%m%dT%H%M%S%N')"
    mkdir -p "${TRASH_ROOT}/${RUN_ID}"
    while :; do
        if (( suffix == 0 )); then
            destination="${TRASH_ROOT}/${RUN_ID}/${reason}.${timestamp}.${basename}"
        else
            destination="${TRASH_ROOT}/${RUN_ID}/${reason}.${timestamp}.${suffix}.${basename}"
        fi
        assert_process_output_path "${destination}" || return 1

        if rename_noreplace "${source_path}" "${destination}"; then
            printf '%s\n' "${destination}"
            return 0
        else
            status=$?
        fi
        if (( status == 17 )); then
            suffix=$((suffix + 1))
            continue
        fi

        die "隔离移动失败：${source_path} -> ${destination}"
        return 1
    done
}

run_conda() {
    local prefix="$1"
    shift

    assert_absolute "${prefix}" || return 1
    "${CONDA_EXE}" run --no-capture-output -p "${prefix}" "$@"
}

mark_stage_done() {
    local stage="$1"
    shift
    local output_path output_hash marker_path config_hash

    require_run_id || return 1
    [[ "${stage}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        die "阶段名称含有不安全字符：${stage}"
        return 1
    }
    (( $# > 0 )) || {
        die "阶段完成标记至少需要一个输出：${stage}"
        return 1
    }

    set_run_paths
    marker_path="${STATE_ROOT}/${stage}.done"
    [[ ! -e "${marker_path}" ]] || {
        die "阶段完成标记已存在：${marker_path}"
        return 1
    }
    config_hash="$(config_sha256)" || return 1

    for output_path in "$@"; do
        assert_process_output_path "${output_path}" || return 1
        [[ -f "${output_path}" ]] || {
            die "阶段输出不存在或不是普通文件：${output_path}"
            return 1
        }
    done

    {
        printf 'config_sha256\t%s\n' "${config_hash}"
        for output_path in "$@"; do
            output_hash="$(sha256sum -- "${output_path}" | awk '{print $1}')"
            printf 'output_sha256\t%s\t%s\n' "${output_hash}" "${output_path}"
        done
    } > "${marker_path}"
}

stage_is_valid() {
    local stage="$1"
    local marker_path record_type stored_hash output_path extra_field current_hash output_hash
    local output_count=0

    require_run_id || return 1
    [[ "${stage}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    set_run_paths
    marker_path="${STATE_ROOT}/${stage}.done"
    [[ -f "${marker_path}" ]] || return 1

    IFS=$'\t' read -r record_type stored_hash extra_field < "${marker_path}" || return 1
    [[ "${record_type}" == "config_sha256" && -n "${stored_hash}" && -z "${extra_field}" ]] || return 1
    current_hash="$(config_sha256)" || return 1
    [[ "${stored_hash}" == "${current_hash}" ]] || return 1

    while IFS=$'\t' read -r record_type stored_hash output_path extra_field; do
        [[ "${record_type}" == "output_sha256" && -n "${stored_hash}" && -n "${output_path}" && -z "${extra_field}" ]] || return 1
        assert_process_output_path "${output_path}" || return 1
        [[ -f "${output_path}" ]] || return 1
        output_hash="$(sha256sum -- "${output_path}" | awk '{print $1}')"
        [[ "${stored_hash}" == "${output_hash}" ]] || return 1
        output_count=$((output_count + 1))
    done < <(tail -n +2 "${marker_path}")

    (( output_count > 0 ))
}
