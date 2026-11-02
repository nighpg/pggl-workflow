# Files the workflow writes

This page lists every file a run leaves behind: the results, the work
directories of `scripts/submit-slurm.sh` and `scripts/run-cram-personalized.sh`,
and the intermediate files with when they are removed. Sizes are those of HG002
at 35x (one read group) mapped to a personalized combined graph.

## Results

A single-node `cwltool --outdir out/` run and a Slurm run (`<workdir>/out/`)
write the same files.

| File | Size (HG002 35x) | Content |
| --- | --- | --- |
| `<prefix>.bam` (+ `.bai`) | 46 GB | Reads surjected onto the linear reference (GRCh38 or T2T-CHM13 coordinates), sorted and duplicate-marked. Written unless `keep_bam: false` |
| `<prefix>.markdup.metrics` | 1 KB | Duplicate-marking statistics from bamsormadup, one row per library (Picard MarkDuplicates columns) |
| `<prefix>.autosome.g.vcf.gz` (+ `.tbi`) | 820 MB | DeepVariant gVCF of the autosomes, diploid |
| `<prefix>.PAR.g.vcf.gz` (+ `.tbi`) | 2 MB | The pseudo-autosomal regions, diploid. PAR is in chrX coordinates |
| `<prefix>.chrX_female.g.vcf.gz` (+ `.tbi`) | 165 MB | chrX outside PAR, diploid |
| `<prefix>.chrX_male.g.vcf.gz` (+ `.tbi`) | 165 MB | chrX outside PAR, haploid |
| `<prefix>.chrY.g.vcf.gz` (+ `.tbi`) | 29 MB | chrY outside PAR, haploid |
| `<prefix>.sv.vcf.gz` (+ `.tbi`) | 11 MB | Graph SVs (≥ `sv_min_length`, default 50 bp) genotyped by `vg call` on the autosomes and PAR, diploid. Written when `call_sv: true` |
| `<prefix>.sv.chrX_female.vcf.gz` (+ `.tbi`) | 1 MB | Graph SVs on chrX outside PAR, diploid |
| `<prefix>.sv.chrX_male.vcf.gz` (+ `.tbi`) | 1 MB | Graph SVs on chrX outside PAR, haploid |
| `<prefix>.sv.chrY.vcf.gz` (+ `.tbi`) | 0.2 MB | Graph SVs on chrY outside PAR, haploid |
| `<prefix>.sv*.nonrep.vcf.gz` (+ `.tbi`) | < 1 MB | The four SV files cut down to the simple DEL/INS the sample carries outside `sv_exclude_bed`. Written when `call_sv: true` and `sv_exclude_bed` is given |
| `<prefix>.<lane>.gam` | ~13 GB per lane at 30x | Each lane's alignments to the graph. Written when `emit_gam: true` |
| `<prefix>.pack` | ~3.6 GB | Read support over the whole graph, for rerunning `vg call` without remapping. Written when `keep_pack: true` |

**Sex chromosomes.** The sample's sex is not an input. The workflow therefore
writes chrX twice, as a female (diploid) and as a male (haploid) call, and
writes chrY as haploid. Pick the files that match the sample. PAR is called once,
diploid, in chrX coordinates. The same split applies to the SV files.

**SV VCFs.** Each record is a graph site (snarl). REF and ALT hold explicit
sequences, and the ID column names the site by its two boundary nodes in the
graph (e.g. `>1485483>1485542`).
- **INFO fields:** `AT` is the allele traversals through the graph. The workflow
  adds `SVTYPE` (DEL, INS, DUP or INV, recovered from the sequences), `SVLEN`
  (bases gained or lost) and `SVSIM` (the 31-mer similarity that `SVTYPE` rests
  on) to every ALT allele.
- **FORMAT fields:** `GT`, `AD`, `DP`, `GL`, `GQ` and others from `vg call`.
- **Sample name:** the `SM` of the read groups.

**`.nonrep` VCFs.** Multi-allelic records are split. A record is kept when all of
these hold:
- it passes the filters, and the sample carries the ALT allele;
- `QUAL ≥ sv_filter_min_qual` (default 30);
- it is a simple deletion or insertion: the shorter allele is at most
  `sv_filter_max_short_allele` bp (default 10), and the length change is at
  least `sv_min_length`;
- it does not overlap `sv_exclude_bed`.

The filter used is recorded in a `##pggl_sv_filter` header line.

## Work directory of `submit-slurm.sh`

```
<workdir>/
├── job.json                 the job file with every path made absolute
├── env.sh                   settings shared by the stage scripts
├── 1-prepare.sh  2-lane.sh  3-call.sh             stage scripts the Slurm jobs run
├── 3-markdup.sh  3-sv.sh  3-cleanup.sh  submit-call.sh   (split Parabricks stage 3)
├── jobs.tsv                 Slurm job IDs, one line per submitted job
├── logs/                    <stage>.<jobid>.out / .err; lane-<N>.<jobid>.* per lane
├── prepare.job.json  prepare.out.json             stage 1, for a CRAM/BAM input
├── prepare-out/             FASTQs decoded from the CRAM/BAM            [intermediate]
├── lanes/NNNN/
│   ├── job.json  job.local.json  out.json
│   └── out/<lane>.namecol.bam  <lane>.gam                                [intermediate]
├── call.job.json  markdup.job.json  sv.job.json  stage-3 jobs
├── out.json  out-markdup.json  out-sv.json      what each stage-3 job wrote
├── out/                     the results (table above)
└── tmp/  tmp-out/           cwltool scratch                              [intermediate]
```

- **Success markers:** `out.json`, `out-markdup.json` and `out-sv.json` are
  written only when the job succeeds, so they show how far stage 3 got.
- **Lane markers:** `lanes/NNNN/out.json` does the same for each lane.

## Work directory of `run-cram-personalized.sh`

```
<workdir>/
├── sample.cram.json         the sample's job (from examples/jobs/sample.cram.json)
├── prep.json                that job with the graph preset and the CRAM's reference
├── prep/                    a submit-slurm.sh work dir used for stage 1 only
│   ├── prepare.out.json     the lanes (FASTQ pair + @RG) decoded from the CRAM
│   └── prepare-out/         the decoded FASTQs (~270 GB)                [intermediate]
├── sample.fastq.json        the sample's job with those FASTQs as lanes
├── hs.json                  the Workflows/haplotype-sample.cwl job
├── pgraph/
│   ├── <prefix>.kff         KMC k-mer counts (~25 GB)                   [intermediate]
│   ├── <prefix>.personalized.gbz  .dist  .min  .zipcodes  .snarls
│   │                        the personalized graph and its indexes (~45 GB) [removed at the end]
│   └── out.json             written when the graph is complete
├── job.json                 the mapping and calling job (personalized graph)
├── 2-sample.sh  3-submit.sh the scripts of steps 2 and 3
├── jobs.tsv  logs/          job IDs and logs of steps 1-3
└── run/                     the submit-slurm.sh work dir of the mapping and calling
    └── out/                 the results
```

`run-cram-personalized.sh --status --workdir <workdir>` reads these files and
reports how far the run got and how to resume it.

## When intermediate files are removed

Every intermediate file is removed as soon as the jobs that read it have
succeeded. The final BAM and the other results are kept.

| File | Size (HG002 35x) | Removed |
| --- | --- | --- |
| `pgraph/<prefix>.kff` | ~25 GB | right after the sampling step |
| `prepare-out/`, `prep/prepare-out/` (decoded FASTQs) | ~270 GB | when stage 3 starts, once every lane is mapped |
| `lanes/*/out/*.namecol.bam` | ~78 GB | after duplicate marking succeeds |
| `lanes/*/out/*.gam` | ~160 GB | after the SV calls succeed |
| `pgraph/` (personalized graph) | ~45 GB | after stage 3 succeeds (`--keep-graph` keeps it) |
| `tmp/`, `tmp-out/` | small | after stage 3 succeeds |

- **Peak use:** a 35x sample peaks at about 600 GB. What remains at the end is
  `out/` (~47 GB with the BAM, ~1.2 GB without), the logs and the job files.
- **Keeping everything:** `--keep-intermediates` keeps every intermediate file.
  It is needed to rerun the calling stage after it has succeeded
  (`submit-slurm.sh --from call`).
- **Input FASTQs:** FASTQs that the job file lists as input are never removed.
