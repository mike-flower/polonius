#!/bin/bash -l
#$ -S /bin/bash
#$ -N polonius_skera
#$ -l h_rt=12:00:00
#$ -pe smp 8
#$ -l mem=4G
#$ -l tmpfs=50G
#$ -wd /home/skgtmdf/Scratch/bin/polonius    # <<< EDIT
#$ -o logs/polonius_$JOB_ID.out
#$ -e logs/polonius_$JOB_ID.err
#$ -M michael.flower@ucl.ac.uk               # <<< EDIT
#$ -m bea

# See README for setup instructions and resource recommendations.

# Print job info
echo "Job ID: $JOB_ID | Host: $(hostname) | Cores: $NSLOTS | $(date)"
echo ""

# Environment
mkdir -p logs
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
echo "Skera: $(skera --version 2>&1 | head -1)"
echo ""

cd ~/Scratch/bin/polonius

# ==============================================================================
# EDIT PARAMETERS BELOW
# ==============================================================================

# --reorganise (no value) selects the recommended default mode: by-type.
# This produces:
#   - per-sample skera_<sample>/{deconcatenated,reports,nonpassing}/ subfolders
#   - top-level deconcatenated/, reports/, nonpassing/ directories at dir_out/
#     containing symlinks pooling files across all samples (zero disk cost)
# Downstream (Ophelia) can then point at dir_out/deconcatenated/ directly.
#
# Other modes:
#   --reorganise=by-sample        # legacy v1.0.0 layout, no top-level pools
#   --reorganise=by-type-sample   # top-level type dirs grouped by sample subfolders
#   --reorganise=none / --no-reorganise   # raw skera output (no reorganisation)

./polonius \
    --dir_data /home/skgtmdf/Scratch/data/demultiplex/2026.05.09_ucllrs_pacbio_revio_kinnex/hifi_reads \
    --dir_out  /home/skgtmdf/Scratch/data/demultiplex/2026.05.09_ucllrs_pacbio_revio_kinnex/deconcat \
    --adapter_ref /home/skgtmdf/Scratch/refs/adapters/mas/mas-seq_adapter_v3/mas8_primers.fasta \
    --threads $NSLOTS \
    --reorganise \
    --resume
    # Optional extras:
    #   --drop-nonpassing                # delete non-passing BAMs (irreversible; saves disk space)
    #   --file_pattern "*bcM000*.bam"
    #   --skera_args "--some-skera-flag"

# ==============================================================================

echo ""
echo "Done: $(date)"