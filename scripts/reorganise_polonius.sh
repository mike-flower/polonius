#!/usr/bin/env bash
# reorganise_polonius.sh
#
# Standalone tool to reorganise existing Polonius (skera) output without
# re-running polonius. Delegates all classification and file-movement logic
# to lib/reorganise.sh and uses the bidirectional reorganise_path() function,
# so any source layout can be converted to any target layout.
#
# Source layouts auto-detected from filenames (no flag needed):
#   - default (v1.3+)       <sample>/*
#   - by-sample-type        <sample>/{deconcatenated,reports,nonpassing}/*
#   - by-type               {deconcatenated,reports,nonpassing}/*
#   - by-type-sample        {deconcatenated,reports,nonpassing}/<sample>/*
#   - legacy v1.2 default   skera_<sample>/*   (back-compat)
#
# Target layouts (--mode):
#   by-sample        per-sample dirs, files flat inside (== default layout)
#   by-sample-type   per-sample dirs with type subdirs
#   by-type          top-level type dirs, all samples pooled flat inside each
#   by-type-sample   top-level type dirs with per-sample subdirs
#
# Each --path is the directory containing your skera output (in any layout).
# --dir_out defaults to each --path (in-place migration); pass --dir_out
# explicitly only when you want to write to a different location.
#
# Version: 1.4.0

set -euo pipefail

#-----------------------------------------------------------------------------
# Locate and source the shared library
#-----------------------------------------------------------------------------
# Resolve real script location, following symlinks (portable bash; works on
# macOS without GNU readlink -f).
_src="${BASH_SOURCE[0]}"
while [[ -L "${_src}" ]]; do
    _dir="$( cd -P "$( dirname "${_src}" )" && pwd )"
    _src="$(readlink "${_src}")"
    [[ "${_src}" != /* ]] && _src="${_dir}/${_src}"
done
SCRIPT_DIR="$( cd -P "$( dirname "${_src}" )" && pwd )"
unset _src _dir
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

Reorganise existing Polonius output without re-running skera. Works
bidirectionally: any source layout can be converted to any target layout.

Required:
  --mode MODE         by-sample | by-sample-type | by-type | by-type-sample
  --path <dir>        directory containing skera output (in any layout).
                      Can be specified multiple times to process several
                      runs in one invocation.

Options:
  --dir_out DIR       destination directory (default: same as --path,
                      i.e. in-place migration)
  --drop-nonpassing   delete non-passing BAMs instead of moving them
                      (irreversible)
  --dry-run           print planned moves without executing
                      (--dry_run is also accepted)
  -h, --help          show this help

Examples:

  # Convert in-place from whatever the current layout is to by-type
  $0 --mode by-type --path ~/results/deconcat

  # Migrate from by-sample-type to by-type (previously unsupported)
  $0 --mode by-type --path ~/results/deconcat

  # Dry-run first to preview moves
  $0 --mode by-sample-type --path ~/results/deconcat --dry-run

  # Two runs combined into one merged tree (per-sample subdirs)
  $0 --mode by-type-sample \\
      --path /run1/deconcat --path /run2/deconcat \\
      --dir_out /merged

Notes:
  - File classification is by filename (*.skera.bam, *.skera.summary.csv, etc.).
    Anything that isn't a recognised skera output is left where it is.
  - Empty intermediate directories are cleaned up after the moves.
  - Re-running the same migration is a safe no-op: files already at their
    target location are detected (by inode) and counted as "in-place".
EOF
}

#-----------------------------------------------------------------------------
# Argument parsing
#-----------------------------------------------------------------------------
# Arguments are space-separated: '--flag value', not '--flag=value'. This
# matches polonius's parser; the README troubleshooting section documents
# the rejection.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -lt 2 || "${2:-}" == --* ]] && { echo "Error: --mode requires a value" >&2; exit 1; }
            MODE="$2"; shift 2 ;;
        --path)
            [[ $# -lt 2 || "${2:-}" == --* ]] && { echo "Error: --path requires a value" >&2; exit 1; }
            PATHS+=("$2"); shift 2 ;;
        --dir_out)
            [[ $# -lt 2 || "${2:-}" == --* ]] && { echo "Error: --dir_out requires a value" >&2; exit 1; }
            DIR_OUT="$2"; shift 2 ;;
        --drop-nonpassing) DROP_NONPASSING=1; shift ;;
        --dry-run|--dry_run) DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)
            if [[ "$1" == --*=* ]]; then
                echo "Error: $1" >&2
                echo "       Arguments use space separation: '--flag value', not '--flag=value'." >&2
            else
                echo "Unknown argument: $1" >&2
            fi
            usage; exit 1 ;;
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
    by-sample|by-sample-type|by-type|by-type-sample) ;;
    *)
        echo "Error: invalid mode '${MODE}'" >&2
        echo "Valid modes: by-sample, by-sample-type, by-type, by-type-sample" >&2
        exit 1
        ;;
esac

if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "Error: at least one --path required" >&2
    usage; exit 1
fi

#-----------------------------------------------------------------------------
# Process each --path
#-----------------------------------------------------------------------------
total_deconcatenated=0
total_reports=0
total_nonpassing=0
total_dropped=0
total_skipped=0
total_inplace=0
n_paths=0

for arg in "${PATHS[@]}"; do
    if [[ ! -d "${arg}" ]]; then
        echo "Warning: ${arg} is not a directory, skipping" >&2
        continue
    fi

    n_paths=$((n_paths + 1))
    abs_path=$(cd "${arg}" && pwd)
    effective_dir_out="${DIR_OUT:-${abs_path}}"

    echo "Processing: ${abs_path}"
    echo "  Target mode: ${MODE}"
    echo "  Destination: ${effective_dir_out}"

    if reorganise_path "${abs_path}" "${MODE}" "${effective_dir_out}" \
            "${DROP_NONPASSING}" "${DRY_RUN}"; then
        if [[ "${DROP_NONPASSING}" -eq 1 ]]; then
            printf '  -> deconcatenated: %d, reports: %d, dropped: %d, in-place: %d, skipped: %d\n' \
                "${REORG_DECONCATENATED}" "${REORG_REPORTS}" "${REORG_DROPPED}" \
                "${REORG_INPLACE}" "${REORG_SKIPPED}"
        else
            printf '  -> deconcatenated: %d, reports: %d, nonpassing: %d, in-place: %d, skipped: %d\n' \
                "${REORG_DECONCATENATED}" "${REORG_REPORTS}" "${REORG_NONPASSING}" \
                "${REORG_INPLACE}" "${REORG_SKIPPED}"
        fi

        total_deconcatenated=$((total_deconcatenated + REORG_DECONCATENATED))
        total_reports=$((total_reports + REORG_REPORTS))
        total_nonpassing=$((total_nonpassing + REORG_NONPASSING))
        total_dropped=$((total_dropped + REORG_DROPPED))
        total_skipped=$((total_skipped + REORG_SKIPPED))
        total_inplace=$((total_inplace + REORG_INPLACE))
    else
        echo "  Warning: reorganise_path failed for ${abs_path}" >&2
    fi
done

if [[ ${n_paths} -eq 0 ]]; then
    echo "No paths processed." >&2
    exit 1
fi

echo ""
echo "Summary across ${n_paths} path(s):"
printf '  Total deconcatenated: %d\n' "${total_deconcatenated}"
printf '  Total reports:        %d\n' "${total_reports}"
if [[ "${DROP_NONPASSING}" -eq 1 ]]; then
    printf '  Total dropped:        %d\n' "${total_dropped}"
else
    printf '  Total nonpassing:     %d\n' "${total_nonpassing}"
fi
printf '  Total in-place:       %d (files already at target location)\n' "${total_inplace}"
printf '  Total skipped:        %d (non-skera files left untouched)\n' "${total_skipped}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ""
    echo "Dry-run only. Re-run without --dry-run to execute."
fi
