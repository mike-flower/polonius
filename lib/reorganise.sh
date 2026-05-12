#!/usr/bin/env bash
#==============================================================================
# Polonius – shared reorganisation library
#==============================================================================
#
# Provides reorganise_sample_dir(), the core function for sorting Polonius
# (skera) output into deconcatenated/, reports/, and nonpassing/ subfolders.
#
# Sourced by:
#   - scripts/polonius_cli.sh         (per-sample reorganisation during a run)
#   - scripts/reorganise_polonius.sh  (post-hoc retrofitting of existing output)
#
# Lives at lib/reorganise.sh in the polonius repo root.
#
# Classification rules (filename-based, order matters – nonpassing checked
# first so its more-specific pattern wins over the generic .skera.bam match):
#   nonpassing/      *.skera.non_passing.bam{,.pbi}
#   deconcatenated/  *.skera.bam{,.pbi}
#   reports/         *.skera.{summary.csv,summary.json,ligations.csv,
#                              read_lengths.csv,found_adapters.csv.gz}
#
# This file should be sourced, not executed.
#==============================================================================

# Guard against double-sourcing
[[ "${_POLONIUS_REORGANISE_LIB_LOADED:-0}" == "1" ]] && return 0
_POLONIUS_REORGANISE_LIB_LOADED=1

#------------------------------------------------------------------------------
# Counters – populated by reorganise_sample_dir(). Callers may read these
# after each call. Reset at the start of every call.
#------------------------------------------------------------------------------
REORG_DECONCATENATED=0
REORG_REPORTS=0
REORG_NONPASSING=0
REORG_DROPPED=0
REORG_SKIPPED=0

#------------------------------------------------------------------------------
# reorganise_sample_dir <sample_dir> [drop_nonpassing] [dry_run]
#
# Arguments:
#   sample_dir        Path to a single skera_*/ directory
#   drop_nonpassing   1 = delete non_passing files, 0 = move them (default 0)
#   dry_run           1 = print intended actions, 0 = execute (default 0)
#
# Returns:
#   0 on success, 1 if sample_dir is not a directory.
#
# Behaviour:
#   - Idempotent: re-running on an already-reorganised dir is a no-op
#     (the regexes only match files that haven't been moved yet).
#   - Subfolders that already exist are reused.
#   - Unrecognised files are left in place and counted as skipped.
#------------------------------------------------------------------------------
reorganise_sample_dir() {
    local sample_dir="${1%/}"
    local drop_nonpassing="${2:-0}"
    local dry_run="${3:-0}"

    REORG_DECONCATENATED=0
    REORG_REPORTS=0
    REORG_NONPASSING=0
    REORG_DROPPED=0
    REORG_SKIPPED=0

    if [[ ! -d "${sample_dir}" ]]; then
        return 1
    fi

    if [[ "${dry_run}" -eq 0 ]]; then
        mkdir -p "${sample_dir}/deconcatenated" "${sample_dir}/reports"
        if [[ "${drop_nonpassing}" -eq 0 ]]; then
            mkdir -p "${sample_dir}/nonpassing"
        fi
    fi

    local f bn
    shopt -s nullglob
    for f in "${sample_dir}"/*; do
        [[ -f "${f}" ]] || continue   # skip subdirs (incl. the ones we just made)
        bn=$(basename "${f}")

        # NB: order matters – non_passing must be checked before the generic
        # .skera.bam pattern, since `*.skera.non_passing.bam` also matches that.
        if   [[ "${bn}" =~ \.skera\.non_passing\.bam(\.pbi)?$ ]]; then
            if [[ "${drop_nonpassing}" -eq 1 ]]; then
                _reorg_drop "${f}" "${dry_run}"
                REORG_DROPPED=$((REORG_DROPPED + 1))
            else
                _reorg_move "${f}" "${sample_dir}/nonpassing" "${dry_run}"
                REORG_NONPASSING=$((REORG_NONPASSING + 1))
            fi
        elif [[ "${bn}" =~ \.skera\.bam(\.pbi)?$ ]]; then
            _reorg_move "${f}" "${sample_dir}/deconcatenated" "${dry_run}"
            REORG_DECONCATENATED=$((REORG_DECONCATENATED + 1))
        elif [[ "${bn}" =~ \.skera\.(summary\.csv|summary\.json|ligations\.csv|read_lengths\.csv|found_adapters\.csv\.gz)$ ]]; then
            _reorg_move "${f}" "${sample_dir}/reports" "${dry_run}"
            REORG_REPORTS=$((REORG_REPORTS + 1))
        else
            REORG_SKIPPED=$((REORG_SKIPPED + 1))
        fi
    done
    shopt -u nullglob

    return 0
}

#------------------------------------------------------------------------------
# locate_summary_file <sample_dir> <output_prefix>
#
# Echoes the path to the skera summary.csv (flat or reorganised), or empty
# string if not found. Used by polonius_cli.sh for resume logic.
#------------------------------------------------------------------------------
locate_summary_file() {
    local sample_dir="${1%/}"
    local output_prefix="$2"
    local flat="${sample_dir}/${output_prefix}.summary.csv"
    local reorg="${sample_dir}/reports/${output_prefix}.summary.csv"

    if   [[ -f "${flat}"  ]]; then echo "${flat}"
    elif [[ -f "${reorg}" ]]; then echo "${reorg}"
    else                           echo ""
    fi
}

#------------------------------------------------------------------------------
# Internal helpers
#------------------------------------------------------------------------------
_reorg_move() {
    local src="$1"
    local dest_dir="$2"
    local dry_run="$3"

    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] %-70s -> %s/\n' "$(basename "${src}")" "$(basename "${dest_dir}")" >&2
    else
        mv -- "${src}" "${dest_dir}/"
    fi
}

_reorg_drop() {
    local src="$1"
    local dry_run="$2"

    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] DROP %s\n' "$(basename "${src}")" >&2
    else
        rm -f -- "${src}"
    fi
}
