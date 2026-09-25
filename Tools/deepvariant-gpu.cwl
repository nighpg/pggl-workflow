#!/usr/bin/env cwl-runner

class: CommandLineTool
id: deepvariant-gpu
label: deepvariant-gpu (run_deepvariant, GPU)
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  # Reserve the cores this step actually uses, so `cwltool --parallel` only
  # starts it when they are free instead of oversubscribing the node.
  ResourceRequirement:
    coresMin: $(inputs.num_shards)
    ramMin: 40960

hints:
  DockerRequirement:
    dockerPull: google/deepvariant:1.10.0-gpu
    dockerFile: |
      # GPU: requires a CUDA-capable driver on the host and singularity/docker --nv
      # This hint only pins the image; cwltool runs the bundled GPU run_deepvariant
      # when the tools are on $PATH (no-container), provided the runtime used --nv.

baseCommand: [/opt/deepvariant/bin/run_deepvariant]

inputs:
  ref:
    type: File
    doc: Linear reference FASTA
    inputBinding:
      prefix: --ref
      position: 1
    secondaryFiles:
      - ^.dict
      - .fai

  reads:
    type: File
    doc: BAM to call variants on
    inputBinding:
      prefix: --reads
      position: 2
    secondaryFiles:
      - .bai

  interval:
    type: File?
    doc: Interval BED to restrict calling to (autosome / PAR / chrX / chrY)
    inputBinding:
      prefix: --regions
      position: 3

  num_shards:
    type: int
    doc: Number of shards to split the region over
    inputBinding:
      prefix: --num_shards
      position: 4

  model_type:
    type: string?
    doc: DeepVariant model type
    default: WGS
    inputBinding:
      prefix: --model_type
      position: 5

  make_examples_extra_args:
    type: string?
    doc: Extra arguments passed to make_examples (vg-recommended defaults, passed comma-separated as required by run_deepvariant's _extra_args_to_dict)
    default: "--min_mapping_quality=0,--normalize_reads=true"
    inputBinding:
      prefix: --make_examples_extra_args
      position: 6

  postprocess_extra_args:
    type: string?
    doc: Extra arguments passed to postprocess_variants (e.g. --haploid_contigs=chrX)
    inputBinding:
      prefix: --postprocess_variants_extra_args
      position: 7

  prefix:
    type: string
    doc: Output file prefix

arguments:
  - position: 8
    prefix: --output_vcf
    valueFrom: $(inputs.prefix).vcf.gz
  - position: 9
    prefix: --output_gvcf
    valueFrom: $(inputs.prefix).g.vcf.gz

outputs:
  gvcf:
    type: File
    doc: gVCF of the interval (diploid, or haploid for the male runs)
    outputBinding:
      glob: $(inputs.prefix).g.vcf.gz
    secondaryFiles:
      - .tbi

  vcf:
    type: File
    doc: VCF of the interval
    outputBinding:
      glob: $(inputs.prefix).vcf.gz
    secondaryFiles:
      - .tbi