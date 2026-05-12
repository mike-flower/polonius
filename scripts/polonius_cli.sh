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
# Version: 1.2.0
#
#==============================================================================

set -euo pipefail

#==============================================================================
# SCRIPT DIRECTORY
#==============================================================================

# Get the directory where this script is located (polonius/scripts)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Get the root polonius directory (parent of scripts/)
POLONIUS_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"

# Source shared reorganisation library (lives at the polonius repo root, not under scripts/)
# shellcheck source=../lib/reorganise.sh
source "${POLONIUS_ROOT}/lib/reorganise.sh"

#==============================================================================
# DEFAULTS
#==============================================================================

VERSION="1.2.0"

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
#   by-sample-type   move files into <sample>/{deconcatenated,reports,nonpassing}/
#   by-type          move files into dir_out/{deconcatenated,reports,nonpassing}/
#   by-type-sample   move files into dir_out/{deconcatenated,reports,nonpassing}/<sample>/
#   (unset)          no reorganisation; raw skera output left untouched
REORGANISE=""

DROP_NONPASSING="FALSE"

# Execution options
DRY_RUN="FALSE"
VERBOSE="FALSE"
RESUME="TRUE"

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
    --reorganise MODE       Move output files into a tidier layout. MODE must be
                            one of:
                              by-sample-type  per-sample directories with file-type
                                              subdirs inside each:
                                              <sample>/{deconcatenated,reports,nonpassing}/
                              by-type         top-level file-type directories, all
                                              samples pooled flat inside each:
                                              {deconcatenated,reports,nonpassing}/
                              by-type-sample  top-level file-type directories with
                                              per-sample subdirs inside each:
                                              {deconcatenated,reports,nonpassing}/<sample>/
                            Omit the flag entirely to leave output as raw skera output.
    --no-reorganise         Explicit no-op; same as omitting --reorganise
    --drop-nonpassing       Delete non-passing BAMs instead of moving them
                            (saves disk space; irreversible; requires --reorganise)

EXECUTION OPTIONS:
    --resume                Skip already processed files (default: on)
    --no-resume             Force re-processing of all files
    --dry_run               Show what would be run without executing
    --verbose               Enable verbose output
    --help                  Show this help message

EXAMPLES:

    # Basic deconcatenation, raw output (no reorganisation)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta

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

    # Drop non-passing BAMs to save disk space (irreversible)
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
        --reorganise by-type --dry_run

OUTPUT STRUCTURE:

    no --reorganise flag — raw skera output:
        dir_out/
        ├── skera_m84277_...bcM0001/
        │   ├── *.skera.bam
        │   ├── *.skera.bam.pbi
        │   ├── *.skera.non_passing.bam
        │   ├── *.skera.non_passing.bam.pbi
        │   ├── *.skera.summary.csv
        │   ├── *.skera.summary.json
        │   ├── *.skera.ligations.csv
        │   ├── *.skera.read_lengths.csv
        │   └── *.skera.found_adapters.csv.gz
        ├── skera_m84277_...bcM0002/
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
    - --reorganise MODE can be applied to existing output by re-running with
      --resume; already-completed samples skip skera and go straight to the
      reorganisation step.

EOF
}

#==============================================================================
# ARGUMENT PARSING
#==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir_data)
                DIR_DATA="$2"
                shift 2
                ;;
            --dir_out)
                DIR_OUT="$2"
                shift 2
                ;;
            --adapter_ref)
                ADAPTER_REF="$2"
                shift 2
                ;;
            --file_pattern)
                FILE_PATTERN="$2"
                shift 2
                ;;
            --threads)
                THREADS="$2"
                shift 2
                ;;
            --skera_args)
                SKERA_ARGS="$2"
                shift 2
                ;;
            --reorganise|--reorganize)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    log_error "--reorganise requires a mode: --reorganise MODE"
                    log_error "Valid modes: by-sample-type, by-type, by-type-sample"
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
            --resume)
                RESUME="TRUE"
                shift
                ;;
            --no-resume)
                RESUME="FALSE"
                shift
                ;;
            --dry_run)
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
                log_error "Unknown option: $1"
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

    # Validate threads is a non-negative integer
    if [[ -n "${THREADS}" && ! "${THREADS}" =~ ^[0-9]+$ ]]; then
        log_error "--threads must be a non-negative integer, got: ${THREADS}"
        errors=$((errors + 1))
    fi

    # Validate --reorganise mode
    case "${REORGANISE}" in
        ""|by-sample-type|by-type|by-type-sample)
            ;;
        *)
            log_error "Invalid --reorganise mode: '${REORGANISE}'"
            log_error "Valid modes: by-sample-type, by-type, by-type-sample"
            errors=$((errors + 1))
            ;;
    esac

    # --drop-nonpassing requires --reorganise
    if [[ "${DROP_NONPASSING}" == "TRUE" && -z "${REORGANISE}" ]]; then
        log_error "--drop-nonpassing requires --reorganise MODE"
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
            local msg="  ${label}: deconcatenated=${REORG_DECONCATENATED}, reports=${REORG_REPORTS}, nonpassing=${REORG_NONPASSING}"
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

    local output_subdir
    output_subdir="${DIR_OUT}/skera_${bam_name}"

    local output_prefix="${bam_name}.skera"
    local output_bam="${output_subdir}/${output_prefix}.bam"

    echo ""
    log_info "Processing: ${bam_name}"
    log_info "  Input:  ${input_bam}"
    log_info "  Output: ${output_subdir}/"

    # Check if already processed (resume logic). Looks for the summary CSV in
    # the skera_<sample>/ dir (flat or within reports/ for by-sample-type).
    # For by-type* modes the skera_ dir may already be gone after a previous run.
    if [[ "${RESUME}" == "TRUE" ]]; then
        local summary_file
        summary_file=$(locate_summary_file "${DIR_OUT}" "${bam_name}")
        if [[ -n "${summary_file}" ]] && grep -q "Mean Array Size" "${summary_file}" 2>/dev/null; then
            log_info "  Skipping (already processed, --resume)"
            # Apply reorganisation if the flat skera_ layout is still present
            if [[ -n "${REORGANISE}" && -d "${output_subdir}" && \
                  "${summary_file}" == "${output_subdir}/${output_prefix}.summary.csv" ]]; then
                reorganise_with_logging "${output_subdir}" "Reorganised (resume)"
            fi
            return 0
        fi
    fi

    # Create output directory
    mkdir -p "${output_subdir}"

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
            local sample_name="${bam_name}"
            local output_prefix="${bam_name}.skera"

            # Summary file location depends on mode:
            #   none:            skera_<sample>/<prefix>.summary.csv
            #   by-sample-type:  <sample>/reports/<prefix>.summary.csv
            #   by-type:         dir_out/reports/<prefix>.summary.csv
            #   by-type-sample:  dir_out/reports/<sample>/<prefix>.summary.csv
            local summary=""
            case "${REORGANISE}" in
                "")
                    summary=$(locate_summary_file "${DIR_OUT}" "${bam_name}")
                    ;;
                by-sample-type)
                    summary="${DIR_OUT}/${sample_name}/reports/${output_prefix}.summary.csv"
                    [[ -f "${summary}" ]] || summary=""
                    ;;
                by-type)
                    summary="${DIR_OUT}/reports/${output_prefix}.summary.csv"
                    [[ -f "${summary}" ]] || summary=""
                    ;;
                by-type-sample)
                    summary="${DIR_OUT}/reports/${sample_name}/${output_prefix}.summary.csv"
                    [[ -f "${summary}" ]] || summary=""
                    ;;
            esac
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
        echo "resume=${RESUME}"
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

    # Create output directory
    mkdir -p "${DIR_OUT}"
    log_info "Output directory: ${DIR_OUT}"

    # Describe chosen output layout
    case "${REORGANISE}" in
        "")
            log_info "Output layout: none (raw skera output)"
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
        log_warn "  Non-passing files will be DELETED (--drop-nonpassing)"
    fi

    # Save parameters
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