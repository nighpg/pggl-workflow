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
    doc: Coordinate-sorted aligned CRAM in reference coordinates with @SQ matching ref; reads are recovered to FASTQ (decoded with ref) and re-mapped onto the pangenome with vg giraffe, exactly like a FASTQ lane (its @RG is carried over). Mutually exclusive with bam.
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
    doc: Number of parallel vg giraffe processes per lane. The lane FASTQ pair is sharded into this many read-pair blocks (pairs never split), mapped in parallel with threads/chunks threads each, and the per-block BAMs are concatenated with samtools cat. Alignment results are identical to a single process (only lane BAM record order changes); total memory use stays ~constant while the per-process peak drops. Set 1 for the original single-process behaviour.
    default: 1

  call_sv:
    type: boolean
    doc: Genotype the structural variants that are embedded in the pangenome graph (vg pack + vg call) and emit <prefix>.sv.vcf.gz. This only genotypes variation present in the graph; vg cannot discover novel SVs, so novel events still need a linear caller on <prefix>.bam. Off by default because it keeps every lane's GAM on disk until the sample-wide pack is built, tens of GB per lane at whole-genome depth.
    default: false

  snarls:
    type: File?
    doc: Precomputed snarls for the graph (vg snarls). Optional, but on whole-genome graphs recomputing them inside every run is expensive, so generate them once alongside the giraffe indexes. Ignored when call_sv is false.

  sv_min_length:
    type: int
    doc: Minimum traversal length for a graph site to be genotyped as an SV (vg call -c). 50 matches the usual SV definition; lower it to also emit smaller graph variants.
    default: 50

steps:
  lane_from_rg:
    run: ../Tools/lane-from-rg.cwl
    in:
      rg: combine_lanes/rg
    out:
      - lane_names
      - sample_name

  cram_to_fastq:
    run: ../Tools/samtools-cram-to-fastq.cwl
    in:
      prefix: prefix
      threads: threads
      cram: cram
      bam: bam
      ref: ref
    out:
      - fq1
      - fq2
      - rg

  combine_lanes:
    run: ../Tools/combine-lanes.cwl
    in:
      user_fq1: fq1
      user_fq2: fq2
      user_rg: rg
      cram_fq1: cram_to_fastq/fq1
      cram_fq2: cram_to_fastq/fq2
      cram_rg:
        source: cram_to_fastq/rg
        loadContents: true
    out:
      - fq1
      - fq2
      - rg

  giraffe:
    run: ../Tools/giraffe-sharded.cwl
    in:
      gbz: gbz
      dist: dist
      min: min
      zipcodes: zipcodes
      ref_paths: ref_paths
      threads: threads
      read_group: combine_lanes/rg
      fq1: combine_lanes/fq1
      fq2: combine_lanes/fq2
      lane: lane_from_rg/lane_names
      emit_gam: emit_gam
      chunks: align_chunks
      call_sv: call_sv
    scatter: [fq1, fq2, read_group, lane]
    scatterMethod: dotproduct
    out:
      - bam
      - gam
      - pack_gam

  pick_pack_gam:
    run: ../Tools/pick-gam.cwl
    in:
      gam_in: giraffe/pack_gam
    out:
      - gam

  build_pack:
    run: ../Tools/vg-pack.cwl
    in:
      gbz: gbz
      gams: pick_pack_gam/gam
      prefix: prefix
      threads: threads
    out:
      - pack

  call_sv_step:
    run: ../Tools/vg-call-sv.cwl
    in:
      gbz: gbz
      pack: build_pack/pack
      ref_paths: ref_paths
      snarls: snarls
      prefix: prefix
      sample: lane_from_rg/sample_name
      threads: threads
      min_length: sv_min_length
      ref_path_prefix: ref_path_prefix
      PAR_interval: PAR_interval
      chrX_interval: chrX_interval
      chrY_interval: chrY_interval
    out:
      - sv_vcf
      - sv_vcf_chrX_female
      - sv_vcf_chrX_male
      - sv_vcf_chrY

  pick_gam:
    run: ../Tools/pick-gam.cwl
    in:
      gam_in: giraffe/gam
    out:
      - gam

  # Lane prep for bamsormadup ("B"): strip the graph reference prefix and apply
  # the full @RG, keeping the input name-collated order (no sort -n / fixmate /
  # sort). bamsormadup then does fixmate + coordinate sort + markdup in one pass.
  prep_lane:
    run: ../Tools/samtools-prep-lane.cwl
    in:
      bam: giraffe/bam
      rg: combine_lanes/rg
      ref_path_prefix: ref_path_prefix
      lane: lane_from_rg/lane_names
      threads: threads
    scatter: [bam, rg, lane]
    scatterMethod: dotproduct
    out:
      - namecol_bam

  to_markdup_bam:
    run: ../Tools/bamsormadup-to-markdup-bam.cwl
    in:
      namecol_bams:
        source: prep_lane/namecol_bam
        valueFrom: '$(self != null && self.length > 0 ? self : null)'
      prefix: prefix
      threads: threads
    out:
      - bam
      - markdup_metrics

  keep_bam_gate:
    run: ../Tools/keep-bam.cwl
    in:
      bam_in: to_markdup_bam/bam
      keep: keep_bam
    out:
      - bam

  make_autosome_chunks:
    run: ../Tools/make-autosome-chunks.cwl
    in:
      bed: autosome_interval
      count: autosome_chunks_count
      user_chunks: autosome_chunks
    out:
      - chunks

  autosome_regions:
    run: ../Tools/autosome-regions.cwl
    in:
      autosome_chunks: make_autosome_chunks/chunks
      autosome_interval: autosome_interval
      base_shards: threads
      prefix: prefix
    out:
      - chunks
      - prefixes
      - shards

  deepvariant_autosome:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: autosome_regions/chunks
      num_shards: autosome_regions/shards
      prefix: autosome_regions/prefixes
    scatter: [interval, num_shards, prefix]
    scatterMethod: dotproduct
    out:
      - gvcf

  concat_autosome:
    run: ../Tools/concat-gvcfs.cwl
    in:
      prefix: prefix
      gvcf: deepvariant_autosome/gvcf
    out:
      - out_gvcf

  deepvariant_PAR:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: PAR_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".PAR")
    out:
      - gvcf

  deepvariant_chrX_female:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: chrX_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_female")
    out:
      - gvcf

  deepvariant_chrX_male:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: chrX_interval
      num_shards: threads
      postprocess_extra_args:
        valueFrom: "--haploid_contigs=chrX"
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_male")
    out:
      - gvcf

  deepvariant_chrY:
    run: ../Tools/deepvariant-gpu.cwl
    in:
      ref: ref
      reads: to_markdup_bam/bam
      interval: chrY_interval
      num_shards: threads
      postprocess_extra_args:
        valueFrom: "--haploid_contigs=chrY"
      prefix:
        source: prefix
        valueFrom: $(self + ".chrY")
    out:
      - gvcf

outputs:
  bam:
    type: File?
    doc: BAM duplicate-marked, in reference coordinates (materialised when keep_bam is true)
    outputSource: keep_bam_gate/bam
    secondaryFiles:
      - .bai

  gam:
    type: File[]?
    doc: Per-lane graph-space alignment in GAM format (kept when emit_gam is true)
    outputSource: pick_gam/gam

  sv_vcf:
    type: File?
    doc: Structural variants of the pangenome graph genotyped for this sample over the autosomes and PAR, diploid, in reference coordinates (produced when call_sv is true)
    outputSource: call_sv_step/sv_vcf

  sv_vcf_chrX_female:
    type: File?
    doc: Genotyped graph SVs on chrX outside PAR, diploid. Emitted alongside the male file because the sample's sex is not an input, exactly as the gVCFs are.
    outputSource: call_sv_step/sv_vcf_chrX_female

  sv_vcf_chrX_male:
    type: File?
    doc: Genotyped graph SVs on chrX outside PAR, haploid
    outputSource: call_sv_step/sv_vcf_chrX_male

  sv_vcf_chrY:
    type: File?
    doc: Genotyped graph SVs on chrY outside PAR, haploid
    outputSource: call_sv_step/sv_vcf_chrY
    secondaryFiles:
      - .tbi

  markdup_metrics:
    type: File
    doc: MarkDuplicates statistics (replaces the BQSR table of the linear WGSpipeline)
    outputSource: to_markdup_bam/markdup_metrics

  gvcf_autosome:
    type: File
    doc: Diploid gVCF for autosome regions (reference coordinates)
    outputSource: concat_autosome/out_gvcf
    secondaryFiles:
      - .tbi

  gvcf_PAR:
    type: File
    doc: Diploid gVCF for PAR regions (reference coordinates)
    outputSource: deepvariant_PAR/gvcf
    secondaryFiles:
      - .tbi

  gvcf_chrX_female:
    type: File
    doc: Diploid gVCF for female chrX
    outputSource: deepvariant_chrX_female/gvcf
    secondaryFiles:
      - .tbi

  gvcf_chrX_male:
    type: File
    doc: Haploid gVCF for male chrX
    outputSource: deepvariant_chrX_male/gvcf
    secondaryFiles:
      - .tbi

  gvcf_chrY:
    type: File
    doc: Haploid gVCF for chrY
    outputSource: deepvariant_chrY/gvcf
    secondaryFiles:
      - .tbi