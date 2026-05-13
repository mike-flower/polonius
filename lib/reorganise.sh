#!/usr/bin/env bash
#==============================================================================
# Polonius – shared reorganisation library
#==============================================================================
#
# Classifies and moves files from skera output into the layout requested by
# --reorganise MODE. All modes move files; nothing is copied or symlinked.
#
# Classification rules (order is defensive – the regexes are mutually exclusive
# because ".skera.bam$" does not match ".skera.non_passing.bam"):
#   nonpassing/      *.skera.non_passing.bam{,.pbi}
#   deconcatenated/  *.skera.bam{,.pbi}
#   reports/         *.skera.{summary.csv,summary.json,ligations.csv,
#                              read_lengths.csv,found_adapters.csv.gz}
#
# Modes:
#   by-sample        files left flat inside <sample>/ — this is the same
#                    layout polonius produces by default, so the mode is
#                    just an explicit alias for "no --reorganise flag"
#   by-sample-type   move files into <sample>/{deconcatenated,reports,nonpassing}/
#   by-type          move files into dir_out/{deconcatenated,reports,nonpassing}/
#                    <sample>/ dirs removed once empty
#   by-type-sample   move files into dir_out/{deconcatenated,reports,nonpassing}/<sample>/
#                    <sample>/ dirs removed once empty
#
# Backwards compatibility: polonius up to v1.2 wrote per-sample output into
# skera_<sample>/ directories (with a "skera_" prefix). v1.3 drops that prefix,
# but reorganise_sample_dir still handles the old prefixed name correctly: the
# input directory's basename is stripped of any leading "skera_" before being
# used as the sample name.
#
# Two top-level functions:
#   reorganise_sample_dir   processes one per-sample directory. Used by
#                           polonius_cli.sh for per-sample post-skera reorg.
#   reorganise_path         walks an arbitrary path, classifies files by
#                           filename, and moves to the target layout. Used by
#                           reorganise_polonius.sh and works bidirectionally
#                           between any pair of layouts.
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
# Counters – reset and populated by each reorganise function. Callers may read
# these after each call. REORG_INPLACE counts files already at their target
# location (no-op move); these are also counted in their bucket totals so the
# reported numbers reflect the final state, not just what changed.
#------------------------------------------------------------------------------
REORG_DECONCATENATED=0
REORG_REPORTS=0
REORG_NONPASSING=0
REORG_DROPPED=0
REORG_SKIPPED=0
REORG_INPLACE=0

#------------------------------------------------------------------------------
# classify_file <basename>
#
# Echoes the type bucket for a file: "deconcatenated", "nonpassing", "reports",
# or "skip".
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
# sample_name_from_filename <basename>
#
# Echoes the sample name implied by a skera output filename. Uses the shortest
# match of ".skera.*" so file names that themselves contain ".skera." earlier
# (rare in practice) are handled correctly. Returns empty for non-skera names.
#------------------------------------------------------------------------------
sample_name_from_filename() {
    local bn="$1"
    if [[ "${bn}" == *.skera.* ]]; then
        # %.skera.* removes the shortest trailing match (i.e. from the last .skera.)
        echo "${bn%.skera.*}"
    else
        echo ""
    fi
}

#------------------------------------------------------------------------------
# _dest_dir_for <mode> <bucket> <sample> <dir_out>
#
# Echoes the destination directory for a (mode, bucket, sample) tuple.
# Used by both reorganise_sample_dir and reorganise_path.
#------------------------------------------------------------------------------
_dest_dir_for() {
    local mode="$1" bucket="$2" sample="$3" dir_out="${4%/}"
    case "${mode}" in
        by-sample)
            echo "${dir_out}/${sample}"
            ;;
        by-sample-type)
            case "${bucket}" in
                deconcatenated) echo "${dir_out}/${sample}/deconcatenated" ;;
                reports)        echo "${dir_out}/${sample}/reports"        ;;
                nonpassing)     echo "${dir_out}/${sample}/nonpassing"     ;;
            esac
            ;;
        by-type)
            case "${bucket}" in
                deconcatenated) echo "${dir_out}/deconcatenated" ;;
                reports)        echo "${dir_out}/reports"        ;;
                nonpassing)     echo "${dir_out}/nonpassing"     ;;
            esac
            ;;
        by-type-sample)
            case "${bucket}" in
                deconcatenated) echo "${dir_out}/deconcatenated/${sample}" ;;
                reports)        echo "${dir_out}/reports/${sample}"        ;;
                nonpassing)     echo "${dir_out}/nonpassing/${sample}"     ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# reorganise_sample_dir <sample_dir> <mode> <dir_out>
#                       [drop_nonpassing] [dry_run]
#
# Processes one per-sample directory. Used by polonius_cli.sh's per-sample
# post-skera flow. The input directory is expected to contain flat skera
# output files. Its basename may be either <sample>/ (v1.3+) or the legacy
# skera_<sample>/ (v1.2); a leading "skera_" is stripped from the basename
# before it is used as the sample name.
#
# Arguments:
#   sample_dir        Path to a per-sample directory containing flat skera output
#   mode              by-sample | by-sample-type | by-type | by-type-sample
#   dir_out           Top-level output directory
#   drop_nonpassing   1 = delete non_passing files, 0 = move them (default 0)
#   dry_run           1 = print intended actions, 0 = execute (default 0)
#
# Returns:
#   0 on success, 1 if sample_dir is not a directory or mode is invalid.
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
    REORG_INPLACE=0

    if [[ ! -d "${skera_dir}" ]]; then
        return 1
    fi

    case "${mode}" in
        by-sample|by-sample-type|by-type|by-type-sample) ;;
        *) return 1 ;;
    esac

    # Derive the sample name. Strip an optional leading "skera_" so the legacy
    # v1.2 directory naming (skera_<sample>/) still resolves correctly.
    local sample_name
    sample_name=$(basename "${skera_dir}")
    sample_name="${sample_name#skera_}"

    # Tally + move files. by-sample doesn't move files into type subdirs; it
    # just counts buckets and lets the directory rename handle relocation.
    local f bn bucket dest_dir
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
                    continue
                fi
                REORG_NONPASSING=$((REORG_NONPASSING + 1))
                ;;
            deconcatenated)
                REORG_DECONCATENATED=$((REORG_DECONCATENATED + 1))
                ;;
            reports)
                REORG_REPORTS=$((REORG_REPORTS + 1))
                ;;
            skip)
                REORG_SKIPPED=$((REORG_SKIPPED + 1))
                continue
                ;;
        esac

        # For by-sample, files stay flat inside the soon-to-be-renamed dir.
        # For all other modes, move into the right subdir under dir_out.
        if [[ "${mode}" != "by-sample" ]]; then
            dest_dir=$(_dest_dir_for "${mode}" "${bucket}" "${sample_name}" "${dir_out}") || return 1
            if [[ "${dry_run}" -eq 0 ]]; then
                mkdir -p "${dest_dir}"
            fi
            _reorg_move "${f}" "${dest_dir}" "${dry_run}"
        fi
    done
    shopt -u nullglob

    # Post-move: rename skera_<sample>/ -> <sample>/ for by-sample{,-type},
    # remove the (now-empty) input dir for by-type{,-sample}. If the input
    # directory is already at its target name (the common case in v1.3 where
    # polonius creates <sample>/ directly), the by-sample{,-type} branches
    # become no-ops on the directory level — only file moves are needed.
    if [[ "${dry_run}" -eq 0 ]]; then
        case "${mode}" in
            by-sample|by-sample-type)
                local dest_sample="${dir_out}/${sample_name}"
                if [[ "${skera_dir}" -ef "${dest_sample}" ]]; then
                    : # input dir is already the target dir; nothing to do
                elif [[ ! -e "${dest_sample}" ]]; then
                    mv -- "${skera_dir}" "${dest_sample}"
                else
                    # Destination already exists (e.g. fresh skera output and
                    # a stale legacy skera_<sample>/ side-by-side). Merge by
                    # moving everything inside skera_dir into dest_sample.
                    shopt -s nullglob
                    for f in "${skera_dir}"/*; do
                        bn=$(basename "${f}")
                        if [[ -f "${f}" ]]; then
                            mv -- "${f}" "${dest_sample}/"
                        elif [[ -d "${f}" ]]; then
                            mkdir -p "${dest_sample}/${bn}"
                            local inner
                            for inner in "${f}"/*; do
                                [[ -e "${inner}" ]] && mv -- "${inner}" "${dest_sample}/${bn}/"
                            done
                            _reorg_rmdir_if_empty "${f}"
                        fi
                    done
                    shopt -u nullglob
                    _reorg_rmdir_if_empty "${skera_dir}"
                fi
                ;;
            by-type|by-type-sample)
                _reorg_rmdir_if_empty "${skera_dir}"
                ;;
        esac
    else
        case "${mode}" in
            by-sample|by-sample-type)
                local dest_sample_dry="${dir_out}/${sample_name}"
                if [[ "${skera_dir}" -ef "${dest_sample_dry}" ]]; then
                    : # already at target; nothing to print
                else
                    printf '  [dry-run] RENAME %s -> %s\n' \
                        "$(basename "${skera_dir}")" "${sample_name}" >&2
                fi
                ;;
            by-type|by-type-sample)
                printf '  [dry-run] RMDIR  %s\n' "$(basename "${skera_dir}")" >&2
                ;;
        esac
    fi

    return 0
}

#------------------------------------------------------------------------------
# reorganise_path <input_path> <target_mode> <dir_out>
#                 [drop_nonpassing] [dry_run]
#
# Walks input_path recursively, classifies every file by its filename, derives
# the sample name from the filename, and moves it to the target layout. This
# works regardless of the source layout because classification is filename-
# based, not directory-based. After moves, any empty directories below
# input_path (and dir_out, if different) are cleaned up.
#
# This is the bidirectional migrator used by reorganise_polonius.sh: any
# source layout (raw skera, by-sample, by-sample-type, by-type, by-type-sample)
# can be converted to any target layout. Files already at their target
# location are detected via -ef (inode test) and counted as in-place.
#
# Arguments:
#   input_path        Directory to walk for skera files
#   target_mode       by-sample | by-sample-type | by-type | by-type-sample
#   dir_out           Top-level destination directory (often == input_path
#                     for an in-place migration)
#   drop_nonpassing   1 = delete non_passing files, 0 = move them (default 0)
#   dry_run           1 = print intended actions, 0 = execute (default 0)
#
# Returns:
#   0 on success, 1 if input_path is not a directory or target_mode is invalid.
#------------------------------------------------------------------------------
reorganise_path() {
    local input_path="${1%/}"
    local target_mode="$2"
    local dir_out="${3%/}"
    local drop_nonpassing="${4:-0}"
    local dry_run="${5:-0}"

    REORG_DECONCATENATED=0
    REORG_REPORTS=0
    REORG_NONPASSING=0
    REORG_DROPPED=0
    REORG_SKIPPED=0
    REORG_INPLACE=0

    if [[ ! -d "${input_path}" ]]; then
        return 1
    fi

    case "${target_mode}" in
        by-sample|by-sample-type|by-type|by-type-sample) ;;
        *) return 1 ;;
    esac

    # Stage the file list to a temp file so the walk is stable while we move
    # things around. find with -print0 handles awkward filenames. Note: the
    # SC2094 disable on the while loop below is needed because shellcheck
    # flags writing-then-reading the same file as suspicious, but here the
    # write and read are sequential, not pipelined.
    local tmpfile
    tmpfile=$(mktemp)
    find "${input_path}" -type f -print0 > "${tmpfile}"

    local file bn bucket sample dest_dir dest_file
    # shellcheck disable=SC2094  # see tmpfile comment above
    while IFS= read -r -d '' file; do
        bn=$(basename "${file}")
        bucket=$(classify_file "${bn}")

        if [[ "${bucket}" == "skip" ]]; then
            REORG_SKIPPED=$((REORG_SKIPPED + 1))
            continue
        fi

        sample=$(sample_name_from_filename "${bn}")
        if [[ -z "${sample}" ]]; then
            # Shouldn't happen if classify_file matched a known bucket
            REORG_SKIPPED=$((REORG_SKIPPED + 1))
            continue
        fi

        # Drop non-passing files if requested
        if [[ "${bucket}" == "nonpassing" && "${drop_nonpassing}" -eq 1 ]]; then
            _reorg_drop "${file}" "${dry_run}"
            REORG_DROPPED=$((REORG_DROPPED + 1))
            continue
        fi

        dest_dir=$(_dest_dir_for "${target_mode}" "${bucket}" "${sample}" "${dir_out}") || {
            rm -f "${tmpfile}"
            return 1
        }
        dest_file="${dest_dir}/${bn}"

        # Already in place? Count it without moving.
        if [[ -e "${dest_file}" ]] && [[ "${file}" -ef "${dest_file}" ]]; then
            REORG_INPLACE=$((REORG_INPLACE + 1))
        else
            if [[ "${dry_run}" -eq 0 ]]; then
                mkdir -p "${dest_dir}"
            fi
            _reorg_move "${file}" "${dest_dir}" "${dry_run}"
        fi

        case "${bucket}" in
            deconcatenated) REORG_DECONCATENATED=$((REORG_DECONCATENATED + 1)) ;;
            reports)        REORG_REPORTS=$((REORG_REPORTS + 1))               ;;
            nonpassing)     REORG_NONPASSING=$((REORG_NONPASSING + 1))         ;;
        esac
    done < "${tmpfile}"
    rm -f "${tmpfile}"

    # Clean up empty directories under input_path (and dir_out if different).
    # -mindepth 1 protects the root itself from removal.
    if [[ "${dry_run}" -eq 0 ]]; then
        find "${input_path}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        if [[ "${dir_out}" != "${input_path}" && -d "${dir_out}" ]]; then
            find "${dir_out}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        fi
    fi

    return 0
}

#------------------------------------------------------------------------------
# locate_summary_file <dir_out> <bam_name>
#
# Searches for the skera summary.csv across all locations it may occupy
# depending on the reorganisation mode (and the legacy v1.2 layout). Echoes
# the path or empty string.
#
# Used by polonius_cli.sh's generate_summary() to find each sample's CSV
# regardless of which layout the run ended up producing.
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
        "${dir_out}/${bam_name}/${csv}"                        # new default / by-sample
        "${dir_out}/${bam_name}/reports/${csv}"                # by-sample-type
        "${dir_out}/reports/${csv}"                            # by-type
        "${dir_out}/reports/${bam_name}/${csv}"                # by-type-sample
        "${dir_out}/skera_${bam_name}/${csv}"                  # legacy v1.2 raw skera output
        "${dir_out}/skera_${bam_name}/reports/${csv}"          # legacy v1.2 by-sample-type pre-rename
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
            "$(basename "${src}")" "${dest_dir}" >&2
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

# Portable replacement for `rmdir --ignore-fail-on-non-empty`. The GNU flag
# is not available on stock macOS rmdir; this works everywhere by discarding
# the failure when the directory still contains files. `|| true` keeps it
# safe under `set -e`.
_reorg_rmdir_if_empty() {
    rmdir -- "$1" 2>/dev/null || true
}
