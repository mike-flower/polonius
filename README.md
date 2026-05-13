# Polonius

A deconcatenation pipeline for PacBio Kinnex / MAS-Seq HiFi sequencing data using PacBio's skera tool. Sister tool to [Ophelia](https://github.com/mike-flower/ophelia); runs before it in the demultiplexing chain.

**Version 1.4.0**

---

## Quick start

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type
```

Each input HiFi BAM is split into one S-read per array segment, producing one `<input_basename>/` output folder per input BAM. `--reorganise by-type` then moves all files into top-level `deconcatenated/`, `reports/`, and `nonpassing/` directories, with all samples pooled flat inside each. Point Ophelia straight at `dir_out/deconcatenated/`.

See [Output reorganisation](#output-reorganisation) for all four modes (`by-sample`, `by-sample-type`, `by-type`, `by-type-sample`) and when to pick each. The default (no flag) is equivalent to `by-sample`.

---

## Table of contents

- [Where Polonius fits](#where-polonius-fits)
- [Installation](#installation)
- [Input file requirements](#input-file-requirements)
- [Repository layout](#repository-layout)
- [Run analysis](#run-analysis)
  - [Command-line interface](#command-line-interface)
  - [HPC deployment (Myriad)](#hpc-deployment-myriad)
- [Parameters](#parameters)
- [Output structure](#output-structure)
- [Output reorganisation](#output-reorganisation)
- [Adapter reference selection](#adapter-reference-selection)
- [Skera reference](#skera-reference)
- [Common workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)

---

## Where Polonius fits

Kinnex / MAS-Seq prep concatenates multiple amplicons or cDNA molecules into arrays held together by ordered MAS adapters, then sequences the array as one long HiFi read. The full demultiplexing chain is:

```
Revio sequencing → HiFi BAMs (concatenated arrays)
   │
   ├── [optional] lima on terminal SMRTbell adapters
   │   (splits by Kinnex library if multiple libraries pooled per cell)
   │   → m84277_*.hifi_reads.bcM000X.bam
   │
   ├── Polonius (skera split with MAS adapters)
   │   → S-reads, one per array segment
   │
   └── Ophelia (lima on sample barcodes)
       → per-sample BAMs
```

Polonius handles the middle stage. Use it whenever your HiFi reads are concatenated Kinnex arrays that need splitting into individual molecules before sample demultiplexing.

---

## Installation

### UCL Myriad

```bash
# One-time setup (install skera into the same env you use for lima)
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima                # or create a new env if preferred
conda install -c bioconda pbskera -y

# Each session
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
```

### AWS / Linux server

```bash
conda create -n lima -c bioconda lima pbskera   # or add pbskera to an existing lima env
conda activate lima
```

Skera is a compiled C++ binary distributed via bioconda alongside lima.

### Pipeline setup

```bash
cd ~/Scratch/bin
git clone https://github.com/mike-flower/polonius.git
cd polonius

# Verify
./polonius --help
```

Polonius creates its own `logs/<timestamp>/` directory at runtime, so no manual setup is required for local use. For Myriad/SGE submissions an extra `mkdir -p logs` step is needed – see [HPC deployment (Myriad)](#hpc-deployment-myriad).

---

## Input file requirements

### 1. HiFi BAM files (concatenated arrays)

**Location:** Specified by `--dir_data`.
**Format:** PacBio HiFi BAM files where each read is a concatenated Kinnex array.

These typically come from one of two upstream stages:

- **Revio onboard analysis or SMRT Link** has run `lima` against the terminal SMRTbell adapter set, producing per-library BAMs named like `m84277_*.hifi_reads.bcM000X.bam`. This is the usual situation when multiple Kinnex libraries are pooled on a single SMRT cell.
- **Raw HiFi output** with no upstream lima step, if only one Kinnex library was sequenced per cell.

```
data/
├── m84277_260509_135316_s2.hifi_reads.bcM0001.bam
├── m84277_260509_135316_s2.hifi_reads.bcM0002.bam
└── m84277_260509_135316_s2.hifi_reads.bcM0004.bam
```

### 2. MAS adapter reference FASTA

**Location:** Specified by `--adapter_ref`.
**Format:** FASTA file with the N+1 MAS adapter sequences for an N-segment Kinnex array.

| Kit | Array size | Adapter file | PacBio download path |
|---|---|---|---|
| Kinnex single-cell RNA | 16-fold | `mas16_primers.fasta` | `MAS-Seq_Adapter_v1/` |
| Kinnex 16S rRNA | 12-fold | `mas12_primers.fasta` | `MAS-Seq_Adapter_v2/` |
| Kinnex full-length RNA | 8-fold | `mas8_primers.fasta` | `MAS-Seq_Adapter_v3/` |

Despite the `v1` / `v2` / `v3` naming, these aren't sequential revisions – they're different adapter sets for different kits. See [Adapter reference selection](#adapter-reference-selection) for download commands and how to identify which kit produced your data.

---

## Repository layout

```
polonius/
├── polonius                        # Main wrapper script
├── scripts/
│   ├── polonius_cli.sh             # Core pipeline logic
│   ├── polonius_myriad.sh          # HPC job submission template
│   └── reorganise_polonius.sh      # Standalone migration tool
├── lib/
│   └── reorganise.sh               # Shared reorganisation library
├── logs/                           # Pipeline logs (created automatically)
│   ├── 20260512_073000/
│   │   ├── polonius.log
│   │   └── polonius_params.txt
│   └── ...
├── www/                            # Reference adapter FASTAs (optional)
└── README.md
```

---

## Run analysis

### Command-line interface

**Basic usage:**

```bash
./polonius --dir_data DIR --dir_out DIR --adapter_ref FILE [OPTIONS]
```

**Full example:**

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --threads 8 \
    --reorganise by-type
```

**View all options:**

```bash
./polonius --help
```

**Dry run:**

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --dry-run
```

### HPC deployment (Myriad)

#### First-time setup

```bash
# 1. Create / update conda env with skera
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
conda install -c bioconda pbskera -y

# 2. Clone polonius
cd ~/Scratch/bin
git clone https://github.com/mike-flower/polonius.git
cd polonius

# 3. Create logs directory for SGE job output (REQUIRED before submission)
mkdir -p logs
```

#### Job submission

```bash
cp scripts/polonius_myriad.sh scripts/polonius_myriad_myrun.sh
nano scripts/polonius_myriad_myrun.sh    # edit parameters
qsub scripts/polonius_myriad_myrun.sh
```

#### Example Myriad job script

```bash
#!/bin/bash -l
#$ -S /bin/bash
#$ -N polonius_skera
#$ -l h_rt=12:00:00
#$ -pe smp 8
#$ -l mem=4G
#$ -l tmpfs=50G
#$ -wd /home/skgtmdf/Scratch/bin/polonius    # <<< EDIT (your repo path)
#$ -o logs/polonius_$JOB_ID.out
#$ -e logs/polonius_$JOB_ID.err
#$ -M your.email@ucl.ac.uk                   # <<< EDIT
#$ -m bea

module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima

cd ~/Scratch/bin/polonius

./polonius \
    --dir_data /home/skgtmdf/Scratch/data/.../hifi_reads \
    --dir_out  /home/skgtmdf/Scratch/data/.../deconcat \
    --adapter_ref /home/skgtmdf/Scratch/refs/adapters/mas/mas-seq_adapter_v3/mas8_primers.fasta \
    --threads $NSLOTS \
    --reorganise by-type
```

The `<<< EDIT` lines must be updated for your account before submission. `scripts/polonius_myriad.sh` is a ready-to-edit copy of this template.

#### Resource recommendations

| Input size | Cores | Memory | Runtime |
|---|---|---|---|
| Single library, ~1 GB BAM | 8 | 4 G | <1 h |
| 3 libraries, ~5 GB total | 8 | 4 G | 1–2 h |
| 10+ libraries | 12–16 | 4 G | 4–8 h |

Skera is internally well-parallelised; files are processed sequentially.

---

## Parameters

### Required

| Parameter | Description |
|---|---|
| `--dir_data` | Directory containing input HiFi BAM files |
| `--dir_out` | Output directory for deconcatenated S-reads |
| `--adapter_ref` | FASTA file with MAS adapter sequences |

### Optional

| Parameter | Default | Description |
|---|---|---|
| `--file_pattern` | `*.bam` | Glob pattern for BAM files to process |
| `--threads` | Auto-detect | Number of CPU threads passed to skera |

### Skera arguments

| Parameter | Default | Description |
|---|---|---|
| `--skera_args` | *(none)* | Additional arguments passed to skera |

> **Note**: `--skera_args` values are passed through with simple word-splitting, so embedded quotes are not preserved. Use it only for simple `--flag value` pairs without spaces inside individual values.

### Output organisation

| Parameter | Default | Description |
|---|---|---|
| `--reorganise MODE` | omitted (≡ `by-sample`) | Output layout. MODE: `by-sample`, `by-sample-type`, `by-type`, `by-type-sample`. Omitting the flag produces the same layout as `--reorganise by-sample` (per-sample directories with files flat inside). See [Output reorganisation](#output-reorganisation). |
| `--no-reorganise` | – | Explicit no-op; same as omitting `--reorganise` |
| `--drop-nonpassing` | Off | Delete `*.skera.non_passing.bam{,.pbi}` files **after** skera has written them. Polonius-only post-skera step (skera has no flag to skip the files at source). Irreversible; requires `--reorganise`. See [Saving disk space](#saving-disk-space--drop-nonpassing). |

### Execution options

| Parameter | Default | Description |
|---|---|---|
| `--dry-run` | Off | Show commands without executing (`--dry_run` is also accepted) |
| `--verbose` | Off | Enable debug output |

---

## Output structure

**Pipeline logs** (in polonius installation directory):

```
polonius/logs/
├── 20260512_073000/
│   ├── polonius.log
│   └── polonius_params.txt
└── ...
```

The reorganisation modes produce different on-disk layouts. Examples below assume 3 input BAMs (bcM0001, bcM0002, bcM0004).

### No `--reorganise` flag (equivalent to `--reorganise by-sample`) – per-sample dirs, files flat inside

```
dir_out/
├── m84277_...bcM0001/
│   ├── m84277_...bcM0001.skera.bam                    # Deconcatenated S-reads
│   ├── m84277_...bcM0001.skera.bam.pbi                # PacBio index
│   ├── m84277_...bcM0001.skera.non_passing.bam        # Reads that didn't form arrays
│   ├── m84277_...bcM0001.skera.non_passing.bam.pbi
│   ├── m84277_...bcM0001.skera.summary.csv            # Summary statistics
│   ├── m84277_...bcM0001.skera.summary.json
│   ├── m84277_...bcM0001.skera.ligations.csv          # Adapter adjacency matrix
│   ├── m84277_...bcM0001.skera.read_lengths.csv       # S-read length distribution
│   └── m84277_...bcM0001.skera.found_adapters.csv.gz  # Per-read adapter calls
├── m84277_...bcM0002/
│   └── ...
└── polonius_summary.txt                               # Cross-sample summary table
```

The default layout is one directory per input BAM, named after the input file stem, with skera's outputs sitting flat inside. `--reorganise by-sample` produces exactly the same thing – it's just an explicit way to state the intent.

> **Note**: polonius up to v1.2 named these directories `skera_<sample>/` with a `skera_` prefix. v1.3+ drops the prefix. To convert a v1.2 output directory to the new naming (or any other layout), run `scripts/reorganise_polonius.sh --mode by-sample --path <dir_out>`.

### `--reorganise by-sample-type` – per-sample dirs with type subdirs

```
dir_out/
├── m84277_...bcM0001/
│   ├── deconcatenated/    # *.skera.bam, *.skera.bam.pbi
│   ├── reports/           # *.summary.*, *.ligations.csv, *.read_lengths.csv, *.found_adapters.csv.gz
│   └── nonpassing/        # *.non_passing.* (omitted with --drop-nonpassing)
├── m84277_...bcM0002/
│   └── ...
└── polonius_summary.txt
```

### `--reorganise by-type` – top-level type dirs, all samples flat

```
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
```

### `--reorganise by-type-sample` – top-level type dirs with per-sample subdirs

```
dir_out/
├── deconcatenated/
│   ├── m84277_...bcM0001/
│   │   ├── m84277_...bcM0001.skera.bam
│   │   └── m84277_...bcM0001.skera.bam.pbi
│   └── m84277_...bcM0002/
├── reports/
│   └── (same pattern)
├── nonpassing/            # omitted with --drop-nonpassing
│   └── (same pattern)
└── polonius_summary.txt
```

### Output files

| File | Description |
|---|---|
| `*.skera.bam` | Deconcatenated S-reads (one per array segment) – the main output |
| `*.skera.bam.pbi` | PacBio index for the S-reads BAM |
| `*.skera.non_passing.bam` | Reads that did not form a clean array |
| `*.skera.summary.csv` / `.summary.json` | Per-sample summary stats (input reads, S-reads, % full arrays, mean array size) |
| `*.skera.ligations.csv` | Adapter adjacency matrix (QC for array structure) |
| `*.skera.read_lengths.csv` | S-read length distribution (one row per S-read) |
| `*.skera.found_adapters.csv.gz` | Per-read adapter assignments (verbose; forensic debugging only) |
| `polonius_summary.txt` | Cross-sample summary table |

---

## Output reorganisation

By default, polonius writes one directory per input BAM into `dir_out/`, named after the input file stem, with skera's outputs sitting flat inside (`dir_out/<sample>/<sample>.skera.*`). The `--reorganise MODE` flag can change this layout. All modes move files – nothing is copied or symlinked.

There are four modes:

### `by-sample`

```
<sample>/
```

Explicit alias for the default layout. Per-sample directories with files flat inside; same output as running polonius without `--reorganise`. Stating the mode explicitly is useful in scripts and shared command lines where you want the intended layout to be obvious to anyone reading.

### `by-sample-type`

Files are moved into type subdirs within each sample directory:

```
<sample>/{deconcatenated,reports,nonpassing}/
```

Sample-centric: easy to work with one sample at a time, but consuming across all samples (e.g. pointing Ophelia at all BAMs) requires a per-sample loop or glob.

### `by-type` (recommended for Ophelia)

Files from all samples are moved into top-level type directories, pooled flat:

```
{deconcatenated,reports,nonpassing}/
```

Type-centric and flat. Filenames retain the sample identity (the Kinnex barcode is embedded). Downstream tools like Ophelia can be pointed at `dir_out/deconcatenated/` in a single command with no per-library loop.

### `by-type-sample`

Like `by-type`, but the type directories are subdivided by sample:

```
{deconcatenated,reports,nonpassing}/<sample>/
```

Useful at larger scale (dozens to hundreds of libraries) where the flat `by-type` directories would become unwieldy to browse.

### Saving disk space – `--drop-nonpassing`

Skera always writes a `*.skera.non_passing.bam` file (and its `.pbi` index) for every input – there is no upstream option to skip generating them. By default, polonius keeps these files. `--drop-nonpassing` is a polonius-only post-skera step that deletes them once skera has finished writing them.

Non-passing BAMs are usually a small minority (~3% of reads in a clean Kinnex prep), so leaving them on disk is normally fine. The flag exists for two situations: large multi-library runs where even 3% per file adds up, and runs where you know in advance you won't be using `skera undo` (which is the inverse of `split` and needs the non-passing BAM to reconstruct the original parent reads).

**Defaults and behaviour:**

- **Off by default.** Non-passing BAMs are written by skera and kept by polonius unless you explicitly opt in.
- **Post-skera, not pre-skera.** Skera still writes the file; polonius deletes it afterwards in the reorganise step. There is no runtime saving from this flag, only a disk-space saving.
- **Irreversible.** Once deleted, the only way to get the file back is to re-run skera on the input BAM.
- **Requires `--reorganise`** because the deletion happens during the reorganise pass. To use the default layout while still dropping non-passing files, pass `--reorganise by-sample --drop-nonpassing`.

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --drop-nonpassing
```

### Migrating an existing output directory

Use `scripts/reorganise_polonius.sh` to change the layout of an existing output directory without re-running skera. It auto-detects the source layout from filenames (so it works on any of the four reorganised layouts, the default `<sample>/` layout, or the legacy v1.2 `skera_<sample>/` layout) and moves files to the target layout. Idempotent: files already in target are detected by inode and left in place.

```bash
# Migrate in-place to by-type (works from any current layout)
scripts/reorganise_polonius.sh --mode by-type --path ~/results/deconcat

# Dry-run first to preview moves
scripts/reorganise_polonius.sh --mode by-sample-type \
    --path ~/results/deconcat --dry-run

# Migrate between two reorganised layouts (by-sample-type -> by-type)
scripts/reorganise_polonius.sh --mode by-type --path ~/results/deconcat

# Merge two runs into one combined tree
scripts/reorganise_polonius.sh --mode by-type-sample \
    --path /run1/deconcat --path /run2/deconcat \
    --dir_out /merged
```

> Polonius itself does **not** have a "migrate-only" mode. If you re-run `./polonius --reorganise MODE` on an existing `dir_out`, polonius will re-run skera for every input BAM (which is slow but produces fresh output) and apply MODE as a final layout pass. For layout-only migration, `reorganise_polonius.sh` is the right tool.

---

## Adapter reference selection

The MAS adapter FASTA must match the Kinnex kit used during library prep. Wrong adapter set = chaos in the ligation matrix and a near-zero full-array rate.

### Available sets

PacBio publishes the adapter FASTAs at:
`https://downloads.pacbcloud.com/public/dataset/MAS-Seq/REF-MAS_adapters/`

| Folder | File | Kit |
|---|---|---|
| `MAS-Seq_Adapter_v1/` | `mas16_primers.fasta` | Kinnex single-cell RNA (16-fold) |
| `MAS-Seq_Adapter_v2/` | `mas12_primers.fasta` | Kinnex 16S rRNA (12-fold) |
| `MAS-Seq_Adapter_v3/` | `mas8_primers.fasta` | Kinnex full-length RNA (8-fold) |

These directories also contain a `*.fasta.fai` index and a SMRT Link `*.barcodeset.xml` definition – not required by skera, but worth grabbing for completeness.

### Download in one command

```bash
mkdir -p ~/refs/adapters/mas/mas-seq_adapter_v3
cd ~/refs/adapters/mas/mas-seq_adapter_v3
wget -r -np -nd -R "index.html*" \
    https://downloads.pacbcloud.com/public/dataset/MAS-Seq/REF-MAS_adapters/MAS-Seq_Adapter_v3/
```

### How to identify the right kit

1. **Ask the wet-lab team** – the kit name (e.g. "Kinnex full-length RNA kit, PacBio P/N 103-072-800") pins it down completely.
2. **Check the BAM header** – `samtools view -H` may show the segmentation adapter set in `@PG` lines if SMRT Link processed the data.
3. **Try empirically** – polonius prints the number of adapter entries it finds at startup and infers the array size (9 → MAS8, 13 → MAS12, 17 → MAS16). After a run, check the `*.summary.csv` files:
   - Mean Array Size at the expected maximum (8, 12, or 16) with >95% full arrays → right adapter set.
   - Mode at 0 or near-zero full arrays → wrong adapter set; try a different one.

---

## Skera reference

Polonius is a thin wrapper around `skera split`. The skera 1.4.0 CLI is deliberately small – all quality and adapter discrimination is driven by the input adapter FASTA, not by command-line tuning – so there's not much polonius could helpfully expose as dedicated flags. The complete option list as of skera 1.4.0 is:

| Flag | Purpose |
|---|---|
| `-j`, `--num-threads N` | Threads (polonius sets this from `--threads`; don't pass directly). `0` = autodetect. |
| `--log-level STR` | Skera's own log level: `TRACE`, `DEBUG`, `INFO`, `WARN`, `FATAL`. Default `WARN`. |
| `--log-file FILE` | Redirect skera's diagnostic log to a file instead of stderr. |
| `-h`, `--help` | Show skera's help. |
| `--version` | Show skera's version. |

Any of these can be forwarded via `--skera_args "..."`. To turn up skera's verbosity for debugging, for example:

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type \
    --skera_args "--log-level DEBUG"
```

Re-run `skera split --help` after `conda activate lima` to check for new flags in later versions.

---

## Common workflows

### 1. Basic deconcatenation with recommended layout

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type
```

### 2. Polonius → Ophelia chain

With `by-type`, Ophelia consumes all samples in one call:

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type

./ophelia \
    --dir_data ~/results/deconcat/deconcatenated \
    --dir_out ~/results/sample_demux \
    --barcode_ref ~/refs/pacbio_kinnex16S_barcodes.fasta \
    --reorganise by-type
```

If your samples need per-library biosample CSVs, run Ophelia per library using `--file_pattern`:

```bash
for BC in bcM0001 bcM0002 bcM0004; do
    ./ophelia \
        --dir_data ~/results/deconcat/deconcatenated \
        --dir_out ~/results/sample_demux/${BC} \
        --barcode_ref ~/refs/pacbio_kinnex16S_barcodes.fasta \
        --biosample_csv ~/refs/biosample_${BC}.csv \
        --file_pattern "*${BC}*.bam" \
        --reorganise by-type
done
```

### 3. Process only specific files

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --file_pattern "*bcM000*.bam" \
    --reorganise by-type
```

### 4. Per-sample layout, files flat inside (also the default)

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-sample
```

Identical output to running polonius without `--reorganise`: one directory per input BAM, named after the input file stem, with skera's outputs flat inside.

### 5. Per-sample layout with type subdirs

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-sample-type
```

### 6. Test run (dry run)

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --dry-run
```

### 7. Migrate an existing output directory to a different layout

```bash
# Preview first
scripts/reorganise_polonius.sh --mode by-type \
    --path ~/results/deconcat --dry-run

# Run in-place
scripts/reorganise_polonius.sh --mode by-type --path ~/results/deconcat
```

Works in any direction (e.g. `by-sample-type` → `by-type`, `by-type` → `by-sample`, legacy `skera_<sample>/` → anything). Detection is filename-based, not directory-based. Re-running with the same target is a safe no-op.

### 8. Save disk space

Skera always writes non-passing BAMs; polonius keeps them by default. `--drop-nonpassing` deletes them after skera finishes (post-skera step, irreversible). See [Saving disk space](#saving-disk-space--drop-nonpassing).

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --drop-nonpassing
```

### 9. Larger-scale runs (many libraries)

```bash
./polonius \
    --dir_data ~/data/many_hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type-sample
```

---

## Troubleshooting

### `skera: command not found`

```bash
conda activate lima
conda install -c bioconda pbskera -y

# On Myriad
module load python/miniconda3/24.3.0-0
source $UCL_CONDA_PATH/etc/profile.d/conda.sh
conda activate lima
```

### `scripts/polonius_cli.sh not found`

Run from the polonius root directory:

```bash
cd ~/Scratch/bin/polonius
./polonius --help
```

### `shared library not found at .../lib/reorganise.sh`

Both `scripts/polonius_cli.sh` and `scripts/reorganise_polonius.sh` source `lib/reorganise.sh` from the repo root. Run them from inside a checked-out polonius repo, or copy both the `scripts/` and `lib/` directories together.

### `can't open output file ... logs/polonius_XXX.out` (Myriad)

SGE creates log files **before** the job script runs, so the logs directory must exist beforehand:

```bash
cd ~/Scratch/bin/polonius
mkdir -p logs
qsub scripts/polonius_myriad.sh
```

### `Invalid --reorganise mode`

Valid modes: `by-sample`, `by-sample-type`, `by-type`, `by-type-sample`. Note the British spelling (`-ise`); the American spelling `--reorganize by-type` is also accepted.

The mode must immediately follow the flag as a positional argument — not joined with `=`. This applies to all polonius flags across both `polonius` and `scripts/reorganise_polonius.sh`:

```bash
--reorganise by-type      # correct
--reorganize by-type      # also accepted (American spelling)
--reorganise=by-type      # rejected with a clear "use space separation" hint
```

If another flag immediately follows `--reorganise` without a mode (e.g. `--reorganise --verbose`), polonius will exit with a clear "requires a mode" error rather than misinterpreting the flag as the mode value.

### Top-level `deconcatenated/`, `reports/`, `nonpassing/` are missing after a run

These are only created by `by-type` and `by-type-sample`. To add them retroactively to an existing output directory without re-running skera:

```bash
scripts/reorganise_polonius.sh --mode by-type --path ~/results/deconcat
```

This works from any current layout (default `<sample>/`, `by-sample-type`, legacy `skera_<sample>/`, etc.). Idempotent: files already in the target layout are detected and left in place.

### Low full-array percentage

Check the `*.summary.csv` files. If the mode is well below the expected maximum (8/12/16) or the full-array fraction is poor:

- **Wrong adapter set.** Check the inferred array size at startup. Try a different `mas*_primers.fasta`.
- **Poor library prep.** Check the `*.ligations.csv` – off-diagonal counts >1% of diagonal indicate ligation problems or chimera formation.

### Non-passing BAM is unexpectedly large

A clean Kinnex prep gives ~3% non-passing. If much more:

- Likely wrong adapter set – check the ligation matrix.
- Mixed library types in the input BAM – check that you've run lima on the terminal SMRTbell adapters first.

### Checking pipeline logs

```bash
ls ~/Scratch/bin/polonius/logs/
ls -t ~/Scratch/bin/polonius/logs/ | head -1 | xargs -I {} cat ~/Scratch/bin/polonius/logs/{}/polonius.log
```

---

## Contact

**Michael Flower**
Senior Clinical Research Fellow
Department of Neurodegenerative Disease
UCL Queen Square Institute of Neurology
London, UK

- Email: [michael.flower@ucl.ac.uk](mailto:michael.flower@ucl.ac.uk)
- GitHub: <https://github.com/mike-flower>

---

## Version history

### 1.4.0 (May 2026)

- **Resume support removed.** `--resume` and `--no-resume` are no longer recognised; passing them now fails with the standard "Unknown option" error. The interaction between resume and the four reorganise layouts was difficult to make reliable enough to trust, and the operations resume tried to combine split cleanly: re-running polonius produces fresh skera output (skipping is no longer needed), and `scripts/reorganise_polonius.sh` handles layout migration without invoking skera.
- **Stale-output cleanup.** Before running skera for each input BAM, polonius now sweeps `dir_out` for any `*.skera.*` files whose filename-derived sample name matches the current input, and removes them. This prevents stale output from a previous run in a different layout from silently overwriting fresh skera output via the final-pass reorganise. Files for other samples are untouched.
- Reorganisation logic is cleanly split into two passes:
  - **Per-sample step** runs after each skera invocation and moves that sample's files into the target layout. Operates on the freshly-created flat `<sample>/` directory.
  - **Final-pass step** runs once over `dir_out` after the per-sample loop, via `reorganise_path()`. Idempotent — files already at their target location are detected by inode and left in place. Catches anything the per-sample step couldn't reach.
- README "Migrating an existing output directory" rewritten: `scripts/reorganise_polonius.sh` is now the documented migration path. The "Resume after interruption" common-workflow entry has been removed.
- Myriad job template no longer includes `--resume`.

### 1.3.0 (May 2026)

- **Default output layout changed**: polonius now writes per-sample directories as `<sample>/` (named after the input BAM stem), without the legacy `skera_` prefix.
- New `--reorganise by-sample` mode: explicit alias for the default layout. Identical output to omitting `--reorganise`; useful in scripts where you want the intended layout to be explicit.
- `scripts/reorganise_polonius.sh` is now bidirectional: it auto-detects the source layout from filenames (not directory structure) and can migrate between any pair of layouts (e.g. `by-sample-type` → `by-type`, `by-type` → `by-sample`, legacy `skera_<sample>/` → anything). Idempotent: re-running with the same target counts already-placed files as "in-place" and makes no changes.
- New `reorganise_path()` function in `lib/reorganise.sh`: walks an arbitrary input path, classifies files by filename, derives the sample name, and moves to the target layout. Used by both `reorganise_polonius.sh` and polonius's final layout pass.
- `--dry-run` is now the preferred spelling; `--dry_run` is still accepted for back-compat.
- Argument parser hardened in both `polonius` and `reorganise_polonius.sh`: value-taking flags now reject a missing value or a following flag (e.g. `--dir_data --verbose`) with a clear error rather than silently consuming the next flag as the value.
- Myriad job template (`scripts/polonius_myriad.sh`): three shellcheck cleanups (`source "$UCL_CONDA_PATH"/...` quoted, `cd ~/... || exit`, `--threads "$NSLOTS"` quoted).
- README "File structure" section renamed to "Repository layout"; "Retrofitting an existing output directory" renamed to "Migrating an existing output directory" and rewritten to reflect bidirectional migration.

### 1.2.0 (May 2026)

- Reorganisation modes redesigned: all modes now move files (no symlinks). Three modes: `by-sample-type`, `by-type`, `by-type-sample`.
- `by-sample-type`: moves files into type subdirs and strips the `skera_` prefix from the sample directory name.
- `by-type` and `by-type-sample`: move files into top-level type directories; `skera_<sample>/` dirs are removed once empty.
- Resume detection updated to find the summary CSV across all layout locations, including after `skera_<sample>/` dirs have been removed.
- `scripts/reorganise_polonius.sh` rewritten with `--mode MODE` argument mirroring the three new modes.
- `lib/reorganise.sh` rewritten: `reorganise_sample_dir()` now takes `mode` and `dir_out` arguments; `locate_summary_file()` now takes `dir_out` and `bam_name` and searches all possible locations.
- Bug fix: `--reorganise` parser now correctly rejects a following flag (e.g. `--reorganise --resume`) with a clear error instead of treating it as the mode value.
- Bug fix: `polonius` wrapper version comment corrected to 1.2.0 and usage example updated to include a required mode argument.
- Improvement: reorganisation step now emits a warning if no classifiable files are found in a sample directory, rather than silently succeeding.

### 1.1.0 (May 2026)

- `--reorganise` now requires an explicit mode (`--reorganise MODE`); bare `--reorganise` without a mode is an error.
- Introduced `by-type` and `by-type-sample` modes (since superseded by v1.2.0 redesign).

### 1.0.0 (May 2026)

- Initial release
- Single script processes all BAMs in a directory
- Supports both AWS and Myriad HPC
- Pass-through of skera arguments via `--skera_args`
- Resume capability for interrupted runs
- `--reorganise` flag to sort each sample's output into type subfolders
- `--drop-nonpassing` flag to delete non-passing BAMs
- Standalone `scripts/reorganise_polonius.sh` migration tool
