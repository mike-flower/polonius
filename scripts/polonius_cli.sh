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
# Version: 1.1.0
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

VERSION="1.1.0"

# Required parameters (no defaults)
DIR_DATA=""
DIR_OUT=""
ADAPTER_REF=""

# Optional parameters
FILE_PATTERN="*.bam"
THREADS=0   # 0 = auto-detect

# Skera arguments (pass-through to skera)
SKERA_ARGS=""

# Reorganisation mode (string-valued in v1.1.0+; was boolean in v1.0.0).
# Values:
#   none           - raw skera output (one flat directory per sample), no reorganisation
#   by-sample      - per-sample deconcatenated/, reports/, nonpassing/ subfolders (v1.0.0 behaviour)
#   by-type        - by-sample + top-level deconcatenated/, reports/, nonpassing/ symlink pools (default for bare --reorganise)
#   by-type-sample - by-sample + top-level deconcatenated/<sample>/, reports/<sample>/, nonpassing/<sample>/ symlink pools
REORGANISE="none"

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
    --reorganise[=MODE]     Reorganise output into a tidier layout (default: off).
                            Bare --reorganise selects MODE=by-type. Modes:
                              none            no reorganisation (raw skera output;
                                              equivalent to --no-reorganise)
                              by-sample       per-sample deconcatenated/, reports/,
                                              nonpassing/ subfolders inside each
                                              skera_<input>/ directory (v1.0.0 behaviour)
                              by-type         by-sample + top-level deconcatenated/,
                                              reports/, nonpassing/ directories with
                                              symlinks pooling files from every sample
                                              (RECOMMENDED for downstream tools like Ophelia)
                              by-type-sample  by-sample + top-level deconcatenated/<sample>/,
                                              reports/<sample>/, nonpassing/<sample>/
                                              directories with symlinks (useful at larger
                                              scale where flat by-type dirs get unwieldy)
    --no-reorganise         Shortcut for --reorganise=none
    --drop-nonpassing       Delete non-passing BAMs instead of moving them
                            (saves disk space; irreversible; requires
                            --reorganise to be set to any mode other than none)

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

    # Recommended: deconcatenate with by-type top-level pools (default mode)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise
    # Then point Ophelia at ~/results/deconcat/deconcatenated

    # Legacy per-sample-only layout (no top-level pools)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise=by-sample

    # Hybrid top-level dirs with per-sample subfolders (useful at larger scale)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise=by-type-sample

    # Drop non-passing BAMs to save disk space (irreversible)
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise --drop-nonpassing

    # Process only specific BAM files
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise \
        --file_pattern "*bcM000*.bam"

    # Dry run to see what would happen
    ./polonius \
        --dir_data ~/data/hifi_reads \
        --dir_out ~/results/deconcat \
        --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
        --reorganise --dry_run

OUTPUT STRUCTURE:

    --reorganise=none (or no flag) — raw skera output, flat:
        dir_out/
        ├── skera_m84277_...bcM0001/
        │   ├── *.skera.bam                      # Deconcatenated S-reads
        │   ├── *.skera.bam.pbi                  # PacBio index
        │   ├── *.skera.non_passing.bam          # Reads that did not form arrays
        │   ├── *.skera.non_passing.bam.pbi
        │   ├── *.skera.summary.csv              # Summary statistics
        │   ├── *.skera.summary.json
        │   ├── *.skera.ligations.csv            # Adapter adjacency matrix
        │   ├── *.skera.read_lengths.csv         # S-read length distribution
        │   └── *.skera.found_adapters.csv.gz   # Per-read adapter calls
        ├── skera_m84277_...bcM0002/
        │   └── ...
        └── polonius_summary.txt                 # Overall summary

    --reorganise=by-sample — per-sample subdirs only:
        dir_out/
        ├── skera_m84277_...bcM0001/
        │   ├── deconcatenated/    # *.skera.bam, *.skera.bam.pbi
        │   ├── reports/           # *.skera.summary.*, *.ligations.csv, *.read_lengths.csv, *.found_adapters.csv.gz
        │   └── nonpassing/        # *.skera.non_passing.* (omitted with --drop-nonpassing)
        └── polonius_summary.txt

    --reorganise=by-type (default) — per-sample subdirs + top-level type-pooled symlinks:
        dir_out/
        ├── deconcatenated/                      # ← symlinks across all samples
        │   ├── m84277_...bcM0001.skera.bam -> skera_m84277_...bcM0001/deconcatenated/...
        │   ├── m84277_...bcM0001.skera.bam.pbi -> ...
        │   ├── m84277_...bcM0002.skera.bam -> ...
        │   └── ...
        ├── reports/                             # ← symlinks; all report files in one place
        │   ├── m84277_...bcM0001.skera.summary.csv -> ...
        │   ├── m84277_...bcM0002.skera.summary.csv -> ...
        │   └── ...
        ├── nonpassing/                          # ← symlinks (omitted with --drop-nonpassing)
        │   └── ...
        ├── skera_m84277_...bcM0001/             # per-sample dirs preserved (forensic browsing)
        │   ├── deconcatenated/
        │   ├── reports/
        │   └── nonpassing/
        └── polonius_summary.txt

    --reorganise=by-type-sample — top-level type dirs with per-sample subfolders:
        dir_out/
        ├── deconcatenated/
        │   ├── m84277_...bcM0001/   ← symlinks
        │   ├── m84277_...bcM0002/
        │   └── m84277_...bcM0004/
        ├── reports/
        │   └── (same pattern)
        ├── nonpassing/
        │   └── (same pattern)
        ├── skera_m84277_...bcM0001/             # per-sample dirs preserved
        │   └── ...
        └── polonius_summary.txt

    Logs (in polonius installation directory):
        polonius/logs/YYYYMMDD_HHMMSS/
        ├── polonius.log
        └── polonius_params.txt

NOTES:
    - The by-type and by-type-sample modes use symlinks for the top-level pools,
      so they cost no disk space and don't duplicate any data. The real files
      always live inside skera_<input>/ where skera wrote them.
    - Skera is internally parallelised; files are processed sequentially
    - Requires skera (pbskera) from bioconda (conda install -c bioconda pbskera)
    - --reorganise can be applied to existing output by re-running with
      --resume (default); already-flat samples will be tidied without
      re-running skera. For ad-hoc retrofitting of existing directories
      without re-running polonius, use scripts/reorganise_polonius.sh
      (note: that script handles only the by-sample layer; use --resume
      via polonius for the top-level by-type pools).

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
                # Bare --reorganise = the recommended default mode
                REORGANISE="by-type"
                shift
                ;;
            --reorganise=*|--reorganize=*)
                # --reorganise=MODE (validated later in validate_inputs)
                REORGANISE="${1#*=}"
                shift
                ;;
            --no-reorganise|--no-reorganize)
                REORGANISE="none"
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
        none|by-sample|by-type|by-type-sample)
            ;;
        *)
            log_error "Invalid --reorganise mode: '${REORGANISE}'"
            log_error "Valid modes: none, by-sample, by-type, by-type-sample"
            errors=$((errors + 1))
            ;;
    esac

    # --drop-nonpassing requires --reorganise (it operates on the nonpassing subdir,
    # which only exists when per-sample reorganisation has happened)
    if [[ "${DROP_NONPASSING}" == "TRUE" && "${REORGANISE}" == "none" ]]; then
        log_error "--drop-nonpassing requires --reorganise (any mode other than 'none')"
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
# REORGANISE WRAPPER (per-sample, by-sample layer)
# Calls the shared library function and logs the result.
#==============================================================================

reorganise_with_logging() {
    local sample_dir="$1"
    local label="${2:-Reorganised}"

    local drop_flag=0
    [[ "${DROP_NONPASSING}" == "TRUE" ]] && drop_flag=1

    local dry_flag=0
    [[ "${DRY_RUN}" == "TRUE" ]] && dry_flag=1

    if reorganise_sample_dir "${sample_dir}" "${drop_flag}" "${dry_flag}"; then
        local total=$((REORG_DECONCATENATED + REORG_REPORTS + REORG_NONPASSING + REORG_DROPPED))
        if [[ ${total} -gt 0 ]]; then
            local msg="  ${label}: deconcatenated=${REORG_DECONCATENATED}, reports=${REORG_REPORTS}, nonpassing=${REORG_NONPASSING}"
            if [[ "${DROP_NONPASSING}" == "TRUE" ]]; then
                msg="${msg}, dropped=${REORG_DROPPED}"
            fi
            log_info "${msg}"
        fi
    else
        log_debug "  Reorganise skipped (no sample dir): ${sample_dir}"
    fi
}

#==============================================================================
# POOL BY TYPE (top-level layer)
# Creates top-level type directories (deconcatenated/, reports/, nonpassing/)
# containing symlinks to the files inside each skera_<sample>/<type>/.
#
# - Uses symlinks (absolute paths). No disk cost.
# - Idempotent (ln -sf). Safe under --resume.
# - mode = "flat":   symlinks go to  dir_out/<type>/<file>
# - mode = "nested": symlinks go to  dir_out/<type>/<sample>/<file>
#                    where <sample> is the input BAM basename (without .bam)
# - Skips empty source dirs (e.g. nonpassing/ when --drop-nonpassing was used)
#==============================================================================

pool_by_type() {
    local mode="${1:-flat}"

    if [[ "${DRY_RUN}" == "TRUE" ]]; then
        log_info "Pooling per-sample files into top-level type directories (mode: ${mode}) [dry run]"
        log_info "  [DRY RUN] Would create symlinks in: ${DIR_OUT}/{deconcatenated,reports,nonpassing}/"
        return 0
    fi

    log_info "Pooling per-sample files into top-level type directories (mode: ${mode})"

    local sample_count=0 link_count=0
    shopt -s nullglob

    for sample_dir in "${DIR_OUT}"/skera_*/; do
        sample_dir="${sample_dir%/}"
        local sample_name
        sample_name=$(basename "${sample_dir}")
        sample_name="${sample_name#skera_}"
        sample_count=$((sample_count + 1))

        # Iterate over the type subdirs that actually exist (deconcatenated/, reports/, nonpassing/)
        for source_subdir in "${sample_dir}"/*/; do
            local type
            type=$(basename "${source_subdir%/}")

            # Determine target dir based on mode
            local target_dir="${DIR_OUT}/${type}"
            if [[ "${mode}" == "nested" ]]; then
                target_dir="${target_dir}/${sample_name}"
            fi

            # Symlink each file in the source subdir into the target dir
            local files_in_subdir=0
            for src_file in "${source_subdir}"*; do
                [[ -f "${src_file}" ]] || continue
                if [[ ${files_in_subdir} -eq 0 ]]; then
                    mkdir -p "${target_dir}"
                fi
                local abs_src
                abs_src=$(readlink -f "${src_file}")
                # ln -sf is idempotent
                ln -sf "${abs_src}" "${target_dir}/$(basename "${src_file}")"
                link_count=$((link_count + 1))
                files_in_subdir=$((files_in_subdir + 1))
            done
        done
    done

    shopt -u nullglob

    if [[ ${link_count} -eq 0 ]]; then
        log_warn "  No files found to pool (per-sample type subdirs are empty or missing)"
    else
        log_info "  Created ${link_count} symlink(s) across ${sample_count} sample(s)"
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

    # Check if already processed (resume logic). Layout-aware: looks for the
    # summary file in either the flat or reorganised location.
    if [[ "${RESUME}" == "TRUE" ]]; then
        local summary_file
        summary_file=$(locate_summary_file "${output_subdir}" "${output_prefix}")
        # Look for the last metric written to summary.csv – if "Mean Array Size"
        # is present, skera completed successfully.
        if [[ -n "${summary_file}" ]] && grep -q "Mean Array Size" "${summary_file}" 2>/dev/null; then
            log_info "  Skipping (already processed, --resume)"
            # If reorganise is requested and the summary is still at the flat
            # location, do the per-sample reorganisation now.
            if [[ "${REORGANISE}" != "none" && "${summary_file}" == "${output_subdir}/${output_prefix}.summary.csv" ]]; then
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
        if [[ "${REORGANISE}" != "none" ]]; then
            log_info "  [DRY RUN] Would then reorganise output into deconcatenated/reports/nonpassing"
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

        # Reorganise this sample's output (per-sample, by-sample layer)
        # The top-level by-type / by-type-sample pooling happens after all samples
        # have been processed (see main()).
        if [[ "${REORGANISE}" != "none" ]]; then
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
        echo "  reorganise:        ${REORGANISE}"
        echo "  drop_nonpassing:   ${DROP_NONPASSING}"
        echo ""
        echo "Files processed: ${#INPUT_FILES[@]}"
        echo ""
        printf "%-60s  %12s  %12s  %10s  %12s\n" "Sample" "InputReads" "S-Reads" "%FullArray" "MeanFactor"
        printf "%-60s  %12s  %12s  %10s  %12s\n" "------" "----------" "-------" "----------" "----------"

        for f in "${INPUT_FILES[@]}"; do
            local bam_name
            bam_name=$(basename "$f" .bam)
            local output_subdir="${DIR_OUT}/skera_${bam_name}"

            # Layout-aware lookup for the summary file
            local summary
            summary=$(locate_summary_file "${output_subdir}" "${bam_name}.skera")
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
        echo "reorganise=${REORGANISE}"
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
        none)
            log_info "Output layout: none (raw skera output, flat per-sample directories)"
            ;;
        by-sample)
            log_info "Output layout: by-sample (per-sample deconcatenated/, reports/, nonpassing/ subfolders)"
            ;;
        by-type)
            log_info "Output layout: by-type (per-sample subfolders + top-level deconcatenated/, reports/, nonpassing/ symlink pools)"
            ;;
        by-type-sample)
            log_info "Output layout: by-type-sample (per-sample subfolders + top-level type dirs with per-sample subfolders)"
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

    # Top-level type-pooled symlinks (by-type / by-type-sample modes)
    case "${REORGANISE}" in
        by-type)
            pool_by_type "flat"
            ;;
        by-type-sample)
            pool_by_type "nested"
            ;;
    esac

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