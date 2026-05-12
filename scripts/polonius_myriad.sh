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
#
# EDIT BEFORE SUBMITTING - fields marked <<< EDIT:
#   -wd        Working directory (polonius repo root on Scratch)
#   -M         Your UCL email address for job notifications
#   --dir_data Path to your input HiFi BAM directory
#   --dir_out  Path to your output deconcatenation directory
#   --adapter_ref  Path to your MAS adapter FASTA
#   --reorganise   Mode: by-sample-type | by-type | by-type-sample (or remove flag)

echo "Job ID: $JOB_ID | Host: $(hostname) | Cores: $NSLOTS | $(date)"
echo ""

mkdir -p logs
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
echo "Skera: $(skera --version 2>&1 | head -1)"
echo ""

cd ~/Scratch/bin/polonius

./polonius \
    --dir_data /home/skgtmdf/Scratch/data/demultiplex/2026.05.09_ucllrs_pacbio_revio_kinnex/hifi_reads \
    --dir_out  /home/skgtmdf/Scratch/data/demultiplex/2026.05.09_ucllrs_pacbio_revio_kinnex/deconcat \
    --adapter_ref /home/skgtmdf/Scratch/refs/adapters/mas/mas-seq_adapter_v3/mas8_primers.fasta \
    --threads $NSLOTS \
    --reorganise by-type \
    --resume
    #   --drop-nonpassing
    #   --file_pattern "*bcM000*.bam"
    #   --skera_args ""

echo ""
echo "Done: $(date)"