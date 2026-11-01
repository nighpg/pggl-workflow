#!/usr/bin/env cwl-runner

# Stage 3 of germline-pangenome-parabricks.cwl: everything after the lanes are mapped --
# duplicate marking over all lanes, the five DeepVariant calls, and the graph
# SV track (vg pack + vg call) when lane GAMs are given.
#
# Used as a subworkflow by Workflows/germline-pangenome-parabricks.cwl. It chains
# three parts: parts/call-markdup.cwl (CPU: duplicate marking),
# parts/call-sv.cwl (CPU: graph SVs) and parts/call-dv-parabricks.cwl (GPU:
# DeepVariant on the markdup BAM). scripts/submit-slurm.sh runs them as separate
# Slurm jobs, so the GPU node is held only for DeepVariant and DeepVariant does
# not wait for the SVs. Edit the steps there, not here.

class: Workflow
id: call-parabricks
label: call-parabricks
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  ScatterFeatureRequirement: {}
  StepInputExpressionRequirement: {}
  SubworkflowFeatureRequirement: {}

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

  sv_exclude_bed:
    type: File?
    doc: Regions whose graph SV calls are left out of <prefix>.sv*.nonrep.vcf.gz, e.g. GIAB GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz. Given, it adds those filtered VCFs (simple DEL/INS the sample carries, PASS, QUAL >= sv_filter_min_qual, no overlap with the BED); unset, nothing changes. The SV VCFs themselves are never altered.

  sv_filter_min_qual:
    type: float
    doc: Minimum QUAL for the .nonrep SV VCFs
    default: 30

  sv_filter_max_short_allele:
    type: int
    doc: For the .nonrep SV VCFs, a record is a simple deletion or insertion when its shorter allele (padding base included) is at most this long; longer ones (inversions, complex substitutions) are dropped
    default: 10

  num_gpus:
    type: int
    doc: GPUs each pbrun deepvariant call uses (--num-gpus). The calls run one after another unless cwltool --parallel has the GPUs to run several; Slurm must grant them (--gres=gpu:N).
    default: 1

steps:
  markdup:
    run: call-markdup.cwl
    in:
      prefix: prefix
      threads: threads
      namecol_bams: namecol_bams
      gams: gams
    out:
      - bam
      - gam
      - markdup_metrics

  sv:
    run: call-sv.cwl
    in:
      gbz: gbz
      ref_paths: ref_paths
      ref: ref
      ref_path_prefix: ref_path_prefix
      PAR_interval: PAR_interval
      chrX_interval: chrX_interval
      chrY_interval: chrY_interval
      prefix: prefix
      threads: threads
      snarls: snarls
      keep_pack: keep_pack
      sv_min_length: sv_min_length
      sample_name: sample_name
      pack_gams: pack_gams
      sv_exclude_bed: sv_exclude_bed
      sv_filter_min_qual: sv_filter_min_qual
      sv_filter_max_short_allele: sv_filter_max_short_allele
    out:
      - sv_nonrep_vcf
      - sv_nonrep_vcf_chrX_female
      - sv_nonrep_vcf_chrX_male
      - sv_nonrep_vcf_chrY
      - sv_vcf
      - sv_vcf_chrX_female
      - sv_vcf_chrX_male
      - sv_vcf_chrY
      - pack

  keep_bam_gate:
    run: ../../Tools/keep-bam.cwl
    in:
      bam_in: markdup/bam
      keep: keep_bam
    out:
      - bam

  deepvariant:
    run: call-dv-parabricks.cwl
    in:
      ref: ref
      autosome_interval: autosome_interval
      autosome_chunks: autosome_chunks
      autosome_chunks_count: autosome_chunks_count
      PAR_interval: PAR_interval
      chrX_interval: chrX_interval
      chrY_interval: chrY_interval
      prefix: prefix
      threads: threads
      num_gpus: num_gpus
      bam: markdup/bam
    out:
      - gvcf_autosome
      - gvcf_PAR
      - gvcf_chrX_female
      - gvcf_chrX_male
      - gvcf_chrY

outputs:
  sv_nonrep_vcf:
    type: File?
    doc: Graph SVs of the autosomes and PAR kept by the sv_exclude_bed filter (simple DEL/INS outside the excluded regions; produced when call_sv is true and sv_exclude_bed is given)
    outputSource: sv/sv_nonrep_vcf
    secondaryFiles:
      - .tbi

  sv_nonrep_vcf_chrX_female:
    type: File?
    doc: As sv_nonrep_vcf, chrX outside PAR, diploid
    outputSource: sv/sv_nonrep_vcf_chrX_female
    secondaryFiles:
      - .tbi

  sv_nonrep_vcf_chrX_male:
    type: File?
    doc: As sv_nonrep_vcf, chrX outside PAR, haploid
    outputSource: sv/sv_nonrep_vcf_chrX_male
    secondaryFiles:
      - .tbi

  sv_nonrep_vcf_chrY:
    type: File?
    doc: As sv_nonrep_vcf, chrY outside PAR, haploid
    outputSource: sv/sv_nonrep_vcf_chrY
    secondaryFiles:
      - .tbi

  bam:
    type: File?
    doc: BAM duplicate-marked, in reference coordinates (materialised when keep_bam is true)
    outputSource: keep_bam_gate/bam
    secondaryFiles:
      - .bai

  gam:
    type: File[]?
    doc: Per-lane graph-space alignment in GAM format (kept when emit_gam is true)
    outputSource: markdup/gam

  sv_vcf:
    type: File?
    doc: Structural variants of the pangenome graph genotyped for this sample over the autosomes and PAR, diploid, in reference coordinates (produced when call_sv is true)
    outputSource: sv/sv_vcf

  sv_vcf_chrX_female:
    type: File?
    doc: Genotyped graph SVs on chrX outside PAR, diploid. Emitted alongside the male file because the sample's sex is not an input, exactly as the gVCFs are.
    outputSource: sv/sv_vcf_chrX_female

  sv_vcf_chrX_male:
    type: File?
    doc: Genotyped graph SVs on chrX outside PAR, haploid
    outputSource: sv/sv_vcf_chrX_male

  sv_vcf_chrY:
    type: File?
    doc: Genotyped graph SVs on chrY outside PAR, haploid
    outputSource: sv/sv_vcf_chrY

  pack:
    type: File?
    doc: Sample-wide vg pack read support in graph space (materialised when keep_pack is true). Re-runs of vg call need only this and the graph's snarls.
    outputSource: sv/pack
    secondaryFiles:
      - .tbi

  markdup_metrics:
    type: File
    doc: MarkDuplicates statistics (replaces the BQSR table of the linear WGSpipeline)
    outputSource: markdup/markdup_metrics

  gvcf_autosome:
    type: File
    doc: Diploid gVCF for autosome regions (reference coordinates)
    outputSource: deepvariant/gvcf_autosome
    secondaryFiles:
      - .tbi

  gvcf_PAR:
    type: File
    doc: Diploid gVCF for PAR regions (reference coordinates)
    outputSource: deepvariant/gvcf_PAR
    secondaryFiles:
      - .tbi

  gvcf_chrX_female:
    type: File
    doc: Diploid gVCF for female chrX
    outputSource: deepvariant/gvcf_chrX_female
    secondaryFiles:
      - .tbi

  gvcf_chrX_male:
    type: File
    doc: Haploid gVCF for male chrX
    outputSource: deepvariant/gvcf_chrX_male
    secondaryFiles:
      - .tbi

  gvcf_chrY:
    type: File
    doc: Haploid gVCF for chrY
    outputSource: deepvariant/gvcf_chrY
    secondaryFiles:
      - .tbi
