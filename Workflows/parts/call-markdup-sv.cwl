#!/usr/bin/env cwl-runner

# The CPU half of the calling stage: duplicate marking over all lanes and the
# graph SV track (vg pack + vg call). Its BAM feeds parts/call-dv-parabricks.cwl.
#
# parts/call-parabricks.cwl chains the two halves for the single-node workflow;
# scripts/submit-slurm.sh --variant parabricks runs them as two Slurm jobs, this
# one on a CPU node and the DeepVariant one on a GPU node, so a GPU node is held
# only while the GPUs work.

class: Workflow
id: call-markdup-sv
label: call-markdup-sv
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

  filter_sv_nonrep:
    run: ../../Tools/sv-filter-nonrep.cwl
    in:
      sv_vcf: call_sv_step/sv_vcf
      sv_vcf_chrX_female: call_sv_step/sv_vcf_chrX_female
      sv_vcf_chrX_male: call_sv_step/sv_vcf_chrX_male
      sv_vcf_chrY: call_sv_step/sv_vcf_chrY
      exclude_bed: sv_exclude_bed
      min_qual: sv_filter_min_qual
      max_short_allele: sv_filter_max_short_allele
      min_length: sv_min_length
    out:
      - nonrep_vcf
      - nonrep_vcf_chrX_female
      - nonrep_vcf_chrX_male
      - nonrep_vcf_chrY

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

outputs:
  sv_nonrep_vcf:
    type: File?
    doc: Graph SVs of the autosomes and PAR kept by the sv_exclude_bed filter (simple DEL/INS outside the excluded regions; produced when call_sv is true and sv_exclude_bed is given)
    outputSource: filter_sv_nonrep/nonrep_vcf
    secondaryFiles:
      - .tbi

  sv_nonrep_vcf_chrX_female:
    type: File?
    doc: As sv_nonrep_vcf, chrX outside PAR, diploid
    outputSource: filter_sv_nonrep/nonrep_vcf_chrX_female
    secondaryFiles:
      - .tbi

  sv_nonrep_vcf_chrX_male:
    type: File?
    doc: As sv_nonrep_vcf, chrX outside PAR, haploid
    outputSource: filter_sv_nonrep/nonrep_vcf_chrX_male
    secondaryFiles:
      - .tbi

  sv_nonrep_vcf_chrY:
    type: File?
    doc: As sv_nonrep_vcf, chrY outside PAR, haploid
    outputSource: filter_sv_nonrep/nonrep_vcf_chrY
    secondaryFiles:
      - .tbi

  bam:
    type: File
    doc: BAM duplicate-marked, in reference coordinates; always written, since the DeepVariant calls read it
    outputSource: to_markdup_bam/bam
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
