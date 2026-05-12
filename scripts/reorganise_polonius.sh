#!/usr/bin/env bash
# reorganise_polonius.sh
#
# Standalone tool to reorganise existing Polonius (skera) output without
# re-running polonius. Delegates all classification and file-movement logic
# to lib/reorganise.sh, staying in lock-step with polonius_cli.sh.
#
# Each --path value is auto-detected:
#   - if its basename starts with skera_, it is processed as a single sample dir
#   - otherwise it is treated as a deconcat/ parent and its skera_*/ subdirs
#     are processed
#
# The --mode flag mirrors polonius's --reorganise modes:
#   by-sample-type   move files into <sample>/{deconcatenated,reports,nonpassing}/
#   by-type          move files into {deconcatenated,reports,nonpassing}/ flat
#   by-type-sample   move files into {deconcatenated,reports,nonpassing}/<sample>/
#
# --dir_out is required for by-type and by-type-sample (the top-level destination).
# For by-sample-type it defaults to the parent of each skera_*/ dir.

set -euo pipefail

#-----------------------------------------------------------------------------
# Locate and source the shared library
#-----------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
POLONIUS_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
LIB="${POLONIUS_ROOT}/lib/reorganise.sh"

if [[ ! -f "${LIB}" ]]; then
    echo "Error: shared library not found at ${LIB}" >&2
    echo "       This script must be run from within a checked-out polonius repo." >&2
    exit 1
fi
# shellcheck source=../lib/reorganise.sh
source "${LIB}"

#-----------------------------------------------------------------------------
# Defaults
#-----------------------------------------------------------------------------
MODE=""
DIR_OUT=""
DRY_RUN=0
DROP_NONPASSING=0
PATHS=()

usage() {
    cat <<EOF
Usage: $0 --mode MODE --path <dir> [--path <dir> ...] [OPTIONS]

Reorganise existing Polonius output without re-running skera.

Required:
  --mode MODE         by-sample-type | by-type | by-type-sample
  --path <dir>        skera_*/ dir OR a deconcat/ parent containing skera_*/ dirs
                      (can be specified multiple times)

Options:
  --dir_out DIR       output directory for by-type and by-type-sample modes
                      (default: parent of each skera_*/ dir)
  --drop-nonpassing   delete non-passing BAMs instead of moving them (irreversible)
  --dry-run           print planned moves without executing
  -h, --help          show this help

Examples:
  # Reorganise a whole deconcat/ directory
  $0 --mode by-type --path ~/results/deconcat --dir_out ~/results/deconcat

  # Dry run first
  $0 --mode by-sample-type --path ~/results/deconcat --dry-run

  # Single sample dir
  $0 --mode by-sample-type --path ~/results/deconcat/skera_m84277_...bcM0001

  # Multiple paths
  $0 --mode by-type --path /run1/deconcat --path /run2/deconcat --dir_out /merged
EOF
}

#-----------------------------------------------------------------------------
# Argument parsing
#-----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -lt 2 ]] && { echo "Error: --mode requires a value" >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        --path)
            [[ $# -lt 2 ]] && { echo "Error: --path requires a value" >&2; exit 1; }
            PATHS+=("$2"); shift 2 ;;
        --path=*)    PATHS+=("${1#--path=}"); shift ;;
        --dir_out)
            [[ $# -lt 2 ]] && { echo "Error: --dir_out requires a value" >&2; exit 1; }
            DIR_OUT="$2"; shift 2 ;;
        --dir_out=*) DIR_OUT="${1#--dir_out=}"; shift ;;
        --drop-nonpassing) DROP_NONPASSING=1; shift ;;
        --dry-run)         DRY_RUN=1;         shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

#-----------------------------------------------------------------------------
# Validate
#-----------------------------------------------------------------------------
if [[ -z "${MODE}" ]]; then
    echo "Error: --mode is required" >&2
    usage; exit 1
fi

case "${MODE}" in
    by-sample-type|by-type|by-type-sample) ;;
    *)
        echo "Error: invalid mode '${MODE}'" >&2
        echo "Valid modes: by-sample-type, by-type, by-type-sample" >&2
        exit 1
        ;;
esac

if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "Error: at least one --path required" >&2
    usage; exit 1
fi

if [[ "${MODE}" != "by-sample-type" && -z "${DIR_OUT}" ]]; then
    echo "Error: --dir_out is required for mode '${MODE}'" >&2
    exit 1
fi

#-----------------------------------------------------------------------------
# Per-sample processing
#-----------------------------------------------------------------------------
total_deconcatenated=0
total_reports=0
total_nonpassing=0
total_dropped=0
total_skipped=0
n_samples=0

process_sample_dir() {
    local skera_dir="${1%/}"
    local effective_dir_out="${2}"

    if [[ ! -d "${skera_dir}" ]]; then
        echo "Warning: ${skera_dir} is not a directory, skipping" >&2
        return
    fi

    n_samples=$((n_samples + 1))
    echo "Processing: $(basename "${skera_dir}")"

    if reorganise_sample_dir "${skera_dir}" "${MODE}" "${effective_dir_out}" \
            "${DROP_NONPASSING}" "${DRY_RUN}"; then
        if [[ "${DROP_NONPASSING}" -eq 1 ]]; then
            printf '  -> deconcatenated: %d, reports: %d, dropped: %d, skipped: %d\n' \
                "${REORG_DECONCATENATED}" "${REORG_REPORTS}" "${REORG_DROPPED}" "${REORG_SKIPPED}"
        else
            printf '  -> deconcatenated: %d, reports: %d, nonpassing: %d, skipped: %d\n' \
                "${REORG_DECONCATENATED}" "${REORG_REPORTS}" "${REORG_NONPASSING}" "${REORG_SKIPPED}"
        fi
        total_deconcatenated=$((total_deconcatenated + REORG_DECONCATENATED))
        total_reports=$((total_reports + REORG_REPORTS))
        total_nonpassing=$((total_nonpassing + REORG_NONPASSING))
        total_dropped=$((total_dropped + REORG_DROPPED))
        total_skipped=$((total_skipped + REORG_SKIPPED))
    fi
}

#-----------------------------------------------------------------------------
# Main loop
#-----------------------------------------------------------------------------
shopt -s nullglob

for arg in "${PATHS[@]}"; do
    if [[ ! -d "${arg}" ]]; then
        echo "Warning: ${arg} is not a directory, skipping" >&2
        continue
    fi

    # Determine effective dir_out: explicit if given, otherwise parent of skera_ dir
    local_dir_out="${DIR_OUT:-$(cd "${arg}" && pwd)}"
    # If arg is itself a skera_ dir, dir_out is its parent
    if [[ "$(basename "${arg}")" == skera_* ]]; then
        [[ -z "${DIR_OUT}" ]] && local_dir_out="$(cd "${arg}/.." && pwd)"
        process_sample_dir "${arg}" "${local_dir_out}"
    else
        [[ -z "${DIR_OUT}" ]] && local_dir_out="$(cd "${arg}" && pwd)"
        found=0
        for skera_dir in "${arg}"/skera_*/; do
            process_sample_dir "${skera_dir}" "${local_dir_out}"
            found=1
        done
        if [[ ${found} -eq 0 ]]; then
            echo "Warning: no skera_*/ subdirs found in ${arg}" >&2
        fi
    fi
done

shopt -u nullglob

if [[ ${n_samples} -eq 0 ]]; then
    echo "No samples processed." >&2
    exit 1
fi

echo ""
echo "Summary across ${n_samples} sample(s):"
printf '  Total deconcatenated: %d\n' "${total_deconcatenated}"
printf '  Total reports:        %d\n' "${total_reports}"
if [[ "${DROP_NONPASSING}" -eq 1 ]]; then
    printf '  Total dropped:        %d\n' "${total_dropped}"
else
    printf '  Total nonpassing:     %d\n' "${total_nonpassing}"
fi
printf '  Total skipped:        %d\n' "${total_skipped}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ""
    echo "Dry-run only. Re-run without --dry-run to execute."
fi
