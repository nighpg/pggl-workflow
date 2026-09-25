#!/usr/bin/env cwl-runner

# Stage 3 of germline-pangenome-pangenome-aware-cpu.cwl: everything after the lanes are mapped --
# duplicate marking over all lanes, the five DeepVariant calls, and the graph
# SV track (vg pack + vg call) when lane GAMs are given.
#
# Used as a subworkflow by Workflows/germline-pangenome-pangenome-aware-cpu.cwl, and run on its own by
# scripts/submit-slurm.sh once every lane's parts/lane-align.cwl job is done.
# The steps are those of the germline workflow verbatim; keep them in sync by
# editing them here, not there.

class: Workflow
id: call-pangenome-aware-cpu
label: call-pangenome-aware-cpu
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  ScatterFeatureRequirement: {}
  StepInputExpressionRequirement: {}

inputs:
  gbz:
    type: File
    doc: GBZ pangenome graph

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

  ref_name_pangenome:
    type: string
    doc: PanSN sample name of the reference inside the GBZ, i.e. the assembly the reads are surjected onto (GRCh38 for a GRCh38-backed graph, CHM13v2 for JaSaPaGe). Consumed only by the pangenome-aware caller.
    default: "GRCh38"

  sample_name_pangenome:
    type: string
    doc: Name recorded for the haplotype panel taken from the GBZ. Cosmetic, but it must differ from the reads' SM, or make_examples stops with "Sample names for reads and pangenome cannot be the same". Defaults to the same neutral name as Tools/pangenome-aware-deepvariant.cwl rather than the tool's own (hprc_v1.1) or the assembly name, either of which can collide with a real @RG SM.
    default: "pangenome"

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
    doc: Number of threads for vg giraffe, samtools and DeepVariant shards
    default: 32

  keep_bam:
    type: boolean
    doc: Keep the final duplicate-marked BAM (prefix.bam / .bai) as a workflow output. The BAM is always produced internally because DeepVariant requires BAM; set false to avoid materialising it in the output directory (e.g. to save disk).
    default: true

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

  sample_name:
    type: string
    doc: Sample name written into the SV VCF (the SM of the read groups, from parts/prepare-lanes.cwl)
    default: SAMPLE

  namecol_bams:
    type: File[]
    doc: Name-collated lane BAMs from parts/lane-align.cwl, in lane order; duplicate-marked together

  gams:
    type:
      - "null"
      - type: array
        items: ["null", File]
    doc: Lane GAMs to pass through as the gam output (emit_gam); nulls are dropped
    default: []

  pack_gams:
    type:
      - "null"
      - type: array
        items: ["null", File]
    doc: Lane GAMs for the sample-wide vg pack; empty turns the SV track off (call_sv=false)
    default: []

steps:
  pick_pack_gam:
    run: ../../Tools/pick-gam.cwl
    in:
      gam_in: pack_gams
    out:
      - gam

  build_pack:
    run: ../../Tools/vg-pack.cwl
    in:
      gbz: gbz
      gams: pick_pack_gam/gam
      prefix: prefix
      threads: threads
    out:
      - pack

  keep_pack_gate:
    run: ../../Tools/keep-pack.cwl
    in:
      pack_in: build_pack/pack
      keep: keep_pack
    out:
      - pack

  call_sv_step:
    run: ../../Tools/vg-call-sv.cwl
    in:
      gbz: gbz
      pack: build_pack/pack
      ref_paths: ref_paths
      snarls: snarls
      prefix: prefix
      sample: sample_name
      threads: threads
      min_length: sv_min_length
      ref_path_prefix: ref_path_prefix
      PAR_interval: PAR_interval
      chrX_interval: chrX_interval
      chrY_interval: chrY_interval
      ref: ref
    out:
      - sv_vcf
      - sv_vcf_chrX_female
      - sv_vcf_chrX_male
      - sv_vcf_chrY

  pick_gam:
    run: ../../Tools/pick-gam.cwl
    in:
      gam_in: gams
    out:
      - gam

  to_markdup_bam:
    run: ../../Tools/bamsormadup-to-markdup-bam.cwl
    in:
      namecol_bams:
        source: namecol_bams
        valueFrom: '$(self != null && self.length > 0 ? self : null)'
      prefix: prefix
      threads: threads
    out:
      - bam
      - markdup_metrics

  keep_bam_gate:
    run: ../../Tools/keep-bam.cwl
    in:
      bam_in: to_markdup_bam/bam
      keep: keep_bam
    out:
      - bam

  make_autosome_chunks:
    run: ../../Tools/make-autosome-chunks.cwl
    in:
      bed: autosome_interval
      count: autosome_chunks_count
      user_chunks: autosome_chunks
    out:
      - chunks

  autosome_regions:
    run: ../../Tools/autosome-regions.cwl
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
    run: ../../Tools/pangenome-aware-deepvariant.cwl
    in:
      ref: ref
      pangenome: gbz
      ref_name_pangenome: ref_name_pangenome
      sample_name_pangenome: sample_name_pangenome
      reads: to_markdup_bam/bam
      interval: autosome_regions/chunks
      num_shards: autosome_regions/shards
      prefix: autosome_regions/prefixes
    scatter: [interval, num_shards, prefix]
    scatterMethod: dotproduct
    out:
      - gvcf

  concat_autosome:
    run: ../../Tools/concat-gvcfs.cwl
    in:
      prefix: prefix
      gvcf: deepvariant_autosome/gvcf
    out:
      - out_gvcf

  deepvariant_PAR:
    run: ../../Tools/pangenome-aware-deepvariant.cwl
    in:
      ref: ref
      pangenome: gbz
      ref_name_pangenome: ref_name_pangenome
      sample_name_pangenome: sample_name_pangenome
      reads: to_markdup_bam/bam
      interval: PAR_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".PAR")
    out:
      - gvcf

  deepvariant_chrX_female:
    run: ../../Tools/pangenome-aware-deepvariant.cwl
    in:
      ref: ref
      pangenome: gbz
      ref_name_pangenome: ref_name_pangenome
      sample_name_pangenome: sample_name_pangenome
      reads: to_markdup_bam/bam
      interval: chrX_interval
      num_shards: threads
      prefix:
        source: prefix
        valueFrom: $(self + ".chrX_female")
    out:
      - gvcf

  deepvariant_chrX_male:
    run: ../../Tools/pangenome-aware-deepvariant.cwl
    in:
      ref: ref
      pangenome: gbz
      ref_name_pangenome: ref_name_pangenome
      sample_name_pangenome: sample_name_pangenome
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
    run: ../../Tools/pangenome-aware-deepvariant.cwl
    in:
      ref: ref
      pangenome: gbz
      ref_name_pangenome: ref_name_pangenome
      sample_name_pangenome: sample_name_pangenome
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

  pack:
    type: File?
    doc: Sample-wide vg pack read support in graph space (materialised when keep_pack is true). Re-runs of vg call need only this and the graph's snarls.
    outputSource: keep_pack_gate/pack
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
