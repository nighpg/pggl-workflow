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
| `Workflows/germline-pangenome-pangenome-aware-cpu.cwl` | `vg giraffe` (CPU, same as above) | pangenome-aware DeepVariant (`google/deepvariant:pangenome_aware_deepvariant-1.10.0`) | Same inputs and outputs, but the caller also sees the graph's haplotypes (see *Pangenome-aware calling*). Needs its own image: the pangenome-aware one ships no plain `run_deepvariant`. **Only works on a graph whose reference is whole paths** — not JaSaPaGe's GRCh38 |
| `Workflows/haplotype-sample.cwl` | — | — | Preparation, not a germline run: builds a sample's personalized pangenome and its giraffe indexes for any of the above to then use (see *Haplotype sampling*) |

Every input lane is mapped with `vg giraffe` onto the pangenome. Two ways to
supply reads (can be combined, lanes are concatenated):

- **FASTQ track** (default): `fq1`/`fq2` + `rg` → `vg giraffe` alignment.
- **Aligned-reads track**: an aligned **CRAM** (linear/`ref` coordinates, `@SQ`
  matching `ref`) or **BAM** is name-collated back to read-pair FASTQ
  (`samtools collate` + `fastq`, its `@RG` header is carried over, orphans are
  dropped), then re-mapped onto the pangenome with `vg giraffe` exactly like a
  FASTQ lane. A CRAM is decoded against `ref`; a BAM carries its own sequences,
  so no decoding happens. `cram` and `bam` are separate inputs and giving both
  is an error rather than something resolved silently.

The pangenome graph + `giraffe` indexes (`gbz`, `dist`, `min`, `zipcodes`,
`ref_paths`) are required in BOTH modes.

## Inputs

For the three germline workflows. `Workflows/haplotype-sample.cwl` takes its
own, documented under *Haplotype sampling*.

| Parameter | Type | Description |
| --- | --- | --- |
| `fq1` / `fq2` | `File[]` | Read-pair FASTQs, one entry per read group (may be omitted; use `cram` instead) |
| `rg` | `string[]` | Full `@RG` string per read group, e.g. `@RG\tID:L1\tPL:ILLUMINA\tSM:SAMPLE` (literal `\t` or real tabs both work) |
| `cram` | `File` | Aligned CRAM in reference coordinates (`@SQ` matching `ref`); recovered to FASTQ and re-mapped onto the pangenome (its `@RG` is carried over). Mutually exclusive with `bam` |
| `bam` | `File` | Aligned BAM, handled exactly like `cram` but without reference decoding. Mutually exclusive with `cram` |
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
| `call_sv` | `boolean` | Genotype the SVs embedded in the pangenome graph (`vg pack` + `vg call`) and emit `<prefix>.sv.vcf.gz` plus the per-sex chrX/chrY files (default `false`) |
| `snarls` | `File` | Precomputed snarls for the graph (`vg snarls`); optional but strongly recommended for whole-genome graphs. Ignored when `call_sv` is false |
| `sv_min_length` | `int` | Minimum graph-site traversal length to be genotyped as an SV (`vg call -c`, default 50) |
| `ref_name_pangenome` | `string` | *Pangenome-aware workflow only.* PanSN sample name of the reference inside the GBZ (`GRCh38`, `CHM13v2`); must name the assembly the BAM is in |
| `sample_name_pangenome` | `string` | *Pangenome-aware workflow only.* Name for the haplotype panel taken from the GBZ; must differ from the reads' `SM` (default `pangenome`) |

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
<prefix>.sv.vcf.gz               (+ .tbi)  genotyped graph SVs, autosomes + PAR, diploid (only when call_sv=true)
<prefix>.sv.chrX_female.vcf.gz   (+ .tbi)  diploid   (chrX outside PAR)
<prefix>.sv.chrX_male.vcf.gz     (+ .tbi)  haploid   (chrX outside PAR)
<prefix>.sv.chrY.vcf.gz          (+ .tbi)  haploid
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

### Surjecting onto a reference the graph only holds in fragments

A Minigraph-Cactus graph clips its non-reference assemblies, so an assembly
that is *not* the backbone survives only as PanSN subranges. In JaSaPaGe the
GBWT `reference_samples` tag is `CHM13v2 GRCh38`, but GRCh38 is 165 fragments
(`GRCh38#0#chr1[585988]`) plus a whole `chrM`, against CHM13v2's 25 full-length
paths. A plain list of those fragment names is *not* usable as `ref_paths`: vg
drops them from the `@SQ` header and the reads come out unmapped.

Pass an **HTSlib sequence dictionary named in PanSN** instead. `vg` resolves
each fragment to its parent contig (`Output coordinates will be in
GRCh38#0#chr1 instead`) and takes the contig lengths from the header, so the
BAM gets the real GRCh38 lengths and, after `ref_path_prefix` stripping, lines
up with `interval_files/` and the linear FASTA:

```bash
awk 'BEGIN{OFS="\t"} $1 ~ /^chr([0-9]+|X|Y|M)$/ {print "@SQ","SN:GRCh38#0#"$1,"LN:"$2}' \
    GRCh38.fa.fai | cat <(echo -e "@HD\tVN:1.6\tSO:unsorted") - > GRCh38.pansn.dict
#  -> workflow inputs: ref_paths=GRCh38.pansn.dict  ref_path_prefix=GRCh38#0#
```

`prepare_pangenome_indexes.sh` cannot produce this: it keeps only full-length
paths, so on such a graph it picks the wrong sample (or stops with "only N
full-length paths"). Build the dictionary as above and run `vg autoindex`
directly.

This works for surjection, and therefore for the standard and GPU workflows.
It does **not** make the graph usable by pangenome-aware DeepVariant, which
resolves a contig to a single fragment instead of to the parent — see
*Pangenome-aware calling*.

**What is lost.** Only what is in the graph can be called. JaSaPaGe holds 92.4%
of GRCh38 by length but **97.6% of its non-N bases** — the ~70 Mb that was
clipped is centromeric/satellite sequence. Per contig the lowest non-N coverage
is chr21 89.8%, chrY 91.2%, chr18 93.2%, chr9 94.2%. The CHM13v2 backbone is
complete, so this is the price of staying in GRCh38 coordinates.

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
important for keeping several calling steps in flight, and without it a
real WGS run is dramatically slower. Because `--parallel` dispatches all ready
jobs at once, peak CPU is `--threads` × the number of concurrent jobs: size
`--threads` to the node's core count (e.g. 64 on a 64-core box) and raise
`align_chunks` only while the node has the memory (each block is a separate
process that reloads the whole graph, see *Parallelisation* below).

**But `--parallel` breaks once a sample has many lanes.** cwltool then hands
two scattered `giraffe` jobs the same temporary output directory, and the
second one dies staging its `InitialWorkDirRequirement` file:

```
FileExistsError: [Errno 17] File exists: '.../scripts/giraffe-sharded.sh'
                              -> '.../out_XXXXXXXX/giraffe-sharded.sh'
bash: giraffe-sharded.sh: No such file or directory
[job giraffe_2] exited with status: 127        -> permanentFail
```

It is a race in cwltool's own staging, not in the workflow, and `--parallel-max`
does not avoid it (that only throttles execution; the collision happens while
setting a job up). Two toy lanes never hit it; a 12-lane WGS sample hit it
within three minutes. **Get the parallelism from `align_chunks` instead**: it
forks inside a single `giraffe` job, so cwltool stays serial and the race
cannot occur. `align_chunks` × ~(gbz + dist + min + zipcodes) has to fit in
RAM — for the JaSaPaGe index set that is ~52 GB per block, so 2 blocks on a
251 GB node, with `ceil(threads/2)` each.

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
  --prefix SAMPLE --threads 64
```

**The inputs are exactly the CPU workflow's** — there is no GPU-count input,
because the workflow has no way to set one. `call_variants` picks up whatever
GPUs CUDA lets it see, so the number of GPUs is chosen outside CWL: Slurm's
`--gres=gpu:N`, apptainer's `--nv`, or `NVIDIA_VISIBLE_DEVICES=0,1`.

`--threads N` keeps its CPU meaning and also sets the DeepVariant shard count,
as in the CPU workflow. That is deliberate: it feeds `run_deepvariant
--num_shards`, and that flag is not about GPUs at all —

```
--num_shards: Optional. Number of shards for make_examples step.
```

— `make_examples` is CPU-only and dominates DeepVariant's runtime on a WGS
sample, while only `call_variants` uses the GPU. Sharding it by a GPU count
would starve the expensive stage to speed up the cheap one; Google's own
CPU-vs-GPU comparison shows the shape of it, `call_variants` 2m1s → 1m52s while
`make_examples` stayed at ~2 hours.

**So temper expectations.** With the official GPU image only `call_variants`
moves to the GPU, so the gain is bounded by how little of the runtime that
stage was. Moving `make_examples` and `postprocess_variants` to the GPU as well
is what NVIDIA Parabricks does, and is a different tool, not a flag.

**Forgetting `--nv` does not fail.** Without GPU passthrough DeepVariant just
reports `Could not find cuda drivers on your machine, GPU will not be used` and
runs to completion on the CPU — correct, and quietly not what was asked for.
Check the log, or have the submitting script refuse to start a GPU workflow
without an allocated GPU.

`--parallel` in the example above is subject to the same staging race described
under *Running*: fine for a couple of lanes, not for a sample with many.

## Self-contained SIF (no-setup on any host)

`./sif-build.def` produces a single image containing DeepVariant, samtools/bcftools,
`vg`, `node`, `cwltool`, biobambam2 (`bamsormadup`), `kmc` (for
`Workflows/haplotype-sample.cwl`) and the workflow/tool/script tree under
`/opt/pangenome`.
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
the base image). On a shared host where you are not root and have no
`/etc/subuid` entry, build unprivileged with
`apptainer build --fakeroot --ignore-fakeroot-command ...`: apptainer then maps
your uid to root in a user namespace, which is all `%post` needs here (the
`--ignore-fakeroot-command` is required because the injected `faked` helper is
not usable in that mapping).
Before building, run `./scripts/stage-sif-assets.sh` once:
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

### Pangenome-aware SIF

`./sif-build-pangenome-aware.def` is the image for
`Workflows/germline-pangenome-pangenome-aware-cpu.cwl`. It is a separate image,
not an option on the CPU one, because
`google/deepvariant:pangenome_aware_deepvariant-1.10.0` ships no plain
`run_deepvariant` at all — the two callers cannot live in one `--no-container`
run. Everything else (vg, samtools/bcftools, biobambam2, kmc, node, cwltool,
the workflow tree) is staged exactly as for the CPU image, so
`./scripts/stage-sif-assets.sh` covers all three.

```bash
apptainer build [--fakeroot --ignore-fakeroot-command] \
    deepvariant-pangenome-aware-cpu-vg.sif sif-build-pangenome-aware.def

apptainer exec deepvariant-pangenome-aware-cpu-vg.sif \
  /opt/pangenome/run-pangenome-aware.sh --ref_name_pangenome GRCh38 ... --outdir out/
```

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

# 3) BAM track: same path, no reference decoding. There is no BAM fixture --
#    make one from the CRAM and swap `cram` for `bam` in the job file:
#      samtools view -b -T tests/toy/ref.fa -o toy_in.bam tests/toy/toy_in.cram
#    It reproduces the CRAM track exactly: identical alignments, identical
#    markdup metrics and identical gVCFs.
```

Each run produces `<prefix>.bam` (+`.bai`), `<prefix>.markdup.metrics` and five
gVCFs (`autosome`, `PAR`, `chrX_female`, `chrX_male`, `chrY`, +`.tbi`). The two
job files cover the FASTQ and CRAM tracks; swap the workflow path for
`Workflows/germline-pangenome-gpu.cwl` to smoke-test the GPU variant on the same
toy inputs.

A third job file runs the same toy inputs through the pangenome-aware caller
(see *Pangenome-aware calling*); it needs the image built from
`sif-build-pangenome-aware.def`, not the one above:

```bash
cwltool --no-container --outdir tests/toy/demo_out/pangenome_aware \
  Workflows/germline-pangenome-pangenome-aware-cpu.cwl \
  tests/toy/jobs/toy_pangenome_aware_job.json
```

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

## Haplotype sampling (personalized pangenome)

Variants that the sample does not carry can mislead the mapper, so `vg` can cut
the graph down to the haplotypes that match the sample's k-mers (Sirén et al.,
*Personalized pangenome references*). Nothing in the workflow changes: build the
personalized graph and its indexes first, then point `gbz`/`dist`/`min`/
`zipcodes` at them. The CRAM track keeps working, because the workflow never
asks how the graph was made.

**Once per graph** (reusable for every sample):

```bash
vg autoindex -p g -G graph.gbz -w giraffe -t N -T "$TMPDIR"   # .dist/.min/.zipcodes
vg gbwt -Z graph.gbz -r g.ri -p --num-threads N               # r-index
vg haplotypes -d g.dist -r g.ri -H g.hapl -t N graph.gbz      # haplotype info
```

A `.hapl` shipped with a graph is often unusable: the format is versioned and
vg 1.70 rejects version 4 with `Expected version 5 to 5, got version 4`. The vg
wiki also says to rebuild anything made before v1.64.0. Regenerating it is
cheap next to the distance index (see the timings below).

**Per sample**, `Workflows/haplotype-sample.cwl` does the three steps (KMC →
`vg haplotypes` → `vg autoindex`, plus `vg snarls` when `make_snarls` is set):

```bash
cwltool --no-container --outdir sample_graph/ Workflows/haplotype-sample.cwl \
  --fq1 L1_R1.fastq --fq2 L1_R2.fastq --fq1 L2_R1.fastq --fq2 L2_R2.fastq \
  --gbz graph.gbz --hapl g.hapl --ref_sample GRCh38 --prefix SAMPLE --threads 32

# then any germline workflow, with only the graph inputs moved:
cwltool --no-container --outdir out/ Workflows/germline-pangenome-cpu.cwl \
  --gbz sample_graph/SAMPLE.personalized.gbz \
  --dist sample_graph/SAMPLE.personalized.dist \
  --min  sample_graph/SAMPLE.personalized.min \
  --zipcodes sample_graph/SAMPLE.personalized.zipcodes \
  --ref_paths ... --ref ... --ref_path_prefix 'GRCh38#0#' ...   # unchanged
```

It is deliberately a separate workflow rather than a step inside the germline
one: the personalized graph belongs to the *sample*, so the same one serves the
standard and the pangenome-aware caller and every re-run, instead of being
rebuilt each time (about an hour for a 38x genome). It takes FASTQ — KMC cannot
read CRAM either way — and `ref_paths`, `ref` and `ref_path_prefix` are
untouched by sampling, so they carry over verbatim.

- **`--include-reference` / `--set-reference <assembly>` are mandatory here.**
  Without them the reference paths are dropped from the sampled graph, there is
  nothing left to surject onto and the linear-reference contract collapses.
  With them the reference survives intact, fragments and all — verified by
  surjecting a test read onto a sampled JaSaPaGe and getting the expected
  GRCh38 contig, length and position.
- **KMC cannot read CRAM** (`wrong EOF marker of BAM file`; it does not use
  htslib). It reads BAM with `-fbam`, or FASTQ. Read groups are irrelevant to
  k-mer counting, so all lanes are counted as one sample.
- `--diploid-sampling` is the vg wiki's recommendation, and it wants ≥20x
  coverage to tell heterozygous from homozygous k-mers.
- **`call_sv` changes meaning** (see *Structural variants*): only the sampled
  haplotypes' SVs are left to genotype, and the graph's own `.snarls` no longer
  describes the sampled graph, so it has to be recomputed per sample. Set
  `make_snarls: true` on this workflow and pass its `snarls` output to the
  germline run; reusing the full graph's file silently genotypes against sites
  that sampling removed.

Measured on JaSaPaGe (3.3 GB GBZ, 68 samples, 52,645 paths) and a 38x sample,
on 32 allocated CPUs (the node exposes 16 physical cores to vg):

| Step | Wall | Peak RSS | Output |
| --- | --- | --- | --- |
| `vg autoindex -w giraffe` | 4 h 19 m | 89.6 GB | `.dist` 7.6 GB, `.min` 38 GB, `.zipcodes` 2.6 GB |
| `vg gbwt -r` | **1 m 31 s** | 26.6 GB | `.ri` 5.4 GB |
| `vg haplotypes -H` | **40 m 41 s** | 46.4 GB | `.hapl` 5.4 GB |
| `kmc -k29` (767 M reads) | 27 m 56 s | 60.4 GB | `.kff` 23 GB |
| `vg haplotypes -i -k -g` | **7 m 27 s** | 33.9 GB | personalized GBZ 2.4 GB, 538 paths |

So enabling sampling on an already-indexed graph costs ~42 minutes once, and
~35 minutes per sample before the personalized graph still has to be indexed.

## Pangenome-aware calling

`Workflows/germline-pangenome-pangenome-aware-cpu.cwl` swaps the five
DeepVariant steps for `run_pangenome_aware_deepvariant`: `make_examples` draws
the pileup image of the reads *and* of the graph's haplotypes at each candidate
site, and a model trained on that pair infers the genotype. Google reports up
to 25.5% fewer errors than linear-reference DeepVariant.

**Mapping is untouched.** The caller takes an aligned BAM; it does not re-map.
It reads only the `gbz` the aligner already used -- no `.dist`/`.min`/
`.zipcodes` -- so the workflow passes its own `gbz` input straight through and
everything up to and including `bamsormadup` is byte-identical to the CPU
workflow. `call_sv` is unaffected: `vg pack`/`vg call` never involved
DeepVariant.

Two inputs are added, and both matter:

| Input | Default | Notes |
| --- | --- | --- |
| `ref_name_pangenome` | `GRCh38` | PanSN sample name of the reference **inside the GBZ** — the assembly the BAM is in (`CHM13v2` for a JaSaPaGe run surjected onto CHM13) |
| `sample_name_pangenome` | `pangenome` | Name recorded for the haplotype panel; **must differ from the reads' `SM`** |

Three limits found while wiring this up. The first is the one that decides
whether a given graph can be used at all.

- **The reference must be whole paths, not subranges.** This is stricter than
  the `reference_samples` tag, and it is what rules JaSaPaGe out for GRCh38:
  that graph tags both `CHM13v2` and `GRCh38` as reference samples, but only
  CHM13v2 is stored as 25 full-length paths. GRCh38 survives as 165 subranges
  (`GRCh38#0#chrX[222346]`), and `make_examples` then dies on the first
  candidate outside the first fragment of a contig:

  ```
  F0000 subgraph.cpp:165] Subgraph::Subgraph():
        Path GRCh38#0#chrX[222346] does not contain offset 2801979
  ```

  The tool resolves a contig to *one* fragment — the first — rather than to the
  parent contig, which `vg surject` does do (`Output coordinates will be in
  GRCh38#0#chr1 instead`). Measured on JaSaPaGe: `chr1:1,000,000-1,010,000`,
  inside the first fragment `[585988]`, calls fine; `chr1:3,000,000-3,010,000`,
  inside `[2755518]`, aborts against `[585988]`. **Restricting `--regions` to
  where the reference exists therefore does not help** — only each contig's
  first fragment is reachable, 2.1 Mb of chr1 and 16 kb of chrX.

  Check before running rather than after six hours of alignment:

  ```bash
  vg paths -x graph.gbz -L | grep '^GRCh38#' | grep -vc '\['   # full-length paths
  vg gbwt --tags -Z graph.gbz | grep reference_samples
  ```

  The first number must be the contig count you expect (25 for a human graph),
  with no `[...]` paths for that sample. On JaSaPaGe it is 1 — `chrM` alone.

  To *build* a graph that qualifies, the assembly has to be the **first**
  `--reference` given to `cactus-pangenome`. Minigraph-Cactus protects only
  that one: it is "never clipped, never self-aligned", while later `--reference`
  samples are "clipped as usual, but end up as 'reference-sense' paths". So
  `--reference CHM13v2 GRCh38` yields exactly what JaSaPaGe has — GRCh38 tagged
  as a reference and fragmented anyway. Only one assembly can be whole per
  graph, which is why HPRC ships a GRCh38 graph and a CHM13 graph separately.

- **The graph must carry its reference as a named sample.** A GBZ whose
  reference paths are plain contig names (`chr20`) has nothing to put in
  `ref_name_pangenome` and the caller stops with `Pangenome path ids not found
  for pangenome sample name`; naming a haplotype sample instead aborts inside
  `Subgraph::Subgraph()` too. `tests/toy_sv/` is such a graph, so it has no
  pangenome-aware reference output; `tests/toy/` (`GRCh38#0#…`, whole) is fine.
- **The GBZ is loaded into `/dev/shm`**, shared by the `make_examples` shards.
  The region name is global and this workflow calls five (or more, once the
  autosome is chunked) regions at once under `--parallel`, so the tool derives
  the name from the per-step output prefix. Size `/dev/shm` for the graph times
  the number of concurrent steps.

```bash
./scripts/stage-sif-assets.sh
apptainer build [--fakeroot --ignore-fakeroot-command] \
    deepvariant-pangenome-aware-cpu-vg.sif sif-build-pangenome-aware.def

cwltool --no-container --parallel --outdir tests/toy/demo_out/pangenome_aware \
  Workflows/germline-pangenome-pangenome-aware-cpu.cwl \
  tests/toy/jobs/toy_pangenome_aware_job.json
```

Against the standard caller on `tests/toy` (`demo_out/pangenome_aware/` vs
`demo_out/opt_default/`): the BAM and the markdup metrics are identical, all
five gVCFs have the same record and variant counts, and the genotypes agree
everywhere except the haploid male chrX track, where the two callers disagree
on both sites (`./.`, `1/1` vs `0/0`, `./.`) from identical AD/DP/VAF. The
outputs are therefore *not* interchangeable with the standard track, which is
why they are kept side by side rather than replacing it.

## Structural variants

`call_sv: true` genotypes the structural variants that are **already embedded in
the pangenome graph** and writes them as `<prefix>.sv.vcf.gz` (+`.tbi`) in the
same reference coordinates as the BAM and the gVCFs:

```bash
cwltool --no-container --parallel --outdir out/ Workflows/germline-pangenome-cpu.cwl \
  ... \
  --call_sv --snarls graph.snarls --sv_min_length 50
```

How it works: each `vg giraffe` block keeps its GAM, the blocks of a lane are
concatenated into one lane GAM, every lane's GAM is concatenated in turn, and a
single `vg pack` pass over that builds the sample's read support, which
`vg call -z -c <sv_min_length>` then genotypes against the GBZ.

**Ploidy and the sex chromosomes.** `vg call` has one ploidy for the whole run,
so a single pass cannot be right for both the autosomes and a male chrX. The
same pack is therefore called twice — once at the default ploidy 2, once with
`-d 1` — and each region is taken from the pass with the right ploidy for it:

| File | Region | Ploidy | From |
| --- | --- | --- | --- |
| `<prefix>.sv.vcf.gz` | autosomes + PAR | diploid | pass 1 |
| `<prefix>.sv.chrX_female.vcf.gz` | chrX outside PAR | diploid | pass 1 |
| `<prefix>.sv.chrX_male.vcf.gz` | chrX outside PAR | haploid | pass 2 |
| `<prefix>.sv.chrY.vcf.gz` | chrY outside PAR | haploid | pass 2 |

Both sexes are emitted and neither is chosen, exactly as the gVCFs are: the
sample's sex is not a workflow input. This matters — on NA18945, whose chrX
read depth is exactly half the autosomal one (median DP 10 against 20), a
single diploid pass called **47.6% of chrX SVs heterozygous**, which a haploid
chromosome cannot be. The regions come from `PAR_interval`, `chrX_interval` and
`chrY_interval`, the same BEDs DeepVariant is given; leave all three out and
the step falls back to one whole-genome diploid file. The contig names are read
from the BEDs rather than assumed, so a differently named reference still
works.

The haploid pass uses `-d 1` rather than `-R <contig>:1`. `-R` assigns ploidy
per contig by regex and could do both in one pass, but on a graph whose
reference is stored as PanSN subranges the name it matches against is the
fragment (`GRCh38#0#chrX[2781479]`), and whether the regex sees that or the
resolved parent is not documented. `-d 1` makes the whole pass haploid, which
is wrong for the autosomes — but nothing is taken from the autosomes of that
pass. The cost is one more `vg call`: measured at 22 minutes on JaSaPaGe
against a 12 h 43 m whole run, so about +3%. The pack is ploidy-independent and
is reused, not rebuilt.

**Inversions and duplications are called, but not labelled.** `vg call` writes
REF and ALT as explicit sequences and never emits a symbolic `<INV>` or
`<DUP>`, so the kind of event a record describes is present in the sequences
but carries no name. When `ref` is given, the step recovers it and writes
`SVTYPE`, `SVLEN` and `SVSIM` (all `Number=A`, so a multi-allelic site gets one
value per ALT):

| `SVTYPE` | Recovered from |
| --- | --- |
| `INV` | the ALT matches the reverse complement of the REF and not the REF |
| `DUP` | the inserted sequence is a copy of the reference beside it |
| `INS` | the inserted sequence is unrelated to its flanks |
| `DEL` | the ALT is shorter than the REF by at least `sv_min_length` |

`SVSIM` carries the 31-mer similarity the call rests on, so a threshold can be
tightened afterwards without recomputing anything. Measured on NA18945 (57,531
records, whole genome, 27 s):

| `SVTYPE` | Called alleles | Median `GQ` | `GQ` ≥ 10 |
| --- | ---: | ---: | ---: |
| `DEL` | 16,673 | 10 | 50% |
| `INS` | 12,542 | 0 | 28% |
| `DUP` | 2,633 | 9 | 47% |
| `INV` | 21 | 0 | 5% |
| `.` (under `sv_min_length`) | 42,010 | 1 | 28% |

**Filtering on length alone loses the inversions.** An inversion barely changes
length — on NA18945 the median length difference of one was 3 bp, and 86% were
under 50 bp — so `|ALT-REF| >= 50` throws away a 6 kb event as if it were a
3 bp indel. That is why the inversions above sit in the `.` bucket by length
and can only be found through `SVTYPE`. Their genotypes are the least reliable
of any class (median `GQ` 0): inversions sit in segmental duplications and
palindromes, where short reads cannot anchor either breakpoint uniquely, so
treat `INV` as a location to follow up rather than a genotype to use.

Notes and limits:

- **`sv_min_length` filters snarls, not alleles.** `vg call -c N` genotypes
  every snarl that has *a traversal* of at least N bases; the alleles it then
  reports for that snarl can be much smaller. On NA18945 only 28,927 of the
  57,531 records had a called allele of 50 bp or more — the rest are small
  variants sitting inside a snarl that also holds a large one. Filter on the
  allele length if SVs are what is wanted.
- **Only variation present in the graph is genotyped.** vg cannot discover novel
  SVs (its own documentation states that augmentation-based de novo calling does
  not work for SVs), so novel events still need a linear caller such as Manta or
  Delly run on `<prefix>.bam`.
- **`snarls` should be precomputed.** `vg snarls graph.gbz > graph.snarls` once
  per graph; without it `vg call` recomputes them on every run, which is
  expensive on a whole-genome graph. They belong to *that* graph: running
  against a personalized graph needs its own, which
  `Workflows/haplotype-sample.cwl` produces with `make_snarls: true` (see
  *Haplotype sampling*).
- **Packing is one pass over the concatenated GAM, not a sum of packs.**
  `vg pack -i`, which sums coverage packs, segfaults in
  `vg::Packer::collect_coverage` on a whole-genome graph — reproduced on
  JaSaPaGe with two packs, with `-Q` and without it, and at one thread as well
  as 32, so it is neither a race nor a quality-vector mismatch. GAM is a
  concatenable stream, so the lanes are joined with `cat` and packed once,
  which is the definition the sum was approximating. Verified equivalent on the
  toy graph, where `vg pack -i` does work: the two routes give byte-different
  packs whose coverage tables are identical.
- **`vg pack` cannot read a FIFO**, which is why the GAM is on disk at all. It
  opens its `-g` argument at startup, closes it again within a second, and only
  reopens it after loading the GBZ — ten minutes later on a whole-genome graph.
  Streaming giraffe into it deadlocks as soon as the graph is big enough:
  measured on JaSaPaGe, the transient open released `tee`, `tee`'s first write
  found no reader and died of `SIGPIPE`, `vg giraffe` followed it down the pipe
  two minutes in, and `vg pack` was still blocked in `open()` thirteen minutes
  later with a zero-byte pack. A toy graph loads instantly, so the fixtures
  never showed either of these.
- **Disk.** Every lane's GAM has to survive until the sample pack is built —
  about 13 GB per lane at 30x, so ~156 GB for a 12-lane sample — and the
  concatenated copy doubles that at the moment of packing. Both are removed
  once the pack exists (the lane GAMs are kept only if `emit_gam` asked for
  them).
- **Memory.** Nothing is packed alongside `vg giraffe` any more, so an
  alignment block peaks at giraffe alone (~70 GB on JaSaPaGe) and
  `align_chunks` multiplies that; the single packing pass peaks at about the
  same figure on its own. `vg call` is likewise run as one process threaded
  with `-t`: scattering it per contig would make every job load the whole GBZ
  and snarls, multiplying memory by the contig count instead of dividing the
  work.
- **Contig names.** `vg call` writes plain contig names in the `CHROM` column but
  keeps the full PanSN path name in the `##contig` headers; the workflow strips
  `ref_path_prefix` from both so the VCF lines up with the BAM and the interval
  BEDs. The `##contig` block is also re-emitted in `ref_paths` order — i.e. the
  BAM `@SQ` order — because `bcftools sort` orders records by the header and
  tools that compare sequence dictionaries (GATK) reject a mismatched order.
  `ref_paths` may be either a plain path list or an HTSlib `.dict`; both are
  read here, and subrange entries (`chr1[585988]`) are folded onto the parent
  contig the VCF names.
- **Contig lengths are taken from `ref_paths`, not from vg.** On a graph whose
  reference is stored as subranges, the `length=` vg puts in each `##contig` is
  the end of that contig's *last* fragment, so the clipped tail is missing --
  measured against JaSaPaGe/GRCh38, 24 of 25 contigs came out short, by 10 kb
  (chr1) to 83 kb (chr9). A VCF whose `##contig` lengths disagree with the
  reference is rejected outright by anything that compares sequence
  dictionaries, so when `ref_paths` is a `.dict` its `LN:` values are written
  back over vg's. With a plain path list there is nothing to correct from and
  vg's lengths are kept as-is, which is one more reason to pass the `.dict`.
- **Subranges are resolved, unlike in pangenome-aware DeepVariant.** `vg call`
  reports a fragmented reference against its parent contigs, the same way
  `vg surject` does, so the `call_sv` track works on GRCh38-on-JaSaPaGe even
  though pangenome-aware DeepVariant does not (see *Pangenome-aware calling*).
  Verified on JaSaPaGe with `-S GRCh38`: 25 `##contig` lines, no fragment
  names anywhere, `CHROM` = `chr1`. The subpath guard above is a safety net for
  graphs that behave otherwise, not an expected outcome.
- **Multi-reference graphs.** `vg call` genotypes *every* reference assembly in
  the graph by default (the default for `-p` is "all"), so a graph carrying more
  than one — e.g. JaSaPaGe, whose GBWT `reference_samples` tag is
  `CHM13v2 GRCh38` — would produce a VCF mixing the contigs of both and no
  longer matching the BAM. The workflow therefore passes `vg call -S <sample>`,
  taking the sample from `ref_path_prefix` (`GRCh38#0#` → `GRCh38`). An empty
  `ref_path_prefix` means plain contig names, i.e. a single-reference graph,
  where the default is already right and no `-S` is added.
  Should a subpath contig nevertheless reach the VCF, the run fails rather than
  emit fragment-relative positions that silently disagree with the BAM.

A self-contained toy fixture lives in `tests/toy_sv/` (a 200 bp deletion, a
150 bp insertion and a 120 bp deletion, all heterozygous):

```bash
cwltool --no-container --outdir tests/toy_sv/demo_out \
  Workflows/germline-pangenome-cpu.cwl tests/toy_sv/jobs/toy_sv_job.json

# same fixture, but ref_paths given as an HTSlib .dict instead of a path list
cwltool --no-container --outdir tests/toy_sv/demo_out \
  Workflows/germline-pangenome-cpu.cwl tests/toy_sv/jobs/toy_sv_dict_job.json
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

  **Memory is the binding constraint, and it is per block.** Every block holds
  the whole index set resident: for JaSaPaGe that is ~52 GB (`min` 38 GB +
  `dist` 7.6 GB + `gbz` 3.3 GB + `zipcodes` 2.6 GB), so a 251 GB node takes 2
  blocks with headroom, not 8. Since `--parallel` is unusable on a many-lane
  sample (see *Running*), `align_chunks` is also where all the mapping
  parallelism has to come from: `align_chunks=2` with `threads` set to the core
  count gives each block `ceil(threads/2)` and keeps the node busy while
  cwltool runs one lane at a time.

- `autosome_chunks_count` (int, default `0`): **the easy way to chunk the
  autosome.** The workflow derives the chunk BEDs itself from `autosome_interval`
  (no per-chunk files to prepare or list). `0` (or omitting it) keeps a single
  chunk over the whole autosome (the previous behaviour); `N>=2` groups
  contiguous contigs into ~`N` bp-balanced chunks, and an `N` at or above the
  number of contigs gives one chunk per contig. A contig is never split across
  chunks. Each chunk still gets `ceil(base_shards / #chunks)` DeepVariant shards
  (`threads`, in both the CPU and the GPU workflow).

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
- **Scratch space is the quiet requirement.** A 38x sample decodes to ~285 GB of
  FASTQ, KMC's KFF is another 23 GB, and cwltool stages inputs per job. Cluster
  nodes routinely have a small node-local `/tmp` (23 GB on the box this was run
  on), so point `--tmpdir-prefix` / `--tmp-outdir-prefix`, `TMPDIR` and
  `vg autoindex -T` at shared storage rather than letting them default.
- **Memory is per giraffe process, not per run.** Each one holds the whole index
  set resident — ~52 GB for the JaSaPaGe set (`min` 38 GB + `dist` 7.6 GB +
  `gbz` 3.3 GB + `zipcodes` 2.6 GB). `align_chunks` multiplies that, and so does
  any scheduler-level parallelism, so size both against the node rather than
  against the core count.
- **Read groups survive a CRAM/BAM only if you split it first.** The
  aligned-reads track collapses the input to one lane and stamps the first `@RG`
  on every read, because `samtools fastq` does not carry read groups. To keep a
  sample's original lanes — and per-lane duplicate marking with them — split by
  read group first (`samtools split -f '%!.cram'`) and pass the pieces as FASTQ
  lanes with their own `@RG` strings.
