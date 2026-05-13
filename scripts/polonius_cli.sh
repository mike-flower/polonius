#!/bin/bash
#==============================================================================
# Polonius - PacBio Kinnex Deconcatenation Pipeline
#==============================================================================
#
# A wrapper for PacBio's skera tool for splitting Kinnex/MAS-Seq concatenated
# HiFi reads into their constituent S-reads.
# Processes all BAM files in a directory using PacBio's skera tool.
#
# Author: Michael Flower
# Institution: UCL Queen Square Institute of Neurology
# Version: 1.4.0
#
#==============================================================================

set -euo pipefail

#==============================================================================
# SCRIPT DIRECTORY
#==============================================================================

# Resolve the script's real location, following symlinks. This lets the
# script be invoked via a symlink (e.g. ~/bin/polonius -> /repo/polonius)
# and still find its sibling scripts and libraries. Portable bash idiom
# that works on macOS (no GNU readlink -f required).
_src="${BASH_SOURCE[0]}"
while [[ -L "${_src}" ]]; do
    _dir="$( cd -P "$( dirname "${_src}" )" && pwd )"
    _src="$(readlink "${_src}")"
    [[ "${_src}" != /* ]] && _src="${_dir}/${_src}"
done
SCRIPT_DIR="$( cd -P "$( dirname "${_src}" )" && pwd )"
unset _src _dir
# Get the root polonius directory (parent of scripts/)
POLONIUS_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"

# Source shared reorganisation library (lives at the polonius repo root, not under scripts/)
# shellcheck source=../lib/reorganise.sh
source "${POLONIUS_ROOT}/lib/reorganise.sh"

#==============================================================================
# DEFAULTS
#==============================================================================

VERSION="1.4.0"

# Required parameters (no defaults)
DIR_DATA=""
DIR_OUT=""
ADAPTER_REF=""

# Optional parameters
FILE_PATTERN="*.bam"
THREADS=0   # 0 = auto-detect

# Skera arguments (pass-through to skera)
SKERA_ARGS=""

# Reorganisation mode. Values:
#   by-sample        explicit alias for the default (no flag): per-sample
#                    directories with files flat inside (<sample>/)
#   by-sample-type   move files into <sample>/{deconcatenated,reports,nonpassing}/
#   by-type          move files into dir_out/{deconcatenated,reports,nonpassing}/
#   by-type-sample   move files into dir_out/{deconcatenated,reports,nonpassing}/<sample>/
#   (unset)          same as by-sample: <sample>/ directories with files flat inside
REORGANISE=""

DROP_NONPASSING="FALSE"

# Execution options
DRY_RUN="FALSE"
VERBOSE="FALSE"

# Runtime globals (set during execution)
SKERA_VERSION=""
LOG_DIR=""
LOG_FILE=""
RUN_TIMESTAMP=""
INPUT_FILES=()
FAILED_FILES=()

#==============================================================================
# COLOUR OUTPUT
# Colours are disabled automatically when stdout is not a TTY (e.g. in log
# files or SGE job output), so the log file remains clean and grep-friendly.
#==============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

#==============================================================================
# LOGGING
#==============================================================================

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_info() {
    echo -e "${GREEN}[$(timestamp)]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[$(timestamp)] WARNING:${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[$(timestamp)] ERROR:${NC} $*" >&2
}

log_debug() {
    if [[ "${VERBOSE}" == "TRUE" ]]; then
        echo -e "${BLUE}[$(timestamp)] DEBUG:${NC} $*"
    fi
}

log_section() {
    echo ""
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo ""
}

#==============================================================================
# USAGE
#==============================================================================

show_help() {
    cat << 'EOF'
Polonius - PacBio Kinnex Deconcatenation Pipeline
=================================================

A wrapper for PacBio's skera tool for splitting Kinnex/MAS-Seq concatenated
HiFi reads into their constituent S-reads.
Processes all BAM files in a directory sequentially.

USAGE:
    ./polonius --dir_data DIR --dir_out DIR --adapter_ref FILE [OPTIONS]

REQUIRED ARGUMENTS:
    --dir_data DIR          Directory containing input HiFi BAM files
                            (typically already split by terminal SMRTbell adapter)
    --dir_out DIR           Output directory for deconcatenated S-reads
    --adapter_ref FILE      MAS adapter reference FASTA file
                            (e.g., mas8_primers.fasta for Kinnex full-length RNA;
                             mas12_primers.fasta for Kinnex 16S;
                             mas16_primers.fasta for Kinnex single-cell RNA)

OPTIONAL ARGUMENTS:
    --file_pattern GLOB     Pattern to match BAM files (default: *.bam)
    --threads N             Number of threads (default: auto-detect)

SKERA ARGUMENTS:
    --skera_args "ARGS"     Additional skera arguments (default: "")

OUTPUT ORGANISATION:
    --reorganise MODE       Output layout. MODE must be one of:
                              by-sample       per-sample directories, files flat
                                              inside each. This is also the default
                                              layout when --reorganise is omitted:
                                              <sample>/
                              by-sample-type  per-sample directories with file-type
                                              subdirs inside each:
                                              <sample>/{deconcatenated,reports,nonpassing}/
                              by-type         top-level file-type directories, all
                                              samples pooled flat inside each:
                                              {deconcatenated,reports,nonpassing}/
                              by-type-sample  top-level file-type directories with
                                              per-sample subdirs inside each:
                                              {deconcatenated,reports,nonpassing}/<sample>/
                            Omit the flag for the default (== by-sample).
    --no-reorganise         Explicit no-op; same as omitting --reorganise
                            (and same as --reorganise by-sample)
    --drop-nonpassing       Delete *.skera.non_passing.bam{,.pbi} files AFTER
                            skera has written them. Polonius-only post-skera
                            step (skera has no flag to skip the files at
                            source). Default off; non-passing files are kept.
                            Irreversible; requires --reorganise.

EXECUTION OPTIONS:
    --dry-run               Show what would be run without executing
                            (--dry_run is also accepted, for back-compat)
    --verbose               Enable verbose output
    --help                  Show this help message

EXAMPLES:

    # Default layout (per-sample dirs, files flat inside)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta

    # Same as above, but stated explicitly
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-sample

    # Per-sample dirs with file-type subdirs
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-sample-type

    # All samples pooled by file type (recommended for Ophelia)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-type
    # Then point Ophelia at ~/results/deconcat/deconcatenated

    # By file type with per-sample subdirs (larger-scale runs)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-type-sample

    # Drop non-passing BAMs after skera writes them (saves disk space; irreversible)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-type --drop-nonpassing

    # Process only specific BAM files
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-type \
        --file_pattern "*bcM000*.bam"

    # Dry run to see what would happen
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise by-type --dry-run

OUTPUT STRUCTURE:

    no --reorganise flag (== --reorganise by-sample) — per-sample dirs, files flat inside:
        dir_out/
        ├── m84277_...bcM0001/
        │   ├── m84277_...bcM0001.skera.bam
        │   ├── m84277_...bcM0001.skera.bam.pbi
        │   ├── m84277_...bcM0001.skera.non_passing.bam
        │   ├── m84277_...bcM0001.skera.non_passing.bam.pbi
        │   ├── m84277_...bcM0001.skera.summary.csv
        │   ├── m84277_...bcM0001.skera.summary.json
        │   ├── m84277_...bcM0001.skera.ligations.csv
        │   ├── m84277_...bcM0001.skera.read_lengths.csv
        │   └── m84277_...bcM0001.skera.found_adapters.csv.gz
        ├── m84277_...bcM0002/
        │   └── ...
        └── polonius_summary.txt

    --reorganise by-sample-type — per-sample dirs with type subdirs:
        dir_out/
        ├── m84277_...bcM0001/
        │   ├── deconcatenated/    # *.skera.bam, *.skera.bam.pbi
        │   ├── reports/           # *.summary.*, *.ligations.csv, *.read_lengths.csv, *.found_adapters.csv.gz
        │   └── nonpassing/        # *.non_passing.* (omitted with --drop-nonpassing)
        ├── m84277_...bcM0002/
        │   └── ...
        └── polonius_summary.txt

    --reorganise by-type — top-level type dirs, all samples flat:
        dir_out/
        ├── deconcatenated/
        │   ├── m84277_...bcM0001.skera.bam
        │   ├── m84277_...bcM0001.skera.bam.pbi
        │   ├── m84277_...bcM0002.skera.bam
        │   └── ...
        ├── reports/
        │   ├── m84277_...bcM0001.skera.summary.csv
        │   └── ...
        ├── nonpassing/            # omitted with --drop-nonpassing
        │   └── ...
        └── polonius_summary.txt

    --reorganise by-type-sample — top-level type dirs with per-sample subdirs:
        dir_out/
        ├── deconcatenated/
        │   ├── m84277_...bcM0001/
        │   │   ├── *.skera.bam
        │   │   └── *.skera.bam.pbi
        │   └── m84277_...bcM0002/
        ├── reports/
        │   └── (same pattern)
        ├── nonpassing/            # omitted with --drop-nonpassing
        │   └── (same pattern)
        └── polonius_summary.txt

    Logs (in polonius installation directory):
        polonius/logs/YYYYMMDD_HHMMSS/
        ├── polonius.log
        └── polonius_params.txt

NOTES:
    - All reorganisation modes move files; nothing is copied or symlinked.
    - Skera is internally parallelised; files are processed sequentially.
    - Requires skera (pbskera) from bioconda (conda install -c bioconda pbskera).
    - To migrate an existing dir_out to a different layout without re-running
      skera, use scripts/reorganise_polonius.sh.

EOF
}

#==============================================================================
# ARGUMENT PARSING
#==============================================================================

parse_args() {
    # Helper: ensure flag $1 has a value $2 that isn't another flag.
    # Usage: _need_value <flag-name> "$@" inside each value-taking case.
    _need_value() {
        local flag="$1" next="${2:-}"
        if [[ -z "${next}" || "${next}" == --* ]]; then
            log_error "${flag} requires a value"
            log_error "Use --help for usage information"
            exit 1
        fi
    }

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir_data)
                _need_value "--dir_data" "${2:-}"
                DIR_DATA="$2"
                shift 2
                ;;
            --dir_out)
                _need_value "--dir_out" "${2:-}"
                DIR_OUT="$2"
                shift 2
                ;;
            --adapter_ref)
                _need_value "--adapter_ref" "${2:-}"
                ADAPTER_REF="$2"
                shift 2
                ;;
            --file_pattern)
                _need_value "--file_pattern" "${2:-}"
                FILE_PATTERN="$2"
                shift 2
                ;;
            --threads)
                _need_value "--threads" "${2:-}"
                THREADS="$2"
                shift 2
                ;;
            --skera_args)
                # --skera_args allows --foo as a value (it's a pass-through),
                # so only check that *something* follows.
                if [[ $# -lt 2 ]]; then
                    log_error "--skera_args requires a value"
                    exit 1
                fi
                SKERA_ARGS="$2"
                shift 2
                ;;
            --reorganise|--reorganize)
                if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                    log_error "--reorganise requires a mode: --reorganise MODE"
                    log_error "Valid modes: by-sample, by-sample-type, by-type, by-type-sample"
                    log_error "Use --no-reorganise (or omit the flag) to leave output as-is"
                    exit 1
                fi
                REORGANISE="$2"
                shift 2
                ;;
            --no-reorganise|--no-reorganize)
                REORGANISE=""
                shift
                ;;
            --drop-nonpassing)
                DROP_NONPASSING="TRUE"
                shift
                ;;
            --dry-run|--dry_run)
                DRY_RUN="TRUE"
                shift
                ;;
            --verbose)
                VERBOSE="TRUE"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                if [[ "$1" == --*=* ]]; then
                    log_error "$1"
                    log_error "  Arguments use space separation: '--flag value', not '--flag=value'."
                else
                    log_error "Unknown option: $1"
                fi
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

#==============================================================================
# VALIDATION
#==============================================================================

validate_inputs() {
    local errors=0

    log_info "Validating inputs..."

    # Required parameters
    if [[ -z "${DIR_DATA}" ]]; then
        log_error "Missing required argument: --dir_data"
        errors=$((errors + 1))
    elif [[ ! -d "${DIR_DATA}" ]]; then
        log_error "Data directory not found: ${DIR_DATA}"
        errors=$((errors + 1))
    fi

    if [[ -z "${DIR_OUT}" ]]; then
        log_error "Missing required argument: --dir_out"
        errors=$((errors + 1))
    fi

    if [[ -z "${ADAPTER_REF}" ]]; then
        log_error "Missing required argument: --adapter_ref"
        errors=$((errors + 1))
    elif [[ ! -f "${ADAPTER_REF}" ]]; then
        log_error "Adapter reference file not found: ${ADAPTER_REF}"
        errors=$((errors + 1))
    fi

    # Refuse --dir_data == --dir_out. The stale-output sweep walks --dir_out
    # for *.skera.* files and deletes anything matching the current input's
    # sample name; if --dir_data == --dir_out and any input BAM happens to
    # have .skera. in its name (e.g. running polonius on a previously
    # polonius'd directory), the input would be deleted before skera runs.
    # Normalise both paths if they exist on disk; otherwise compare literally.
    if [[ -n "${DIR_DATA}" && -n "${DIR_OUT}" ]]; then
        local data_norm="${DIR_DATA}" out_norm="${DIR_OUT}"
        [[ -d "${DIR_DATA}" ]] && data_norm=$(cd "${DIR_DATA}" && pwd)
        [[ -d "${DIR_OUT}"  ]] && out_norm=$(cd  "${DIR_OUT}"  && pwd)
        if [[ "${data_norm}" == "${out_norm}" ]]; then
            log_error "--dir_data and --dir_out must not be the same path: ${data_norm}"
            log_error "  Output cannot share a directory with the input BAMs."
            errors=$((errors + 1))
        fi
    fi

    # Validate threads is a non-negative integer
    if [[ -n "${THREADS}" && ! "${THREADS}" =~ ^[0-9]+$ ]]; then
        log_error "--threads must be a non-negative integer, got: ${THREADS}"
        errors=$((errors + 1))
    fi

    # Validate --reorganise mode
    case "${REORGANISE}" in
        ""|by-sample|by-sample-type|by-type|by-type-sample)
            ;;
        *)
            log_error "Invalid --reorganise mode: '${REORGANISE}'"
            log_error "Valid modes: by-sample, by-sample-type, by-type, by-type-sample"
            errors=$((errors + 1))
            ;;
    esac

    # --drop-nonpassing requires --reorganise
    if [[ "${DROP_NONPASSING}" == "TRUE" && -z "${REORGANISE}" ]]; then
        log_error "--drop-nonpassing requires --reorganise MODE"
        log_error "  (to keep the default layout while still dropping non-passing files,"
        log_error "   pass --reorganise by-sample --drop-nonpassing)"
        errors=$((errors + 1))
    fi

    if [[ ${errors} -gt 0 ]]; then
        echo ""
        echo "Use --help for usage information"
        exit 1
    fi

    log_info "Validation complete"
}

#==============================================================================
# ENVIRONMENT SETUP
#==============================================================================

setup_environment() {
    log_info "Setting up environment..."

    # Detect and activate conda/micromamba environment
    if command -v micromamba &> /dev/null; then
        log_debug "Found micromamba"
        eval "$(micromamba shell hook --shell bash 2>/dev/null)" || true
        if micromamba activate lima 2>/dev/null; then
            log_debug "Activated lima environment (micromamba)"
        else
            log_debug "Could not activate lima environment via micromamba, checking PATH"
        fi
    elif command -v conda &> /dev/null; then
        log_debug "Found conda"
        # Source conda for Myriad/HPC environments
        if [[ -n "${UCL_CONDA_PATH:-}" ]]; then
            source "${UCL_CONDA_PATH}/etc/profile.d/conda.sh"
        elif [[ -f "${CONDA_PREFIX:-}/etc/profile.d/conda.sh" ]]; then
            source "${CONDA_PREFIX}/etc/profile.d/conda.sh"
        fi
        eval "$(conda shell.bash hook 2>/dev/null)" || true
        if conda activate lima 2>/dev/null; then
            log_debug "Activated lima environment (conda)"
        else
            log_debug "Could not activate lima environment via conda, checking PATH"
        fi
    else
        log_debug "No conda/micromamba found, assuming skera is in PATH"
    fi

    # Check skera is available
    if ! command -v skera &> /dev/null; then
        log_error "skera not found in PATH"
        echo ""
        echo "To install skera:"
        echo "  conda install -c bioconda pbskera"
        echo ""
        echo "On UCL Myriad:"
        echo "  module load python/miniconda3/24.3.0-0"
        echo "  source \$UCL_CONDA_PATH/etc/profile.d/conda.sh"
        echo "  conda activate lima      # or whichever env has skera"
        echo "  conda install -c bioconda pbskera"
        exit 1
    fi

    SKERA_VERSION=$(skera --version 2>&1 | head -1)
    log_info "Using skera: ${SKERA_VERSION}"
}

#==============================================================================
# ADAPTER REFERENCE SANITY CHECK
#==============================================================================

check_adapter_ref() {
    local n_entries
    n_entries=$(grep -c "^>" "${ADAPTER_REF}" 2>/dev/null || echo 0)

    log_info "Adapter reference: ${ADAPTER_REF}"
    log_info "  Entries: ${n_entries}"

    if [[ ${n_entries} -eq 0 ]]; then
        log_error "No FASTA entries found in adapter reference"
        exit 1
    fi

    # Inform user of likely Kinnex kit based on entry count.
    # An N-segment Kinnex array requires N+1 unique MAS adapters.
    case ${n_entries} in
        9)  log_info "  -> 8-fold concatenation (Kinnex full-length RNA kit, MAS8)" ;;
        13) log_info "  -> 12-fold concatenation (Kinnex 16S rRNA kit, MAS12)"      ;;
        17) log_info "  -> 16-fold concatenation (Kinnex single-cell RNA kit, MAS16)" ;;
        *)  log_warn "  -> Unusual entry count (${n_entries}); expected 9, 13 or 17 for standard Kinnex kits" ;;
    esac
}

#==============================================================================
# FIND INPUT FILES
#==============================================================================

find_input_files() {
    log_info "Searching for BAM files matching: ${FILE_PATTERN}"

    INPUT_FILES=()
    while IFS= read -r -d '' file; do
        INPUT_FILES+=("$file")
    done < <(find "${DIR_DATA}" -maxdepth 1 -name "${FILE_PATTERN}" -type f -print0 | sort -z)

    if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
        log_error "No BAM files found in ${DIR_DATA} matching pattern: ${FILE_PATTERN}"
        exit 1
    fi

    log_info "Found ${#INPUT_FILES[@]} BAM file(s) to process:"
    for f in "${INPUT_FILES[@]}"; do
        echo "    - $(basename "$f")"
    done
}

#==============================================================================
# REORGANISE WRAPPER
# Calls reorganise_sample_dir() from lib/reorganise.sh and logs the result.
#==============================================================================

reorganise_with_logging() {
    local skera_dir="$1"
    local label="${2:-Reorganised}"

    local drop_flag=0
    [[ "${DROP_NONPASSING}" == "TRUE" ]] && drop_flag=1

    local dry_flag=0
    [[ "${DRY_RUN}" == "TRUE" ]] && dry_flag=1

    if reorganise_sample_dir "${skera_dir}" "${REORGANISE}" "${DIR_OUT}" \
            "${drop_flag}" "${dry_flag}"; then
        local total=$((REORG_DECONCATENATED + REORG_REPORTS + REORG_NONPASSING + REORG_DROPPED))
        if [[ ${total} -gt 0 ]]; then
            # by-sample mode doesn't move files (they stay flat in <sample>/),
            # so the counts reflect classification only. Re-label accordingly
            # to avoid overclaiming.
            local action="${label}"
            if [[ "${REORGANISE}" == "by-sample" ]]; then
                action="Classified (no moves; by-sample layout)"
            fi
            local msg="  ${action}: deconcatenated=${REORG_DECONCATENATED}, reports=${REORG_REPORTS}, nonpassing=${REORG_NONPASSING}"
            [[ "${DROP_NONPASSING}" == "TRUE" ]] && msg="${msg}, dropped=${REORG_DROPPED}"
            log_info "${msg}"
        else
            log_warn "  ${label}: no classifiable files found in $(basename "${skera_dir}") (skipped=${REORG_SKIPPED})"
        fi
    else
        log_debug "  Reorganise skipped (no sample dir): ${skera_dir}"
    fi
}

#==============================================================================
# PROCESS SINGLE BAM FILE
#==============================================================================

process_bam() {
    local input_bam="$1"
    local bam_name
    bam_name=$(basename "${input_bam}" .bam)

    # Per-sample output directory. Named after the input BAM stem with no
    # added prefix — skera output files keep .skera in their basename so the
    # directory name doesn't need to repeat it.
    local output_subdir
    output_subdir="${DIR_OUT}/${bam_name}"

    local output_prefix="${bam_name}.skera"
    local output_bam="${output_subdir}/${output_prefix}.bam"

    echo ""
    log_info "Processing: ${bam_name}"
    log_info "  Input:  ${input_bam}"
    log_info "  Output: ${output_subdir}/"

    # Clean up any stale output for THIS sample from prior runs. We walk
    # DIR_OUT for files matching *.skera.* and remove only those whose
    # sample-name-derived-from-filename equals this sample. Other samples'
    # files (whether from this run or earlier) are untouched. This guarantees
    # the run is "fresh" for each input BAM and prevents the final-pass
    # reorganise from silently overwriting new files with stale duplicates
    # left over in a different layout.
    if [[ "${DRY_RUN}" != "TRUE" && -d "${DIR_OUT}" ]]; then
        local stale_count=0
        while IFS= read -r -d '' stale_file; do
            local stale_bn
            stale_bn=$(basename "${stale_file}")
            local stale_sample
            stale_sample=$(sample_name_from_filename "${stale_bn}")
            if [[ "${stale_sample}" == "${bam_name}" ]]; then
                rm -f -- "${stale_file}"
                stale_count=$((stale_count + 1))
            fi
        done < <(find "${DIR_OUT}" -type f -name "*.skera.*" -print0 2>/dev/null)
        if [[ ${stale_count} -gt 0 ]]; then
            log_info "  Removed ${stale_count} stale output file(s) from previous run"
        fi
        # Sweep up any directories left empty by the removals (e.g. a prior
        # by-sample-type's <sample>/{deconcatenated,reports,nonpassing}/ tree,
        # or a legacy v1.2 skera_<sample>/ dir).
        find "${DIR_OUT}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi

    # Build skera command: skera split <input> <adapters> <output>
    local skera_cmd=("skera" "split")

    # Add threads if specified
    if [[ "${THREADS}" -gt 0 ]]; then
        skera_cmd+=("--num-threads" "${THREADS}")
    fi

    # Add user-specified skera arguments (word splitting intentional)
    # shellcheck disable=SC2206
    if [[ -n "${SKERA_ARGS}" ]]; then
        skera_cmd+=(${SKERA_ARGS})
    fi

    # Positional args: input, adapters, output
    skera_cmd+=("${input_bam}")
    skera_cmd+=("${ADAPTER_REF}")
    skera_cmd+=("${output_bam}")

    log_debug "  Command: ${skera_cmd[*]}"

    # Execute or dry run
    if [[ "${DRY_RUN}" == "TRUE" ]]; then
        log_info "  [DRY RUN] Would execute: ${skera_cmd[*]}"
        if [[ -n "${REORGANISE}" ]]; then
            log_info "  [DRY RUN] Would then reorganise output (mode: ${REORGANISE})"
        fi
        return 0
    fi

    # Create output directory (only outside dry-run; dry-run has no side effects)
    mkdir -p "${output_subdir}"

    # Run skera
    if "${skera_cmd[@]}"; then
        log_info "  ✓ Complete"

        # Report summary statistics from skera's flat output location
        local summary_file="${output_subdir}/${output_prefix}.summary.csv"
        if [[ -f "${summary_file}" ]]; then
            local input_reads s_reads pct_full mean_factor
            input_reads=$(awk -F, '$1=="Input Reads" {print $2}' "${summary_file}" | head -1)
            s_reads=$(awk -F, '$1=="Segmented Reads (S-Reads)" {print $2}' "${summary_file}" | head -1)
            pct_full=$(awk -F, '$1=="Percentage of Reads with Full Array" {print $2}' "${summary_file}" | head -1)
            mean_factor=$(awk -F, '$1=="Mean Array Size (Concatenation Factor)" {print $2}' "${summary_file}" | head -1)
            log_info "  Stats: ${input_reads} input -> ${s_reads} S-reads (${pct_full}% full arrays, mean factor ${mean_factor})"
        fi

        # Reorganise this sample's output
        if [[ -n "${REORGANISE}" ]]; then
            reorganise_with_logging "${output_subdir}" "Reorganised"
        fi

        return 0
    else
        log_error "  ✗ Failed: ${bam_name}"
        return 1
    fi
}

#==============================================================================
# GENERATE SUMMARY
#==============================================================================

generate_summary() {
    local summary_file="${DIR_OUT}/polonius_summary.txt"

    log_info "Generating summary..."

    {
        echo "Polonius Pipeline Summary"
        echo "========================="
        echo ""
        echo "Date: $(date)"
        echo "Version: ${VERSION}"
        echo "Skera version: ${SKERA_VERSION}"
        echo ""
        echo "Parameters:"
        echo "  dir_data:          ${DIR_DATA}"
        echo "  dir_out:           ${DIR_OUT}"
        echo "  adapter_ref:       ${ADAPTER_REF}"
        echo "  skera_args:        ${SKERA_ARGS:-none}"
        echo "  reorganise:        ${REORGANISE:-none}"
        echo "  drop_nonpassing:   ${DROP_NONPASSING}"
        echo ""
        echo "Files processed: ${#INPUT_FILES[@]}"
        echo ""
        printf "%-60s  %12s  %12s  %10s  %12s\n" "Sample" "InputReads" "S-Reads" "%FullArray" "MeanFactor"
        printf "%-60s  %12s  %12s  %10s  %12s\n" "------" "----------" "-------" "----------" "----------"

        for f in "${INPUT_FILES[@]}"; do
            local bam_name
            bam_name=$(basename "$f" .bam)

            # Summary CSV location depends on mode; locate_summary_file searches
            # every possible layout (none / by-sample / by-sample-type / by-type /
            # by-type-sample) and returns the first hit, so we can use it for any
            # mode without branching.
            local summary
            summary=$(locate_summary_file "${DIR_OUT}" "${bam_name}")
            if [[ -n "${summary}" ]]; then
                local input_reads s_reads pct_full mean_factor
                input_reads=$(awk -F, '$1=="Input Reads" {print $2}' "${summary}" | head -1)
                s_reads=$(awk -F, '$1=="Segmented Reads (S-Reads)" {print $2}' "${summary}" | head -1)
                pct_full=$(awk -F, '$1=="Percentage of Reads with Full Array" {print $2}' "${summary}" | head -1)
                mean_factor=$(awk -F, '$1=="Mean Array Size (Concatenation Factor)" {print $2}' "${summary}" | head -1)
                printf "%-60s  %12s  %12s  %10s  %12s\n" \
                    "${bam_name}" "${input_reads:-?}" "${s_reads:-?}" "${pct_full:-?}" "${mean_factor:-?}"
            else
                printf "%-60s  %12s\n" "${bam_name}" "[not processed]"
            fi
        done
    } > "${summary_file}"

    log_info "Summary written to: ${summary_file}"
}

#==============================================================================
# SAVE PARAMETERS
#==============================================================================

save_parameters() {
    local params_file="${LOG_DIR}/polonius_params.txt"

    {
        echo "Polonius Pipeline Parameters"
        echo "============================"
        echo ""
        echo "Version: ${VERSION}"
        echo "Timestamp: $(date)"
        echo "Log directory: ${LOG_DIR}"
        echo ""
        echo "# Required"
        echo "dir_data=${DIR_DATA}"
        echo "dir_out=${DIR_OUT}"
        echo "adapter_ref=${ADAPTER_REF}"
        echo ""
        echo "# Optional"
        echo "file_pattern=${FILE_PATTERN}"
        echo "threads=${THREADS}"
        echo ""
        echo "# Skera arguments"
        echo "skera_args=${SKERA_ARGS}"
        echo ""
        echo "# Output organisation"
        echo "reorganise=${REORGANISE:-none}"
        echo "drop_nonpassing=${DROP_NONPASSING}"
        echo ""
        echo "# Execution"
        echo "dry_run=${DRY_RUN}"
        echo "verbose=${VERBOSE}"
    } > "${params_file}"

    log_info "Parameters saved to: ${params_file}"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
    local start_time
    start_time=$(date +%s)

    # Parse arguments
    parse_args "$@"

    # Show banner
    log_section "Polonius v${VERSION} - PacBio Kinnex Deconcatenation Pipeline"

    # Set up logging BEFORE validation so all output (including errors) is captured.
    # Log dir is in the polonius root, independent of DIR_OUT, so it can be created
    # even if DIR_OUT hasn't been validated yet.
    RUN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="${POLONIUS_ROOT}/logs/${RUN_TIMESTAMP}"
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/polonius.log"

    # Redirect stdout/stderr: terminal sees ANSI colours, log file is plain text
    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}")) 2>&1

    log_info "Log directory: ${LOG_DIR}"

    # Validate inputs (errors now captured in log)
    validate_inputs

    # Create output directory (dry-run is side-effect-free; the log
    # directory is still created above because we want the log even
    # for dry runs)
    if [[ "${DRY_RUN}" != "TRUE" ]]; then
        mkdir -p "${DIR_OUT}"
    fi
    log_info "Output directory: ${DIR_OUT}"

    # Describe chosen output layout
    case "${REORGANISE}" in
        ""|by-sample)
            log_info "Output layout: by-sample (<sample>/, files flat inside)"
            ;;
        by-sample-type)
            log_info "Output layout: by-sample-type (<sample>/{deconcatenated,reports,nonpassing}/)"
            ;;
        by-type)
            log_info "Output layout: by-type ({deconcatenated,reports,nonpassing}/, all samples flat)"
            ;;
        by-type-sample)
            log_info "Output layout: by-type-sample ({deconcatenated,reports,nonpassing}/<sample>/)"
            ;;
    esac
    if [[ "${DROP_NONPASSING}" == "TRUE" ]]; then
        log_warn "  Non-passing files will be DELETED after skera writes them (--drop-nonpassing)"
    fi

    # Save parameters. Always written (including on dry-run, where the file
    # is marked dry_run=TRUE) because LOG_DIR is created unconditionally for
    # the log file, and the params file captures file_pattern, threads, and
    # skera_args which don't appear elsewhere in the log.
    save_parameters

    # Setup environment
    setup_environment

    # Sanity-check the adapter reference
    check_adapter_ref

    # Find input files
    find_input_files

    # Process each BAM file
    log_section "Processing BAM Files"

    local failed=0
    local succeeded=0
    FAILED_FILES=()

    for bam_file in "${INPUT_FILES[@]}"; do
        if process_bam "${bam_file}"; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
            FAILED_FILES+=("$(basename "${bam_file}")")
        fi
    done

    # Final-pass reorganisation. The per-sample reorganise step inside
    # process_bam handles freshly-created flat <sample>/ dirs. This final pass
    # walks DIR_OUT filename-by-filename via reorganise_path() and catches
    # anything that ended up in the wrong layout (e.g. stale files from a
    # previous run with different --reorganise mode, or a legacy v1.2
    # skera_<sample>/ directory still sitting alongside fresh output).
    # Idempotent: files already at their target location are detected via
    # inode and counted as "in-place" with no move.
    if [[ -n "${REORGANISE}" && "${DRY_RUN}" != "TRUE" && ${succeeded} -gt 0 ]]; then
        local drop_flag=0
        [[ "${DROP_NONPASSING}" == "TRUE" ]] && drop_flag=1
        if reorganise_path "${DIR_OUT}" "${REORGANISE}" "${DIR_OUT}" "${drop_flag}" 0; then
            local moved_total=$((REORG_DECONCATENATED + REORG_REPORTS + REORG_NONPASSING - REORG_INPLACE))
            if [[ ${moved_total} -gt 0 || ${REORG_DROPPED} -gt 0 ]]; then
                log_info "Final layout pass: ${moved_total} file(s) migrated, ${REORG_INPLACE} already in place, ${REORG_DROPPED} dropped"
            else
                log_debug "Final layout pass: all ${REORG_INPLACE} file(s) already in target layout"
            fi
        else
            log_warn "Final layout pass failed (reorganise_path returned non-zero)"
        fi
    fi

    # Generate summary
    if [[ "${DRY_RUN}" != "TRUE" ]]; then
        generate_summary
    fi

    # Final report
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    log_section "Pipeline Complete"

    log_info "Results:     ${DIR_OUT}"
    log_info "Succeeded:   ${succeeded}"
    log_info "Failed:      ${failed}"
    log_info "Duration:    $(printf "%02d:%02d:%02d" ${hours} ${minutes} ${seconds}) (HH:MM:SS)"
    log_info "Logs:        ${LOG_DIR}"

    if [[ ${failed} -gt 0 ]]; then
        log_warn "The following files failed to process:"
        for f in "${FAILED_FILES[@]}"; do
            log_warn "  - ${f}"
        done
        log_warn "Check log for details: ${LOG_FILE}"
        exit 1
    fi
}

# Run main
main "$@"