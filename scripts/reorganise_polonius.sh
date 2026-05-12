#!/usr/bin/env bash
# reorganise_polonius.sh
#
# Standalone tool to reorganise Polonius (skera) output into deconcatenated/,
# reports/, and nonpassing/ subfolders. Useful for retrofitting existing output
# directories without re-running polonius.
#
# This script delegates the actual classification logic to lib/reorganise.sh,
# so it stays in lock-step with polonius_cli.sh's --reorganise flag.
#
# Each --path value is auto-detected:
#   - if its basename starts with `skera_`, it's processed as a single sample dir
#   - otherwise it's treated as a deconcat/ parent and its skera_*/ subdirs are processed
#
# Safe to re-run: existing subfolders are reused. Files outside skera_*/ dirs are left untouched.

set -euo pipefail

#-----------------------------------------------------------------------------
# Locate and source the shared library (lives at the polonius repo root)
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
DRY_RUN=0
DROP_NONPASSING=0
PATHS=()

usage() {
    cat <<EOF
Usage: $0 --path <dir> [--path <dir> ...] [--drop-nonpassing] [--dry-run]

Options:
  --path <dir>        path to a deconcat/ dir OR a specific skera_*/ dir
                      (can be specified multiple times)
  --drop-nonpassing   delete non-passing BAMs instead of moving them to nonpassing/
                      (saves disk space – irreversible)
  --dry-run           print planned moves/deletions without executing
  -h, --help          show this help

Examples:
  # One deconcat/ dir
  $0 --path ~/Scratch/data/demultiplex/2026.05.09_ucllrs_pacbio_revio_kinnex/deconcat

  # Dry run first
  $0 --path ~/Scratch/data/.../deconcat --dry-run

  # Multiple runs in one go
  $0 --path /path/to/run1/deconcat --path /path/to/run2/deconcat

  # Drop non-passing BAMs to save space
  $0 --path /path/to/deconcat --drop-nonpassing

  # Just one sample dir
  $0 --path /path/to/deconcat/skera_m84277_260509_135316_s2.hifi_reads.bcM0001
EOF
}

#-----------------------------------------------------------------------------
# Argument parsing
#-----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            if [[ $# -lt 2 ]]; then
                echo "Error: --path requires a value" >&2
                exit 1
            fi
            PATHS+=("$2")
            shift 2
            ;;
        --path=*)
            PATHS+=("${1#--path=}")
            shift
            ;;
        --drop-nonpassing) DROP_NONPASSING=1; shift ;;
        --dry-run)         DRY_RUN=1;         shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "Error: at least one --path required" >&2
    usage
    exit 1
fi

#-----------------------------------------------------------------------------
# Per-sample wrapper that prints a one-line summary
#-----------------------------------------------------------------------------
total_deconcatenated=0
total_reports=0
total_nonpassing=0
total_dropped=0
total_skipped=0
n_samples=0

process_sample_dir() {
    local sample_dir="${1%/}"

    if [[ ! -d "${sample_dir}" ]]; then
        echo "Warning: ${sample_dir} is not a directory, skipping" >&2
        return
    fi

    n_samples=$((n_samples + 1))
    echo "Processing: $(basename "${sample_dir}")"

    if reorganise_sample_dir "${sample_dir}" "${DROP_NONPASSING}" "${DRY_RUN}"; then
        if [[ ${DROP_NONPASSING} -eq 1 ]]; then
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

    bn=$(basename "${arg}")
    if [[ "${bn}" == skera_* ]]; then
        process_sample_dir "${arg}"
    else
        found=0
        for sample_dir in "${arg}"/skera_*/; do
            process_sample_dir "${sample_dir}"
            found=1
        done
        if [[ ${found} -eq 0 ]]; then
            echo "Warning: no skera_*/ subdirs found in ${arg}" >&2
        fi
    fi
done

if [[ ${n_samples} -eq 0 ]]; then
    echo "No samples processed." >&2
    exit 1
fi

echo ""
echo "Summary across ${n_samples} sample(s):"
printf '  Total deconcatenated: %d\n' "${total_deconcatenated}"
printf '  Total reports:        %d\n' "${total_reports}"
if [[ ${DROP_NONPASSING} -eq 1 ]]; then
    printf '  Total dropped:        %d\n' "${total_dropped}"
else
    printf '  Total nonpassing:     %d\n' "${total_nonpassing}"
fi
printf '  Total skipped:        %d\n' "${total_skipped}"

if [[ ${DRY_RUN} -eq 1 ]]; then
    echo ""
    echo "Dry-run only. Re-run without --dry-run to execute."
fi
