#!/usr/bin/env cwl-runner

class: CommandLineTool
id: parabricks-deepvariant
label: deepvariant (NVIDIA Parabricks pbrun deepvariant, GPU)
cwlVersion: v1.1

doc: |
  Drop-in replacement for Tools/deepvariant.cwl and Tools/deepvariant-gpu.cwl:
  the same inputs and outputs, run with NVIDIA Parabricks' GPU DeepVariant. The
  run_deepvariant style extra arguments the call parts pass (min_mapping_quality,
  normalize_reads, haploid_contigs) are translated to pbrun options by
  scripts/parabricks-deepvariant.sh, which refuses any it does not know. The
  pangenome-aware caller has no Parabricks counterpart and stays on Google's
  image. Results are expected to match DeepVariant closely but not bit for bit;
  validate on a benchmark sample before switching production runs.

requirements:
  InlineJavascriptRequirement: {}
  ResourceRequirement:
    coresMin: $(inputs.num_shards)
    ramMin: 40960
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/parabricks-deepvariant.sh
        basename: parabricks-deepvariant.sh

hints:
  DockerRequirement:
    dockerPull: nvcr.io/nvidia/clara/clara-parabricks:4.8.0-1

baseCommand: [bash, parabricks-deepvariant.sh]

inputs:
  ref:
    type: File
    doc: Linear reference FASTA
    secondaryFiles:
      - ^.dict
      - .fai

  reads:
    type: File
    doc: BAM to call variants on
    secondaryFiles:
      - .bai

  interval:
    type: File?
    doc: Interval BED to restrict calling to (autosome / PAR / chrX / chrY)

  num_shards:
    type: int
    doc: CPU cores reserved for the step (pbrun sets its own CPU threads per GPU stream); kept for the same interface as the other DeepVariant tools
    default: 16

  num_gpus:
    type: int
    doc: GPUs pbrun uses (--num-gpus)
    default: 1

  model_type:
    type: string?
    doc: WGS (default) or WES
    default: WGS

  make_examples_extra_args:
    type: string?
    doc: run_deepvariant style make_examples arguments; --min_mapping_quality and --normalize_reads are translated (vg-recommended defaults)
    default: "--min_mapping_quality=0,--normalize_reads=true"

  postprocess_extra_args:
    type: string?
    doc: run_deepvariant style postprocess arguments; --haploid_contigs is translated

  prefix:
    type: string
    doc: Output file prefix

arguments:
  - position: 1
    valueFrom: $(inputs.ref.path)
  - position: 2
    valueFrom: $(inputs.reads.path)
  - position: 3
    valueFrom: '$(inputs.interval === null ? "" : inputs.interval.path)'
  - position: 4
    valueFrom: $(inputs.prefix)
  - position: 5
    valueFrom: $(inputs.num_gpus)
  - position: 6
    valueFrom: '$(inputs.make_examples_extra_args === null ? "" : inputs.make_examples_extra_args)'
  - position: 7
    valueFrom: '$(inputs.postprocess_extra_args === null ? "" : inputs.postprocess_extra_args)'
  - position: 8
    valueFrom: '$(inputs.model_type === null ? "WGS" : inputs.model_type)'

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
