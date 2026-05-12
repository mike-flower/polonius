#!/usr/bin/env bash
#==============================================================================
# Polonius – shared reorganisation library
#==============================================================================
#
# Classifies and moves files from skera_<sample>/ output directories into the
# layout requested by --reorganise MODE. All modes move files; nothing is
# copied or symlinked.
#
# Classification rules (order matters – non_passing before generic .skera.bam):
#   nonpassing/      *.skera.non_passing.bam{,.pbi}
#   deconcatenated/  *.skera.bam{,.pbi}
#   reports/         *.skera.{summary.csv,summary.json,ligations.csv,
#                              read_lengths.csv,found_adapters.csv.gz}
#
# Modes:
#   by-sample-type   files moved into <sample>/{deconcatenated,reports,nonpassing}/
#                    skera_<sample>/ renamed to <sample>/
#   by-type          files moved into dir_out/{deconcatenated,reports,nonpassing}/
#                    skera_<sample>/ dirs removed once empty
#   by-type-sample   files moved into dir_out/{deconcatenated,reports,nonpassing}/<sample>/
#                    skera_<sample>/ dirs removed once empty
#
# Sourced by:
#   - scripts/polonius_cli.sh
#   - scripts/reorganise_polonius.sh
#
# This file should be sourced, not executed.
#==============================================================================

[[ "${_POLONIUS_REORGANISE_LIB_LOADED:-0}" == "1" ]] && return 0
_POLONIUS_REORGANISE_LIB_LOADED=1

#------------------------------------------------------------------------------
# Counters – reset and populated by reorganise_sample_dir(). Callers may read
# these after each call.
#------------------------------------------------------------------------------
REORG_DECONCATENATED=0
REORG_REPORTS=0
REORG_NONPASSING=0
REORG_DROPPED=0
REORG_SKIPPED=0

#------------------------------------------------------------------------------
# classify_file <basename>
#
# Echoes the type bucket for a file: "deconcatenated", "nonpassing", "reports",
# or "skip". Used internally and by reorganise_polonius.sh.
#------------------------------------------------------------------------------
classify_file() {
    local bn="$1"
    if   [[ "${bn}" =~ \.skera\.non_passing\.bam(\.pbi)?$ ]]; then
        echo "nonpassing"
    elif [[ "${bn}" =~ \.skera\.bam(\.pbi)?$ ]]; then
        echo "deconcatenated"
    elif [[ "${bn}" =~ \.skera\.(summary\.csv|summary\.json|ligations\.csv|read_lengths\.csv|found_adapters\.csv\.gz)$ ]]; then
        echo "reports"
    else
        echo "skip"
    fi
}

#------------------------------------------------------------------------------
# reorganise_sample_dir <skera_sample_dir> <mode> <dir_out>
#                       [drop_nonpassing] [dry_run]
#
# Arguments:
#   skera_sample_dir  Path to a skera_<sample>/ directory
#   mode              by-sample-type | by-type | by-type-sample
#   dir_out           Top-level output directory (used by by-type* modes)
#   drop_nonpassing   1 = delete non_passing files, 0 = move them (default 0)
#   dry_run           1 = print intended actions, 0 = execute (default 0)
#
# Returns:
#   0 on success, 1 if skera_sample_dir is not a directory.
#------------------------------------------------------------------------------
reorganise_sample_dir() {
    local skera_dir="${1%/}"
    local mode="$2"
    local dir_out="${3%/}"
    local drop_nonpassing="${4:-0}"
    local dry_run="${5:-0}"

    REORG_DECONCATENATED=0
    REORG_REPORTS=0
    REORG_NONPASSING=0
    REORG_DROPPED=0
    REORG_SKIPPED=0

    if [[ ! -d "${skera_dir}" ]]; then
        return 1
    fi

    # Derive the sample name by stripping the skera_ prefix
    local sample_name
    sample_name=$(basename "${skera_dir}")
    sample_name="${sample_name#skera_}"

    # Determine the target root for each file type based on mode
    # by-sample-type:  <skera_dir>/<type>/      (we rename the dir after)
    # by-type:         <dir_out>/<type>/
    # by-type-sample:  <dir_out>/<type>/<sample>/
    local dest_deconcatenated dest_reports dest_nonpassing
    case "${mode}" in
        by-sample-type)
            dest_deconcatenated="${skera_dir}/deconcatenated"
            dest_reports="${skera_dir}/reports"
            dest_nonpassing="${skera_dir}/nonpassing"
            ;;
        by-type)
            dest_deconcatenated="${dir_out}/deconcatenated"
            dest_reports="${dir_out}/reports"
            dest_nonpassing="${dir_out}/nonpassing"
            ;;
        by-type-sample)
            dest_deconcatenated="${dir_out}/deconcatenated/${sample_name}"
            dest_reports="${dir_out}/reports/${sample_name}"
            dest_nonpassing="${dir_out}/nonpassing/${sample_name}"
            ;;
        *)
            return 1
            ;;
    esac

    # Create destination directories upfront (skip nonpassing if dropping)
    if [[ "${dry_run}" -eq 0 ]]; then
        mkdir -p "${dest_deconcatenated}" "${dest_reports}"
        if [[ "${drop_nonpassing}" -eq 0 ]]; then
            mkdir -p "${dest_nonpassing}"
        fi
    fi

    # Move files
    local f bn bucket
    shopt -s nullglob
    for f in "${skera_dir}"/*; do
        [[ -f "${f}" ]] || continue
        bn=$(basename "${f}")
        bucket=$(classify_file "${bn}")

        case "${bucket}" in
            nonpassing)
                if [[ "${drop_nonpassing}" -eq 1 ]]; then
                    _reorg_drop "${f}" "${dry_run}"
                    REORG_DROPPED=$((REORG_DROPPED + 1))
                else
                    _reorg_move "${f}" "${dest_nonpassing}" "${dry_run}"
                    REORG_NONPASSING=$((REORG_NONPASSING + 1))
                fi
                ;;
            deconcatenated)
                _reorg_move "${f}" "${dest_deconcatenated}" "${dry_run}"
                REORG_DECONCATENATED=$((REORG_DECONCATENATED + 1))
                ;;
            reports)
                _reorg_move "${f}" "${dest_reports}" "${dry_run}"
                REORG_REPORTS=$((REORG_REPORTS + 1))
                ;;
            skip)
                REORG_SKIPPED=$((REORG_SKIPPED + 1))
                ;;
        esac
    done
    shopt -u nullglob

    # Post-move: for by-sample-type, rename skera_<sample>/ -> <sample>/
    # For by-type*, remove the now-empty skera_<sample>/ dir
    if [[ "${dry_run}" -eq 0 ]]; then
        case "${mode}" in
            by-sample-type)
                local dest_sample="${dir_out}/${sample_name}"
                if [[ ! -e "${dest_sample}" ]]; then
                    mv -- "${skera_dir}" "${dest_sample}"
                else
                    # Destination already exists (resume scenario): merge by moving subdirs
                    for subdir in "${skera_dir}"/*/; do
                        [[ -d "${subdir}" ]] || continue
                        local subdir_name
                        subdir_name=$(basename "${subdir}")
                        mkdir -p "${dest_sample}/${subdir_name}"
                        # Move any files that ended up in subdirs (idempotent)
                        shopt -s nullglob
                        for f in "${subdir}"*; do
                            [[ -f "${f}" ]] && mv -- "${f}" "${dest_sample}/${subdir_name}/"
                        done
                        shopt -u nullglob
                        rmdir --ignore-fail-on-non-empty "${subdir}"
                    done
                    rmdir --ignore-fail-on-non-empty "${skera_dir}"
                fi
                ;;
            by-type|by-type-sample)
                # Remove empty skera_<sample>/ dir
                rmdir --ignore-fail-on-non-empty "${skera_dir}"
                ;;
        esac
    else
        case "${mode}" in
            by-sample-type)
                printf '  [dry-run] RENAME %s -> %s\n' \
                    "$(basename "${skera_dir}")" "${sample_name}" >&2
                ;;
            by-type|by-type-sample)
                printf '  [dry-run] RMDIR  %s\n' "$(basename "${skera_dir}")" >&2
                ;;
        esac
    fi

    return 0
}

#------------------------------------------------------------------------------
# locate_summary_file <dir_out> <bam_name>
#
# Searches for the skera summary.csv across all locations it may occupy
# depending on the reorganisation mode. Echoes the path or empty string.
# Used by polonius_cli.sh for:
#   - resume logic (process_bam): skip already-completed samples
#   - summary generation (generate_summary): locate CSVs for the final report
#
# Arguments:
#   dir_out   Top-level output directory
#   bam_name  Input BAM basename without .bam (e.g. m84277_...bcM0001)
#------------------------------------------------------------------------------
locate_summary_file() {
    local dir_out="${1%/}"
    local bam_name="$2"
    local prefix="${bam_name}.skera"
    local csv="${prefix}.summary.csv"

    # Check all possible locations across all modes, in order:
    local candidates=(
        "${dir_out}/skera_${bam_name}/${csv}"                  # no reorganise (flat)
        "${dir_out}/skera_${bam_name}/reports/${csv}"          # by-sample-type (pre-rename)
        "${dir_out}/${bam_name}/reports/${csv}"                # by-sample-type (post-rename)
        "${dir_out}/reports/${csv}"                            # by-type
        "${dir_out}/reports/${bam_name}/${csv}"                # by-type-sample
    )

    local loc
    for loc in "${candidates[@]}"; do
        if [[ -f "${loc}" ]]; then
            echo "${loc}"
            return
        fi
    done
    echo ""
}

#------------------------------------------------------------------------------
# Internal helpers
#------------------------------------------------------------------------------
_reorg_move() {
    local src="$1" dest_dir="$2" dry_run="$3"
    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] MOVE %-70s -> %s/\n' \
            "$(basename "${src}")" "$(basename "${dest_dir}")" >&2
    else
        mv -- "${src}" "${dest_dir}/"
    fi
}

_reorg_drop() {
    local src="$1" dry_run="$2"
    if [[ "${dry_run}" -eq 1 ]]; then
        printf '  [dry-run] DROP %s\n' "$(basename "${src}")" >&2
    else
        rm -f -- "${src}"
    fi
}
