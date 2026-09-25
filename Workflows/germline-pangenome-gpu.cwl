#!/usr/bin/env cwl-runner
# GPU variant: identical to germline-pangenome-cpu.cwl, inputs included, except
# that the five DeepVariant steps use the GPU image
# (google/deepvariant:1.10.0-gpu). Only call_variants runs on the GPU, and it
# picks the GPUs up from CUDA visibility by itself -- there is no input for the
# GPU count because the workflow has no way to set it. make_examples, which
# dominates the runtime, is CPU-only and is sharded by `threads` exactly as in
# the CPU workflow.
# vg giraffe + samtools stay on CPU. Requires a CUDA driver (e.g. V100S) on the
# host and the container started with GPU passthrough:
#   singularity exec --nv deepvariant-opencode-cpu-vg-gpu.sif \
#     /opt/pangenome/run-pangenome.sh Workflows/germline-pangenome-gpu.cwl ...

class: Workflow
id: germline-pangenome-gpu
label: germline-pangenome-gpu
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  ScatterFeatureRequirement: {}
  StepInputExpressionRequirement: {}
  SubworkflowFeatureRequirement: {}

inputs:
  fq1:
    type: File[]?
    doc: FASTQ file 1. This option can be used multiple times. Omit when cram is provided.
    default: []

  fq2:
    type: File[]?
    doc: FASTQ file 2. This option can be used multiple times. Omit when cram is provided.
    default: []

  rg:
    type: string[]?
    doc: Read group string. This option can be used multiple times. Omit when cram is provided.
    default: []

  cram:
    type: File?
    doc: Coordinate-sorted aligned CRAM in reference coordinates with @SQ matching ref; reads are recovered to FASTQ (decoded with ref) and re-mapped onto the pangenome with vg giraffe, exactly like a FASTQ lane. Every @RG of its header becomes its own lane with that @RG, so per-library duplicate marking is kept. Mutually exclusive with bam.
    secondaryFiles:
      - { pattern: ".crai", required: false }

  bam:
    type: File?
    doc: Coordinate-sorted aligned BAM, handled exactly like cram except that no reference decoding is needed. Mutually exclusive with cram.
    secondaryFiles:
      - { pattern: ".bai", required: false }

  gbz:
    type: File
    doc: GBZ pangenome graph

  dist:
    type: File
    doc: giraffe distance index (.dist)

  min:
    type: File
    doc: giraffe minimizer index (.min)

  zipcodes:
    type: File
    doc: giraffe zipcode index (.zipcodes)

  ref_paths:
    type: File
    doc: Ordered reference paths of the graph, either one path name per line or an HTSlib sequence dictionary (.dict); drives giraffe @SQ and surjection. The dictionary form is required when the reference is stored as PanSN subranges (chr1[585988]), because the contig names and lengths then come from the header instead of from the split paths.

  ref:
    type: File
    doc: Linear reference FASTA used to decode the CRAM and for variant calling; contig sequences must match the graph reference paths (or the CRAM @SQ)
    secondaryFiles:
      - ^.dict
      - .fai

  ref_path_prefix:
    type: string
    doc: Reference path prefix (PanSN <sample>#<haplotype>#) to strip from @SQ contig names; empty means no strip
    default: "GRCh38#0#"

  autosome_interval:
    type: File
    doc: Interval BED file for autosome regions

  autosome_chunks:
    type:
      - type: array
        items: File
      - "null"
    doc: Optional explicit list of BED files partitioning the autosome. Leave unset to derive the chunks automatically (see autosome_chunks_count); when set, these are used verbatim, in this order.
    default: []

  autosome_chunks_count:
    type: int?
    doc: Convenience knob for automatic autosome chunking. Omit or 0 = a single chunk over the whole autosome (the previous default); N>=2 groups contiguous contigs into ~N bp-balanced chunks (a contig is never split); if N >= the number of contigs, one chunk per contig. Ignored when autosome_chunks is set. DeepVariant still shards each chunk internally via base_shards. Non-HS37 DNA sites that fall in no chunk are dropped.
    default: 0

  PAR_interval:
    type: File
    doc: Interval BED file for PAR regions

  chrX_interval:
    type: File
    doc: Interval BED file for chrX regions (excluding PAR)

  chrY_interval:
    type: File
    doc: Interval BED file for chrY regions

  prefix:
    type: string
    doc: Output file prefix

  threads:
    type: int
    doc: CPU threads for vg giraffe, samtools and the DeepVariant shards. How many GPUs the run uses is not set here -- it is whatever CUDA is allowed to see (apptainer --nv, NVIDIA_VISIBLE_DEVICES, Slurm --gres).
    default: 32

  emit_gam:
    type: boolean
    doc: Keep the per-lane graph-space alignments (lane.gam) as workflow outputs. Adds a GAM write per lane; off by default.
    default: false

  keep_bam:
    type: boolean
    doc: Keep the final duplicate-marked BAM (prefix.bam / .bai) as a workflow output. The BAM is always produced internally because DeepVariant requires BAM; set false to avoid materialising it in the output directory (e.g. to save disk).
    default: true

  align_chunks:
    type: int
    doc: Number of parallel vg giraffe processes per lane. The lane FASTQ pair is sharded into this many read-pair blocks (pairs never split), mapped in parallel with threads/chunks threads each, and the per-block BAMs are concatenated with samtools cat. Each block is its own giraffe process holding the whole index set (~77 GB for JaSaPaGe, so memory grows with the block count); all blocks use block 1's fragment-length estimate, so results are the same as one process, and blocks 2..N start only after block 1 has loaded and estimated. Set 1 for the original single-process behaviour.
    default: 1

  call_sv:
    type: boolean
    doc: Genotype the structural variants that are embedded in the pangenome graph (vg pack + vg call) and emit <prefix>.sv.vcf.gz. This only genotypes variation present in the graph; vg cannot discover novel SVs, so novel events still need a linear caller on <prefix>.bam. Off by default because it keeps every lane's GAM on disk until the sample-wide pack is built, tens of GB per lane at whole-genome depth.
    default: false

  snarls:
    type: File?
    doc: Precomputed snarls for the graph (vg snarls). Optional, but on whole-genome graphs recomputing them inside every run is expensive, so generate them once alongside the giraffe indexes. Ignored when call_sv is false.

  keep_pack:
    type: boolean?
    doc: Materialise the sample-wide vg pack (<prefix>.pack) in the output directory (default false). It is built whenever call_sv is set because vg call needs it; keeping it lets vg call be re-run -- at another ploidy, against another reference sample, with other thresholds -- without re-mapping the sample. About 3.6 GB for a 30x sample against JaSaPaGe, against roughly 9 hours of mapping to rebuild.
    default: false

  sv_min_length:
    type: int
    doc: Minimum traversal length for a graph site to be genotyped as an SV (vg call -c). 50 matches the usual SV definition; lower it to also emit smaller graph variants.
    default: 50

steps:
  # 1. Reads -> lanes (FASTQ pairs pass through; a CRAM/BAM is split by @RG).
  prepare:
    run: parts/prepare-lanes.cwl
    in:
      fq1: fq1
      fq2: fq2
      rg: rg
      cram: cram
      bam: bam
      ref: ref
      prefix: prefix
      threads: threads
    out: [fq1, fq2, rg, lane, sample_name]

  # 2. Every lane onto the pangenome (scripts/submit-slurm.sh runs these as
  #    one Slurm array task per lane instead).
  align:
    run: parts/lane-align.cwl
    in:
      fq1: prepare/fq1
      fq2: prepare/fq2
      rg: prepare/rg
      lane: prepare/lane
      gbz: gbz
      dist: dist
      min: min
      zipcodes: zipcodes
      ref_paths: ref_paths
      ref_path_prefix: ref_path_prefix
      threads: threads
      align_chunks: align_chunks
      emit_gam: emit_gam
      call_sv: call_sv
    scatter: [fq1, fq2, rg, lane]
    scatterMethod: dotproduct
    out: [namecol_bam, gam, pack_gam]

  # 3. Duplicate marking, variant calling and the SV track.
  call:
    run: parts/call-gpu.cwl
    in:
      gbz: gbz
      ref_paths: ref_paths
      ref: ref
      ref_path_prefix: ref_path_prefix
      autosome_interval: autosome_interval
      autosome_chunks: autosome_chunks
      autosome_chunks_count: autosome_chunks_count
      PAR_interval: PAR_interval
      chrX_interval: chrX_interval
      chrY_interval: chrY_interval
      prefix: prefix
      threads: threads
      keep_bam: keep_bam
      snarls: snarls
      keep_pack: keep_pack
      sv_min_length: sv_min_length
      sample_name: prepare/sample_name
      namecol_bams: align/namecol_bam
      gams: align/gam
      pack_gams: align/pack_gam
    out: [bam, gam, sv_vcf, sv_vcf_chrX_female, sv_vcf_chrX_male, sv_vcf_chrY, pack, markdup_metrics, gvcf_autosome, gvcf_PAR, gvcf_chrX_female, gvcf_chrX_male, gvcf_chrY]

outputs:
  bam:
    type: File?
    doc: BAM duplicate-marked, in reference coordinates (materialised when keep_bam is true)
    outputSource: call/bam
    secondaryFiles:
      - .bai

  gam:
    type: File[]?
    doc: Per-lane graph-space alignment in GAM format (kept when emit_gam is true)
    outputSource: call/gam

  sv_vcf:
    type: File?
    doc: Structural variants of the pangenome graph genotyped for this sample over the autosomes and PAR, diploid, in reference coordinates (produced when call_sv is true)
    outputSource: call/sv_vcf

  sv_vcf_chrX_female:
    type: File?
    doc: Genotyped graph SVs on chrX outside PAR, diploid. Emitted alongside the male file because the sample's sex is not an input, exactly as the gVCFs are.
    outputSource: call/sv_vcf_chrX_female

  sv_vcf_chrX_male:
    type: File?
    doc: Genotyped graph SVs on chrX outside PAR, haploid
    outputSource: call/sv_vcf_chrX_male

  sv_vcf_chrY:
    type: File?
    doc: Genotyped graph SVs on chrY outside PAR, haploid
    outputSource: call/sv_vcf_chrY

  pack:
    type: File?
    doc: Sample-wide vg pack read support in graph space (materialised when keep_pack is true). Re-runs of vg call need only this and the graph's snarls.
    outputSource: call/pack
    secondaryFiles:
      - .tbi

  markdup_metrics:
    type: File
    doc: MarkDuplicates statistics (replaces the BQSR table of the linear WGSpipeline)
    outputSource: call/markdup_metrics

  gvcf_autosome:
    type: File
    doc: Diploid gVCF for autosome regions (reference coordinates)
    outputSource: call/gvcf_autosome
    secondaryFiles:
      - .tbi

  gvcf_PAR:
    type: File
    doc: Diploid gVCF for PAR regions (reference coordinates)
    outputSource: call/gvcf_PAR
    secondaryFiles:
      - .tbi

  gvcf_chrX_female:
    type: File
    doc: Diploid gVCF for female chrX
    outputSource: call/gvcf_chrX_female
    secondaryFiles:
      - .tbi

  gvcf_chrX_male:
    type: File
    doc: Haploid gVCF for male chrX
    outputSource: call/gvcf_chrX_male
    secondaryFiles:
      - .tbi

  gvcf_chrY:
    type: File
    doc: Haploid gVCF for chrY
    outputSource: call/gvcf_chrY
    secondaryFiles:
      - .tbi
