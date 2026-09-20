# Pangenome WGS pipelines for WGSpipeline

Drop-in replacements for the NCGM WGSpipeline germline workflow that align to a
pangenome graph instead of linear GRCh38 while keeping every downstream consumer
unchanged.

- **Same contract**: identical inputs (FASTQ pairs + `@RG` strings + 4 interval BEDs + `prefix`), identical output layout (alignment BAM + 5 ploidy-aware gVCFs), GRCh38 coordinates.
- **Surjection at the aligner**: reads are mapped to the graph and projected onto the GRCh38 reference paths; everything downstream (`samtools`, DeepVariant, Manta, CNVkit, ...) stays linear.
- **CWL first**: the CWL files are the source of truth; see the design deck `docs/WGSpipeline-pangenome-concept_1.pptx` for the full rationale.

## Workflow

| File | Aligner | Variant caller | Notes |
| --- | --- | --- | --- |
| `Workflows/germline-pangenome-cpu.cwl` | `vg giraffe` (one job per read group, CWL scatter) | DeepVariant (`google/deepvariant:1.10.0`) | Portable; runs without containers when tools are on `$PATH` |
| `Workflows/germline-pangenome-gpu.cwl` | `vg giraffe` (CPU, same as above) | DeepVariant GPU (`google/deepvariant:1.10.0-gpu`) | Identical inputs/outputs to the CPU workflow; the five DeepVariant steps run on the GPU (auto-detected when CUDA is visible). Requires a CUDA driver on the host and a container started with GPU passthrough (`singularity exec --nv ...`) |

Every input lane is mapped with `vg giraffe` onto the pangenome. Two ways to
supply reads (can be combined, lanes are concatenated):

- **FASTQ track** (default): `fq1`/`fq2` + `rg` → `vg giraffe` alignment.
- **CRAM track**: an aligned CRAM (linear/`ref` coordinates, `@SQ` matching
  `ref`) is decoded with `ref` back to read-pair FASTQ (`samtools collate` +
  `fastq`, its `@RG` header is carried over, orphans are dropped), then
  re-mapped onto the pangenome with `vg giraffe` exactly like a FASTQ lane.

The pangenome graph + `giraffe` indexes (`gbz`, `dist`, `min`, `zipcodes`,
`ref_paths`) are required in BOTH modes.

## Inputs

| Parameter | Type | Description |
| --- | --- | --- |
| `fq1` / `fq2` | `File[]` | Read-pair FASTQs, one entry per read group (may be omitted; use `cram` instead) |
| `rg` | `string[]` | Full `@RG` string per read group, e.g. `@RG\tID:L1\tPL:ILLUMINA\tSM:SAMPLE` (literal `\t` or real tabs both work) |
| `cram` | `File` | Aligned CRAM in reference coordinates (`@SQ` matching `ref`); recovered to FASTQ and re-mapped onto the pangenome (its `@RG` is carried over) |
| `gbz` | `File` | Pangenome graph (required) |
| `dist` / `min` / `zipcodes` | `File` | giraffe distance / minimizer / zipcode indexes (required) |
| `ref_paths` | `File` | Ordered reference path names (PanSN), one per line; drives giraffe `@SQ` and surjection (required) |
| `ref` | `File` | Linear GRCh38 (or T2T-CHM13) FASTA (+`.fai`); sequences must match the graph reference paths |
| `ref_path_prefix` | `string` | PanSN prefix to strip from `@SQ`, e.g. `GRCh38#0#`; `""` disables |
| `autosome_interval`, `PAR_interval`, `chrX_interval`, `chrY_interval` | `File` | Interval BEDs (from `interval_files/`) |
| `prefix` | `string` | Output prefix |
| `threads` | `int` | CPU threads (default 32) |
| `emit_gam` | `boolean` | Keep the per-lane graph-space alignments (`<prefix>.<lane>.gam`) as workflow outputs (default `false`). Adds one GAM write per lane; the BAM is always produced from the same one-pass via `vg surject` |
| `keep_bam` | `boolean` | Materialise the final duplicate-marked `<prefix>.bam` (+`.bai`) in the output directory (default `true`). Set `false` to skip it; the BAM is still built internally because DeepVariant requires it |
| `call_sv` | `boolean` | Genotype the SVs embedded in the pangenome graph (`vg pack` + `vg call`) and emit `<prefix>.sv.vcf.gz` (default `false`) |
| `snarls` | `File` | Precomputed snarls for the graph (`vg snarls`); optional but strongly recommended for whole-genome graphs. Ignored when `call_sv` is false |
| `sv_min_length` | `int` | Minimum graph-site traversal length to be genotyped as an SV (`vg call -c`, default 50) |

## Outputs

```
<prefix>.bam                      (+ .bai)   duplicate-marked BAM, reference (GRCh38/T2T) coords (only when keep_bam=true)
<prefix>.markdup.metrics                      (BQSR replacement)
<prefix>.autosome.g.vcf.gz       (+ .tbi)  diploid
<prefix>.PAR.g.vcf.gz            (+ .tbi)  diploid
<prefix>.chrX_female.g.vcf.gz    (+ .tbi)  diploid
<prefix>.chrX_male.g.vcf.gz      (+ .tbi)  haploid (--haploid-contigs chrX)
<prefix>.chrY.g.vcf.gz           (+ .tbi)  haploid (--haploid-contigs chrY)
<prefix>.<lane>.gam                           per-lane graph-space alignment (only when emit_gam=true)
<prefix>.sv.vcf.gz               (+ .tbi)  genotyped graph SVs (only when call_sv=true)
```

## Preparing a graph

```bash
# Auto-build the =>giraffe index set<= from a GBZ and validate the linear reference
./scripts/prepare_pangenome_indexes.sh path/to/graph.gbz mygraph GRCh38 Homo_sapiens_assembly38.fasta
# produces mygraph.ref_paths.txt, mygraph.dist, mygraph.min, mygraph.zipcodes
# plus mygraph.snarls (only needed for the call_sv / SV genotyping track)
# and suggests the ref_path_prefix to pass to the workflows
export SKIP_AUTOINDEX=1   # when the graph already ships .dist/.min/.zipcodes (e.g. HPRC)
export SKIP_SNARLS=1      # when SV genotyping (call_sv) is not needed
```

The script now auto-detects the reference sample: it keeps only full-length
reference paths (fragment paths like `GRCh38#0#chr1[585988]` are filtered out)
and, if the requested/default sample has none, falls back to the sample with the
most complete paths. For `data/JaSaPaGe.gbz` (T2T-CHM13 backbone) it reports
`ref_path_prefix=CHM13v2#0#` and 25 reference contigs (22 autosomes + chrX +
chrY + chrM). The linear reference and the interval BEDs must match that
backbone:

- Linear reference extracted from the graph itself (guaranteed sequence match):
  `vg paths -x data/JaSaPaGe.gbz -S CHM13v2 -F` → strip the `CHM13v2#0#`
  prefix → `data/jasa.chm13.fa` (+ `.fai` / `.dict`).
- `interval_files/` holds GRCh38 BEDs; T2T-CHM13 BEDs live in
  `interval_files/chm13_t2t/` (autosome = full-length chX/chr1-22; chrX/chrY
  minus PAR). PAR coordinates were derived from `data/jasa.chm13.fa`: the
  JaSaPaGe chrY reference is PAR-masked with Ns (PAR1 `0-2,458,320`, PAR2
  `62,122,809-62,460,029`), so chrX carries the callable PAR: chrX `0-2,458,320`
  and `153,922,346-154,259,566` (`interval_files/chm13_t2t/PAR.bed`).

## Behind the scenes (design notes)

- **Contig names**: giraffe writes full PanSN path names (`GRCh38#0#chr1`) into `@SQ`. The workflows strip the prefix on the header only (`samtools reheader -c 'sed ...'`), so the output BAM/CRAM matches `Homo_sapiens_assembly38.fasta` and existing interval BEDs.
- **Read groups**: `vg giraffe -R/-N` only carries ID/SM; the full `@RG` string is applied afterwards with `samtools addreplacerg -m overwrite_all -w -O BAM,level=6`. The output format is pinned because this `samtools` build otherwise writes **uncompressed** BAM (a ~5x size blow-up, e.g. 335 GB instead of ~63 GB for one lane).
- **Duplicate marking**: lane prep (`samtools reheader` + `addreplacerg`) keeps the input name-collated order; the per-lane BAMs are concatenated and passed to biobambam2 **`bamsormadup`**, which does mate fixing + coordinate sorting + duplicate marking (incl. optical duplicates) in one streaming pass. This replaces the old `samtools sort -n` / `fixmate -m` / `sort` + `samtools markdup` chain (~2x faster end to end; `fixmate` was the single largest cost) and needs no `MC`/`ms` tags.
- **Ploidy**: `--haploid-contigs chrX` / `--haploid-contigs chrY` on the male tracks reproduces HaplotypeCaller `--ploidy 1`. `chrX.bed` already excludes PAR, so no PAR handling is needed for the callers.
- **BQSR** is dropped (DeepVariant does not need it); the CPU track emits `markdup` metrics instead, mirroring the WGSpipeline output slot.
- **rg `\t` escaping**: pass `--rg "@RG\\tID:..."` on the shell (literal backslash-t). cwltool passes it through unchanged; the postprocess script converts it to a real tab.

## Running

The CWL files use `DockerRequirement` as **hints** (not hard requirements), so
the same workflow runs either with containers (`cwltool --singularity` / docker) or,
when the tools are already on `$PATH`, natively with `--no-container`. This matches
the hackathon CPU box, where the SIF image (`image/deepvariant-opencode-cpu.sif`)
ships DeepVariant 1.10.0, samtools and bcftools, and `vg` / `cwltool` / `node` are
on `$PATH` in the image home.

```bash
# Validate
cwltool --validate --no-container Workflows/germline-pangenome-cpu.cwl

# CPU track from FASTQs, native tools (no containers, no GPU):
cwltool --no-container --parallel --outdir out/ Workflows/germline-pangenome-cpu.cwl \
  --fq1 R1_L1.fastq --fq1 R1_L2.fastq \
  --fq2 R2_L1.fastq --fq2 R2_L2.fastq \
  --rg "@RG\\tID:L1\\tPL:ILLUMINA\\tSM:SAMPLE" \
  --rg "@RG\\tID:L2\\tPL:ILLUMINA\\tSM:SAMPLE" \
  --gbz graph.gbz --dist graph.dist --min graph.min --zipcodes graph.zipcodes \
  --ref_paths graph.ref_paths.txt --ref Homo_sapiens_assembly38.fasta \
  --autosome_interval interval_files/autosome.bed \
  --autosome_chunks_count 8 \
  --PAR_interval interval_files/PAR.bed \
  --chrX_interval interval_files/chrX.bed \
  --chrY_interval interval_files/chrY.bed \
  --prefix SAMPLE --threads 32

# CPU track from a CRAM (aligned on ref; reads are recovered to FASTQ and
# re-mapped onto the pangenome, so the graph + giraffe indexes are required):
cwltool --no-container --parallel --outdir out/ Workflows/germline-pangenome-cpu.cwl \
  --cram SAMPLE.aligned.cram \
  --gbz graph.gbz --dist graph.dist --min graph.min --zipcodes graph.zipcodes \
  --ref_paths graph.ref_paths.txt --ref Homo_sapiens_assembly38.fasta \
  --autosome_interval interval_files/autosome.bed \
  --autosome_chunks_count 8 \
  --PAR_interval interval_files/PAR.bed \
  --chrX_interval interval_files/chrX.bed \
  --chrY_interval interval_files/chrY.bed \
  --prefix SAMPLE --threads 32
```

**`cwltool --parallel`**: the workflow only executes steps in parallel when
cwltool is told to run every job whose inputs are ready at the same time; by
default it runs them one after another. Pass `--parallel` (short `-p`) so the
scattered jobs really overlap — the `align_chunks` giraffe blocks, the
`autosome_chunks_count` chunks, and the per-chunk DeepVariant steps. This is
required for `--gpu_count > 1` to keep more than one GPU busy, and without it a
real WGS run is dramatically slower. Because `--parallel` dispatches all ready
jobs at once, peak CPU is `--threads` × the number of concurrent jobs: size
`--threads` to the node's core count (e.g. 64 on a 64-core box) and raise
`align_chunks` only while the node has the memory (each block is a separate
process that reloads the whole graph, see *Parallelisation* below).

A job-order JSON can be used instead of CLI inputs, see **Toy demo** below
(`tests/toy/jobs/`); omit the `fq1`/`fq2`/`rg` keys when using `cram`.

CPU-only environment prerequisites (this hackathon box already has all of them):

- `vg` in `$PATH` (static binary; symlinked from `$HOME/.local/bin` / `$HOME/go/bin`)
- `cwltool` (`pip install cwltool`) and `node` (for inline JS expressions) in `$PATH`
- `run_deepvariant` (`/opt/deepvariant/bin`) and `samtools`/`bcftools`
  (`/opt/conda/envs/bio/bin`) on `$PATH` — already set inside the SIF
- `bamsormadup` (biobambam2) on `$PATH` for the duplicate-marking step; bundled
  in both SIFs, or install the `biobambam2` distro package when running natively

The container images (used when Docker is available) are:
`quay.io/vgteam/vg:v1.70.0`,
`google/deepvariant:1.10.0`,
`quay.io/biocontainers/samtools:1.21--h96c455f_1`,
`quay.io/biocontainers/biobambam2` (hint only for the markdup step; `bamsormadup`
and `samtools` must both be on `$PATH` under `--no-container`).

The GPU workflow additionally uses `google/deepvariant:1.10.0-gpu` for the
five variant-calling steps (`vg giraffe` and `samtools` stay on CPU).

### GPU track

```bash
cwltool --validate --no-container Workflows/germline-pangenome-gpu.cwl

cwltool --no-container --parallel --outdir out/ Workflows/germline-pangenome-gpu.cwl \
  --fq1 R1_L1.fastq --fq2 R2_L1.fastq \
  --rg "@RG\\tID:L1\\tPL:ILLUMINA\\tSM:SAMPLE" \
  --gbz graph.gbz --dist graph.dist --min graph.min --zipcodes graph.zipcodes \
  --ref_paths graph.ref_paths.txt --ref Homo_sapiens_assembly38.fasta \
  --autosome_interval interval_files/autosome.bed \
  --autosome_chunks_count 22 \
  --PAR_interval interval_files/PAR.bed \
  --chrX_interval interval_files/chrX.bed \
  --chrY_interval interval_files/chrY.bed \
  --prefix SAMPLE --threads 64 --gpu_count 2
```

CPU usage and GPU usage are configured **independently**:

- `--threads N` — CPU threads for `vg giraffe` and the samtools steps (use the
  CPU core count of the run node, e.g. `--threads 64`).
- `--gpu_count N` — number of DeepVariant shards run on the GPU (a shard = one
  TensorFlow GPU session), i.e. the number of GPUs the caller devotes to the run
  (`--gpu_count 2` on a two-GPU box; default 1).

CUDA must be visible to the container (`NVIDIA_VISIBLE_DEVICES` / `--nv`); if you
want to restrict which GPUs are used, pin them via `NVIDIA_VISIBLE_DEVICES`
(e.g. `=0,1`), matching `--gpu_count`.

## Self-contained SIF (no-setup on any host)

`./sif-build.def` produces a single image containing DeepVariant, samtools/bcftools,
`vg`, `node`, `cwltool`, biobambam2 (`bamsormadup`) and the workflow/tool/script
tree under `/opt/pangenome`.
Reference data (the ~54 GB JaSaPaGe graph + indexes + linear ref) is **not**
bundled; bind-mount it or pass host paths at runtime.

```bash
cd /home/tago/biohack/pggl-workflow
./scripts/stage-sif-assets.sh                       # stage sif-stage/ + image/ build assets
singularity build deepvariant-opencode-cpu-vg.sif sif-build.def      # on a host

# on any other host, zero setup:
singularity exec deepvariant-opencode-cpu-vg.sif \
  /opt/pangenome/run-pangenome.sh \
  --cram $PWD/sample.cram --ref $PWD/jasa.chm13.fa \
  --autosome_interval /opt/pangenome/interval_files/chm13_t2t/autosome.bed \
  --PAR_interval      /opt/pangenome/interval_files/chm13_t2t/PAR.bed \
  --chrX_interval     /opt/pangenome/interval_files/chm13_t2t/chrX.bed \
  --chrY_interval     /opt/pangenome/interval_files/chm13_t2t/chrY.bed \
  --prefix SAMPLE --outdir out/
```

(For an air-gapped target host, build the SIF on an online host with
`./scripts/fetch-offline-bundle.sh` and install it with
`./scripts/setup-offline.sh`; see *Offline (air-gapped) setup* below.)

Build notes: singularity is required on the build host (not installable inside
the base image). Before building, run `./scripts/stage-sif-assets.sh` once:
it creates `sif-stage/` (vg, node, cwltool wheels, `biobambam2/`) and `image/`
(the CPU base SIF for the `localimage` bootstrap + the opencode tarball) by
copying from the working repo, falling back to the original downloads
(GitHub releases for vg / nodejs.org / `pip download` / the Ubuntu jammy
archive for the biobambam2 debs) when that is unavailable. No docker is
needed anywhere. `bamsormadup` is installed under
`/opt/biobambam2` with its private `libmaus2`/`libgpgme`/`libnettle` libs, and
exposed as `/usr/local/bin/bamsormadup` via a wrapper that sets
`LD_LIBRARY_PATH` (so no system lib dirs are touched). Python is 3.10 with no
venv and no PEP 668 marker, so cwltool is installed system-wide from the wheels
staged in `sif-stage/` (offline). The final image's `%environment` already sets
`PATH` and the image's `/opt/deepvariant/bin/run_deepvariant` needs
`TF_USE_LEGACY_KERAS=1`. `tools/filter_fastq.py` is bundled at
`/opt/pangenome/tools/` in both images.

### GPU SIF

`./sif-build-gpu.def` is the GPU equivalent, based on
`google/deepvariant:1.10.0-gpu` (Ubuntu 22.04 / glibc 2.35 + CUDA). It adds the
GPU workflow (`/opt/pangenome/Workflows/germline-pangenome-gpu.cwl`) and a
`/opt/pangenome/run-pangenome-gpu.sh` launcher; vg, samtools, cwltool and
biobambam2 are installed exactly as in the CPU image, so only the five
DeepVariant steps use the GPU.

```bash
# Run the same staging first (build assets are shared with the CPU SIF):
./scripts/stage-sif-assets.sh

# Build on a host that can pull the docker image and has the GPU toolchain:
singularity build deepvariant-opencode-gpu-vg.sif sif-build-gpu.def

# Run with GPU passthrough (--nv binds nvidia devices/driver to the container):
singularity exec --nv deepvariant-opencode-gpu-vg.sif \
  /opt/pangenome/run-pangenome-gpu.sh \
  --fq1 SAMPLE.R1.fastq.gz --fq2 SAMPLE.R2.fastq.gz \
  --rg '@RG\\tID:L1\\tPL:ILLUMINA\\tSM:SAMPLE' \
  --gbz ... --dist ... --min ... --zipcodes ... --ref_paths ... \
  --ref ... --ref_path_prefix CHM13v2#0# \
  --autosome_interval /opt/pangenome/interval_files/chm13_t2t/autosome.bed \
  --PAR_interval      /opt/pangenome/interval_files/chm13_t2t/PAR.bed \
  --chrX_interval     /opt/pangenome/interval_files/chm13_t2t/chrX.bed \
  --chrY_interval     /opt/pangenome/interval_files/chm13_t2t/chrY.bed \
  --prefix SAMPLE --outdir out/
```

Verified on a host with V100S GPUs (driver 550.x, devices `/dev/nvidia0`,
`/dev/nvidia1`). The image's `%test` validates `germline-pangenome-gpu.cwl`
with `cwltool --validate` at build time. The CPU SIF (`sif-build.def`) remains
the portable fallback for hosts without a GPU.

## Offline (air-gapped) setup

The pipeline never needs the network at run time — only fetching the apptainer
image and its build inputs does. Two scripts split along that line, see
`docs/OFFLINE.md` for the full procedure:

```bash
# on an ONLINE host: collect image + build inputs + repo snapshot into one bundle
./scripts/fetch-offline-bundle.sh --archive          # (--gpu for the GPU image too)
#   -> offline-bundle/ and pggl-offline-bundle-<date>.tar (+ .sha256)

# carry the tar over, then on the OFFLINE host:
./scripts/setup-offline.sh --bundle offline-bundle --verify
#   verifies the checksums, installs (or builds) deepvariant-opencode-cpu-vg.sif,
#   validates the workflow inside the image and runs the toy demo
```

The bundle carries the ready-to-run SIF when the online host has
apptainer/singularity (`--no-build`/`--with-base` ship the base images plus
`sif-stage/` instead, so the offline host can build them itself), and
`--tool-images` adds the per-tool SIFs for `cwltool --singularity`.
`scripts/stage-sif-assets.sh` accepts `PGGL_SRC=<unpacked bundle>` and
`PGGL_OFFLINE=1` (fail fast instead of downloading).

**Not** in the bundle: the pangenome graph, its giraffe indexes and the linear
reference (~54 GB) — copy those separately; the index preparation itself runs
offline from the image (`apptainer exec ... prepare_pangenome_indexes.sh`).

## Toy demo (self-contained)

All toy inputs and job files live under `tests/toy/`. The job files use
**paths relative to their own directory** (`tests/toy/jobs/`), so cwltool can be
run from anywhere in the checkout.

    tests/toy/
    ├── L1_R1.fastq, L1_R2.fastq, L2_R1.fastq, L2_R2.fastq   <- paired FASTQs (2 lanes)
    ├── toy.giraffe.gbz, toy.dist, toy.shortread.withzip.min, toy.shortread.zipcodes, mygraph.ref_paths.txt
    ├── ref.fa (+.fai) + autosome/PAR/chrX/chrY.bed
    ├── toy_in.cram                <- 2,400 reads aligned to ref.fa (decode with ref)
    └── jobs/                      <- ready-to-run job-order JSONs (paths relative to jobs/)

Run both tracks (each takes ~2 min on the toy data):

```bash
# 1) FASTQ track: paired FASTQs (2 lanes) -> vg giraffe (pangenome) -> DV
cwltool --no-container --outdir tests/toy/demo_out/fastq_track \
  Workflows/germline-pangenome-cpu.cwl tests/toy/jobs/toy_job.json

# 2) CRAM track: reads are recovered to FASTQ *inside the workflow*
#    (samtools collate -> fastq -T ref) and re-mapped with vg giraffe
cwltool --no-container --outdir tests/toy/demo_out/cram_track \
  Workflows/germline-pangenome-cpu.cwl tests/toy/jobs/toy_cram_job.json
```

Each run produces `<prefix>.bam` (+`.bai`), `<prefix>.markdup.metrics` and five
gVCFs (`autosome`, `PAR`, `chrX_female`, `chrX_male`, `chrY`, +`.tbi`). The two
job files cover the FASTQ and CRAM tracks; swap the workflow path for
`Workflows/germline-pangenome-gpu.cwl` to smoke-test the GPU variant on the same
toy inputs.

`jobs/toy_job.json` (and the top-level `toy.json`) also show the new
`autosome_chunks_count` input (the toy autosome has a single contig, so any
count there just yields one chunk).

Two job files demonstrate the retention options (identical gVCFs in all three
cases):

```bash
# keep the per-lane GAM in addition to the BAM -> L1.gam, L2.gam
cwltool --no-container --outdir tests/toy/demo_out/emit_gam \
  Workflows/germline-pangenome-cpu.cwl tests/toy/jobs/toy_emit_gam_job.json

# drop the final BAM from the outputs (still built internally for DeepVariant)
cwltool --no-container --outdir tests/toy/demo_out/no_bam \
  Workflows/germline-pangenome-cpu.cwl tests/toy/jobs/toy_keep_bam_job.json
```

## Structural variants

`call_sv: true` genotypes the structural variants that are **already embedded in
the pangenome graph** and writes them as `<prefix>.sv.vcf.gz` (+`.tbi`) in the
same reference coordinates as the BAM and the gVCFs:

```bash
cwltool --no-container --parallel --outdir out/ Workflows/germline-pangenome-cpu.cwl \
  ... \
  --call_sv --snarls graph.snarls --sv_min_length 50
```

How it works: each `vg giraffe` block feeds its GAM stream to `vg pack` through
a FIFO, so the read support is built **without ever writing the GAM to disk**;
the per-block packs are summed with `vg pack -i` into one lane pack, the lane
packs are summed into one sample pack, and `vg call -z -c <sv_min_length>`
genotypes it against the GBZ. Summing packs is exact — the sample pack is
identical to one built from a single GAM holding every lane's alignments.

Notes and limits:

- **Only variation present in the graph is genotyped.** vg cannot discover novel
  SVs (its own documentation states that augmentation-based de novo calling does
  not work for SVs), so novel events still need a linear caller such as Manta or
  Delly run on `<prefix>.bam`.
- **`snarls` should be precomputed.** `vg snarls graph.gbz > graph.snarls` once
  per graph; without it `vg call` recomputes them on every run, which is
  expensive on a whole-genome graph.
- **Memory.** Every alignment block runs its own `vg pack` process, so peak
  memory grows with `align_chunks`; lower `align_chunks` when enabling
  `call_sv` on a large graph. `vg call` itself is run as a single process
  threaded with `-t`: scattering it per contig would make every job load the
  whole GBZ and snarls, multiplying memory by the contig count instead of
  dividing the work.
- **Contig names.** `vg call` writes plain contig names in the `CHROM` column but
  keeps the full PanSN path name in the `##contig` headers; the workflow strips
  `ref_path_prefix` from both so the VCF lines up with the BAM and the interval
  BEDs. The `##contig` block is also re-emitted in `ref_paths` order — i.e. the
  BAM `@SQ` order — because `bcftools sort` orders records by the header and
  tools that compare sequence dictionaries (GATK) reject a mismatched order.

A self-contained toy fixture lives in `tests/toy_sv/` (a 200 bp deletion, a
150 bp insertion and a 120 bp deletion, all heterozygous):

```bash
cwltool --no-container --outdir tests/toy_sv/demo_out \
  Workflows/germline-pangenome-cpu.cwl tests/toy_sv/jobs/toy_sv_job.json
```

## Parallelisation

Two workflow inputs speed up the two dominant steps of a whole-genome run
(verified on a 30x WGS: `vg giraffe` ~6h20m and autosome DeepVariant ~6h20m on
a 64-thread CPU box):

- `align_chunks` (int, default `1`): shard each lane's FASTQ pair into this many
  read-pair blocks and run `vg giraffe -> surject` **in parallel** (each block
  gets `ceil(threads/align_chunks)` threads), then concatenate the per-block BAMs
  with `samtools cat`. A block never splits a read pair, so **every read is
  aligned identically** to a single process; only the lane BAM record order
  changes (bamsormadup normalises it downstream). Total memory stays
  roughly constant while the per-process peak drops by `align_chunks`. Example
  `--align_chunks 8` gives ~4-6x speed-up of the mapping step on top of the
  per-lane scatter.

- `autosome_chunks_count` (int, default `0`): **the easy way to chunk the
  autosome.** The workflow derives the chunk BEDs itself from `autosome_interval`
  (no per-chunk files to prepare or list). `0` (or omitting it) keeps a single
  chunk over the whole autosome (the previous behaviour); `N>=2` groups
  contiguous contigs into ~`N` bp-balanced chunks, and an `N` at or above the
  number of contigs gives one chunk per contig. A contig is never split across
  chunks. Each chunk still gets `ceil(base_shards / #chunks)` DeepVariant shards
  (CPU: `threads`; GPU: `gpu_count`).

- `autosome_chunks` (BED `File[]`, default `[]`): optional **explicit** chunk
  override, used verbatim in the given order. Leave it unset to let
  `autosome_chunks_count` derive the chunks (recommended). The chunks are run
  **in parallel** and the per-chunk gVCFs are merged with `bcftools concat -a`.

  For **manual** chunks, adjacent regions must be chained in BED half-open
  coordinates: `chunk[i+1].start == chunk[i].end`, otherwise the boundary base
  is left uncalled (the automatic contig split above is always gap-free).

  A helper that writes one BED per contig is still available if you want files
  on disk, but it is no longer needed for normal runs:

  ```bash
  scripts/split-autosome-bed.sh autosome.bed autosome_chunks/   # -> list on stdout
  ```

### Result equivalence

Verified on the toy data (`align_chunks=2` and two manually halved autosome
chunks vs the default single-process run):

- the 2400 paired reads are aligned identically (per-record comparison after
  sorting);
- all variant (PASS, non-`<*>`) records are identical, and the set of called
  bases is the same;
- the number of **reference (REF) blocks** can differ: DeepVariant emits a
  reference block every time a candidate window ends, which depends on its
  internal shard partitioning of each region, so chunked runs may merge or split
  `<*>` blocks differently. Variant records and genotypes are unaffected.

## Release notes

- The toy job files use **paths relative to their own directory**
  (`tests/toy/jobs/`): run cwltool from anywhere in the checkout, e.g.
  `cwltool --no-container --outdir out/
  Workflows/germline-pangenome-cpu.cwl tests/toy/jobs/toy_job.json`.
- The pangenome graph + giraffe indexes for real (whole-genome) runs are large
  (~54 GB for the T2T-CHM13 backbone shown here) and are **not** bundled; build or
  download them (see *Preparing a graph*) and reference them in the job file.
- **Known issue / sanity check before production runs**: `vg` v1.70.0 aborts
  (SIGSEGV) on FASTQ reads whose base-quality length differs from the sequence
  length (a handful of reads with truncated quality exist in some production
  datasets, e.g. 1000 Genomes). A small streaming filter is provided:
  `tools/filter_fastq.py <fq1> <fq2> <out1> <out2>`. It drops both mates of any
  pair whose `seqlen != quallen` while keeping R1/R2 in lockstep — pipe the
  decoder output (or run it once over your FASTQs) before mapping.
- On Lustre-backed filesystems, staging the graph + indexes on node-local disk
  (`cp` to `/tmp`) avoids long per-read lock stalls when `vg` maps against them;
  the toy test data is tiny enough not to care.
