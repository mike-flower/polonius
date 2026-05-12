# Polonius

A deconcatenation pipeline for PacBio Kinnex / MAS-Seq HiFi sequencing data using PacBio's skera tool. Sister tool to [Ophelia](https://github.com/mike-flower/ophelia); runs before it in the demultiplexing chain.

**Version 1.1.0**

---

## Quick start

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type
```

Each input HiFi BAM (containing Kinnex-concatenated arrays) is split into one S-read per array segment, producing one `skera_<input_basename>/` output folder per input BAM.

The `--reorganise by-type` flag sorts each sample's files into `deconcatenated/`, `reports/`, and `nonpassing/` subfolders AND creates top-level `deconcatenated/`, `reports/`, `nonpassing/` directories with symlinks pooling files across all samples. Downstream tools (e.g. Ophelia) can then be pointed straight at `dir_out/deconcatenated/`.

See [Output reorganisation](#output-reorganisation) for the four available modes (`none`, `by-sample`, `by-type`, `by-type-sample`) and when to pick each.

---

## Table of contents

- [Where Polonius fits](#where-polonius-fits)
- [Installation](#installation)
- [Input file requirements](#input-file-requirements)
- [File structure](#file-structure)
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

# Create logs directory (required for Myriad SGE job output)
mkdir -p logs

# Verify
./polonius --help
```

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

## File structure

```
polonius/
├── polonius                        # Main wrapper script
├── scripts/
│   ├── polonius_cli.sh             # Core pipeline logic
│   ├── polonius_myriad.sh          # HPC job submission template
│   └── reorganise_polonius.sh      # Standalone retrofit tool (by-sample layer only)
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
    --reorganise by-type --dry_run
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
#$ -wd /home/skgtmdf/Scratch/bin/polonius
#$ -o logs/polonius_$JOB_ID.out
#$ -e logs/polonius_$JOB_ID.err
#$ -M your.email@ucl.ac.uk
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
    --reorganise by-type \
    --resume
```

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

### Output organisation

| Parameter | Default | Description |
|---|---|---|
| `--reorganise MODE` | off | Reorganise output. MODE must be `by-sample`, `by-type`, or `by-type-sample`. Omit the flag (or use `--no-reorganise`) for no reorganisation. See [Output reorganisation](#output-reorganisation). |
| `--no-reorganise` | – | Shortcut for `--reorganise none` |
| `--drop-nonpassing` | Off | Delete non-passing BAMs instead of moving them (irreversible; requires `--reorganise MODE` to be set to any mode other than `none`) |

### Execution options

| Parameter | Default | Description |
|---|---|---|
| `--resume` | On | Skip files where `*.skera.summary.csv` exists and is complete |
| `--no-resume` | – | Force re-processing of all files |
| `--dry_run` | Off | Show commands without executing |
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

The four reorganisation modes produce four different on-disk layouts. Examples below assume 3 input BAMs (bcM0001, bcM0002, bcM0004).

### `--reorganise none` (or no flag) – raw skera output, flat per sample

```
dir_out/
├── skera_m84277_...bcM0001/
│   ├── m84277_...bcM0001.skera.bam                   # Deconcatenated S-reads
│   ├── m84277_...bcM0001.skera.bam.pbi               # PacBio index
│   ├── m84277_...bcM0001.skera.non_passing.bam       # Reads that didn't form arrays
│   ├── m84277_...bcM0001.skera.non_passing.bam.pbi
│   ├── m84277_...bcM0001.skera.summary.csv           # Summary statistics
│   ├── m84277_...bcM0001.skera.summary.json
│   ├── m84277_...bcM0001.skera.ligations.csv         # Adapter adjacency matrix
│   ├── m84277_...bcM0001.skera.read_lengths.csv      # S-read length distribution
│   └── m84277_...bcM0001.skera.found_adapters.csv.gz # Per-read adapter calls
├── skera_m84277_...bcM0002/
│   └── ...
└── polonius_summary.txt                              # Cross-sample summary table
```

### `--reorganise by-sample` – per-sample subdirs only

```
dir_out/
├── skera_m84277_...bcM0001/
│   ├── deconcatenated/                               # *.skera.bam, *.skera.bam.pbi
│   ├── reports/                                      # *.summary.*, *.ligations.csv, *.read_lengths.csv, *.found_adapters.csv.gz
│   └── nonpassing/                                   # *.non_passing.* (omitted with --drop-nonpassing)
├── skera_m84277_...bcM0002/
│   └── ...
└── polonius_summary.txt
```

### `--reorganise by-type` – top-level type-pooled symlinks (recommended)

```
dir_out/
├── deconcatenated/                                   # ← symlinks across all samples
│   ├── m84277_...bcM0001.skera.bam -> ../skera_m84277_...bcM0001/deconcatenated/...
│   ├── m84277_...bcM0001.skera.bam.pbi
│   ├── m84277_...bcM0002.skera.bam
│   └── ...
├── reports/                                          # ← symlinks; all reports in one place
│   ├── m84277_...bcM0001.skera.summary.csv
│   ├── m84277_...bcM0001.skera.ligations.csv
│   ├── m84277_...bcM0002.skera.summary.csv
│   └── ...
├── nonpassing/                                       # ← symlinks (omitted with --drop-nonpassing)
│   └── ...
├── skera_m84277_...bcM0001/                          # per-sample dirs preserved (forensic browsing)
│   ├── deconcatenated/
│   ├── reports/
│   └── nonpassing/
├── skera_m84277_...bcM0002/
│   └── ...
└── polonius_summary.txt
```

### `--reorganise by-type-sample` – top-level type dirs with per-sample subfolders

```
dir_out/
├── deconcatenated/
│   ├── m84277_...bcM0001/                            # ← symlinks per sample
│   │   ├── m84277_...bcM0001.skera.bam
│   │   └── m84277_...bcM0001.skera.bam.pbi
│   ├── m84277_...bcM0002/
│   └── m84277_...bcM0004/
├── reports/
│   ├── m84277_...bcM0001/
│   ├── m84277_...bcM0002/
│   └── m84277_...bcM0004/
├── nonpassing/
│   ├── m84277_...bcM0001/
│   └── ... (omitted dirs with --drop-nonpassing)
├── skera_m84277_...bcM0001/                          # per-sample dirs preserved
│   └── ...
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

By default polonius leaves skera's output untouched (`--reorganise none`): one flat directory per input BAM, files identifiable by name. The `--reorganise MODE` flag turns on tidier layouts.

There are four modes, in increasing order of structure:

### `none` (default when no `--reorganise` flag)

Skera's raw output. One `skera_<input_basename>/` directory per input BAM, all output files dumped flat inside. Useful when you'll consume the files individually and don't care about layout, or when you want absolute minimal intervention.

### `by-sample` (`--reorganise by-sample`)

Each `skera_<sample>/` directory is split into three subfolders:

- **`deconcatenated/`** – the main S-reads BAM and its index (`*.skera.bam`, `*.skera.bam.pbi`)
- **`reports/`** – everything skera emits about the run as a whole (`*.summary.csv`, `*.summary.json`, `*.ligations.csv`, `*.read_lengths.csv`, `*.found_adapters.csv.gz`)
- **`nonpassing/`** – reads that didn't form a clean array (`*.skera.non_passing.bam`, `*.skera.non_passing.bam.pbi`)

Sample-centric: easy to delete one sample's stuff entirely, but cross-sample comparisons (e.g. comparing every sample's `summary.csv`) require digging into each subfolder.

### `by-type` (`--reorganise by-type`, **recommended**)

Everything `by-sample` does, **plus** three top-level directories at `dir_out/` containing symlinks pooled across all samples:

- `dir_out/deconcatenated/` – symlinks to every passing `*.skera.bam` and `.bam.pbi` from every sample
- `dir_out/reports/` – symlinks to every report file from every sample
- `dir_out/nonpassing/` – symlinks to every non-passing BAM (omitted if `--drop-nonpassing` was used)

Type-centric and flat. Filenames identify which sample each file came from (the Kinnex barcode is embedded in the filename). Downstream tools like Ophelia can be pointed at `dir_out/deconcatenated/` in a single command without any extra glob or per-library loop.

**Why symlinks, not copies:** the real files always live inside `skera_<sample>/<type>/`. The top-level dirs are convenience views with zero disk cost. Re-running with `--resume` simply refreshes the symlinks (`ln -sf` is idempotent), and removing them later (`rm -rf dir_out/deconcatenated`) is safe – it never touches the underlying data.

### `by-type-sample` (top-level type dirs with per-sample subfolders)

Like `by-type`, but the top-level type dirs are themselves divided into per-sample subdirectories:

- `dir_out/deconcatenated/<sample>/` – symlinks for that sample only
- `dir_out/reports/<sample>/`
- `dir_out/nonpassing/<sample>/`

Useful at larger scale (dozens to hundreds of libraries) where the flat `by-type` directories would become unwieldy to browse. Probably overkill for the typical 1–12-library Kinnex run.

### Saving disk space – `--drop-nonpassing`

Non-passing BAMs are usually a small minority (~3% of reads in a clean Kinnex prep), so the disk saving is much less than `--drop-unbarcoded` in Ophelia – but the option is here for completeness. Irreversible, opt-in, requires `--reorganise MODE` (any mode other than `none`):

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --drop-nonpassing
```

In `by-type` and `by-type-sample` modes, the top-level `nonpassing/` directory will simply not be created if there are no non-passing files to symlink.

### Retrofitting an existing output directory

Two ways to apply a reorganised layout to an existing flat output directory:

**Option 1 – re-run polonius with `--reorganise by-type --resume`.** The resume logic is layout-aware, so already-completed samples won't be re-run through skera; they'll just be tidied. This is the only route that produces the top-level `by-type` or `by-type-sample` symlink pools.

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --resume
```

**Option 2 – use the standalone `reorganise_polonius.sh` script.** Right choice when you don't want to re-supply the original polonius parameters, when the skera environment isn't available, or when reorganising someone else's output. Note that this script only handles the `by-sample` layer (per-sample type subfolders); for `by-type` or `by-type-sample` top-level pools, use Option 1.

```bash
# Whole deconcat/ directory
scripts/reorganise_polonius.sh --path ~/results/deconcat

# Dry run first
scripts/reorganise_polonius.sh --path ~/results/deconcat --dry-run

# Single sample dir
scripts/reorganise_polonius.sh --path ~/results/deconcat/skera_m84277_..._bcM0001

# Drop non-passing BAMs
scripts/reorganise_polonius.sh --path ~/results/deconcat --drop-nonpassing
```

Both routes use the same classification logic (`lib/reorganise.sh`) for the per-sample layer.

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

Polonius is a thin wrapper around `skera split`. Any skera option can be passed through via `--skera_args "..."`. As of skera 1.4.0, the most commonly relevant flags are:

| Flag | Purpose |
|---|---|
| `--num-threads N` | Threads (polonius sets this from `--threads`; don't pass directly) |
| `--min-rq F` | Minimum predicted read quality (default 0.99) |

The full option list is available via `skera split --help` once you've activated the conda environment.

---

## Common workflows

### 1. Basic deconcatenation

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type
```

`--reorganise by-type` produces per-sample structure for browsing, plus top-level type-pooled symlinks for downstream consumption.

### 2. Feed Polonius output into Ophelia

With the default `by-type` layout, Ophelia consumes the pooled BAMs in one call:

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

If your samples need per-library biosample CSVs, run Ophelia per library against the same pooled directory using `--file_pattern`:

```bash
for BC in bcM0001 bcM0002 bcM0004; do
    ./ophelia \
        --dir_data ~/results/deconcat/deconcatenated \
        --dir_out ~/results/sample_demux/${BC} \
        --barcode_ref ~/refs/pacbio_kinnex16S_barcodes.fasta \
        --biosample_csv ~/refs/biosample_${BC}.csv \
        --file_pattern "*${BC}*.bam" \
        --reorganise
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

### 4. Legacy per-sample-only layout

If you don't want the top-level type pools (e.g. you're not chaining straight into Ophelia and prefer browsing per-sample):

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-sample
```

### 5. Test run (dry run)

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --dry_run
```

### 6. Resume after interruption

The `--resume` option (default) skips files where a complete `*.skera.summary.csv` already exists. The reorganisation steps (both per-sample and top-level pooling) are idempotent under `--resume` – top-level symlinks are simply refreshed with `ln -sf`.

```bash
./polonius ... --no-resume      # force re-processing of all files
```

### 7. Save disk space on confirmed runs

```bash
./polonius \
    --dir_data ~/data/hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type --drop-nonpassing
```

Or retrofit an existing run for the per-sample layer:

```bash
scripts/reorganise_polonius.sh --path ~/results/deconcat --drop-nonpassing
```

### 8. Larger-scale runs (many libraries)

For runs with dozens of Kinnex libraries, the flat `by-type` directories can get crowded. Use `by-type-sample` to keep the top level tidy:

```bash
./polonius \
    --dir_data ~/data/many_hifi_reads \
    --dir_out ~/results/deconcat \
    --adapter_ref ~/refs/mas-seq_adapter_v3/mas8_primers.fasta \
    --reorganise by-type-sample
```

Each top-level type dir then contains one subdir per Kinnex library.

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

Polonius is strict about mode names. Valid values: `none`, `by-sample`, `by-type`, `by-type-sample`. Note the British spelling (`-ise`); the American spelling `--reorganize by-type` is also accepted.

### Top-level `deconcatenated/`, `reports/`, `nonpassing/` are missing after a run

If you used `--reorganise by-sample` (or no `--reorganise` at all), the top-level type dirs aren't created – they're a feature of `by-type` and `by-type-sample`. To add them retroactively:

```bash
./polonius ... --reorganise by-type --resume
```

This skips skera (all samples already processed) and just does the pooling step.

### Symlinks in top-level type dirs are broken

Broken symlinks indicate the underlying files in `skera_<sample>/<type>/` were moved or deleted after the pool step ran. The symlinks use absolute paths. To rebuild:

```bash
rm -rf dir_out/deconcatenated dir_out/reports dir_out/nonpassing
./polonius ... --reorganise by-type --resume
```

`rm -rf` on the top-level type dirs only removes the symlinks, never the underlying BAMs.

### Low full-array percentage

Check the `*.summary.csv` files. If the mode is well below the expected maximum (8/12/16) or the full-array fraction is poor:

- **Wrong adapter set.** Run polonius and check the inferred array size at startup. Try a different `mas*_primers.fasta`.
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

### 1.1.0 (May 2026)

- `--reorganise` now requires an explicit mode: `--reorganise MODE`. Bare `--reorganise` (without `=MODE`) is an error. Valid modes: `by-sample`, `by-type`, `by-type-sample`. Omit the flag entirely (or use `--no-reorganise`) for no reorganisation.
- New `by-type` and `by-type-sample` modes add top-level `deconcatenated/`, `reports/`, `nonpassing/` directories at `dir_out/` containing symlinks pooling files across all samples. `by-type` pools flat; `by-type-sample` groups symlinks by sample within each type dir. Uses symlinks (zero disk cost), idempotent under `--resume`, doesn't disturb the underlying `skera_<sample>/` structure.
- Downstream tools (e.g. Ophelia) can be pointed straight at `dir_out/deconcatenated/` in a single command, eliminating per-library loops or manual symlink/copy steps.
- `--reorganise none` and `--no-reorganise` are equivalent.
- Behavioural change vs v1.0.0: bare `--reorganise` previously meant the `by-sample` layout; in v1.1.0 a mode is required. Pass `--reorganise by-sample` explicitly to restore the v1.0.0 behaviour.
- Updated `scripts/polonius_myriad.sh` template to use `--reorganise by-type`.

### 1.0.0 (May 2026)

- Initial release
- Single script processes all BAMs in a directory
- Supports both AWS and Myriad HPC
- Pass-through of skera arguments via `--skera_args`
- Resume capability for interrupted runs
- `--reorganise` flag to sort each sample's output into `deconcatenated/`, `reports/`, and `nonpassing/` subfolders
- `--drop-nonpassing` flag to delete non-passing BAMs (requires `--reorganise`)
- Layout-aware resume: `--resume` correctly detects completed samples in either flat or reorganised layout
- Standalone `scripts/reorganise_polonius.sh` retrofit tool sharing the same classification logic as `--reorganise`
- Automatic kit inference from adapter FASTA entry count (9 → MAS8, 13 → MAS12, 17 → MAS16)