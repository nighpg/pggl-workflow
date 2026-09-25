#!/usr/bin/env cwl-runner

class: CommandLineTool
id: pangenome-aware-deepvariant
label: pangenome-aware-deepvariant (run_pangenome_aware_deepvariant)
cwlVersion: v1.1

doc: |
  Same contract as Tools/deepvariant.cwl, but calls variants with the pangenome
  haplotypes as extra evidence: make_examples draws the pileup image of the
  reads *and* of the graph's haplotypes at each candidate site, and a model
  trained on that pair infers the genotype.

  The graph is only read at calling time -- reads are not re-mapped, and only
  the GBZ is needed (no .dist/.min/.zipcodes). It is the same GBZ the aligner
  surjected onto, so the workflow passes its own `gbz` input straight through.

  run_pangenome_aware_deepvariant lives in a different image from the plain
  run_deepvariant (google/deepvariant:pangenome_aware_deepvariant-1.10.0, which
  ships no run_deepvariant at all), so the two cannot be mixed in one
  --no-container run; sif-build-pangenome-aware.def builds the matching image.

requirements:
  # Reserve the cores this step actually uses, so `cwltool --parallel` only
  # starts it when they are free instead of oversubscribing the node.
  ResourceRequirement:
    coresMin: $(inputs.num_shards)
  InlineJavascriptRequirement: {}

hints:
  DockerRequirement:
    dockerPull: google/deepvariant:pangenome_aware_deepvariant-1.10.0

baseCommand: [/opt/deepvariant/bin/run_pangenome_aware_deepvariant]

inputs:
  ref:
    type: File
    doc: Linear reference FASTA; must be the assembly the reads were surjected onto
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

  pangenome:
    type: File
    doc: The GBZ pangenome graph whose haplotypes are drawn alongside the reads. The same file the aligner used; its giraffe indexes are not needed here.
    inputBinding:
      prefix: --pangenome
      position: 3

  ref_name_pangenome:
    type: string
    doc: |
      PanSN sample name of the reference inside the GBZ (e.g. GRCh38, CHM13v2);
      it must name the assembly the BAM is in. The graph therefore has to carry
      its reference as a named sample: a GBZ whose reference paths are plain
      contig names (chr20) has no name to give here and cannot be used -- the
      caller stops with "Pangenome path ids not found for pangenome sample
      name". Naming a haplotype sample instead aborts in the same place.
    default: "GRCh38"
    inputBinding:
      prefix: --ref_name_pangenome
      position: 4

  sample_name_pangenome:
    type: string
    doc: |
      Name recorded for the haplotype panel taken from the GBZ. Cosmetic, but
      it must differ from the sample name of the reads, or make_examples stops
      with "Sample names for reads and pangenome cannot be the same" -- hence a
      neutral default rather than the tool's own (hprc_v1.1) or the assembly
      name, either of which can collide with a real @RG SM.
    default: "pangenome"
    inputBinding:
      prefix: --sample_name_pangenome
      position: 5

  interval:
    type: File?
    doc: Interval BED to restrict calling to (autosome / PAR / chrX / chrY)
    inputBinding:
      prefix: --regions
      position: 6

  num_shards:
    type: int
    doc: Number of shards to split the region over
    inputBinding:
      prefix: --num_shards
      position: 7

  model_type:
    type: string?
    doc: Model type; the image ships the pangenome-aware WGS/WES models
    default: WGS
    inputBinding:
      prefix: --model_type
      position: 8

  make_examples_extra_args:
    type: string?
    doc: Extra arguments passed to make_examples (vg-recommended defaults, passed comma-separated as required by run_deepvariant's _extra_args_to_dict)
    default: "--min_mapping_quality=0,--normalize_reads=true"
    inputBinding:
      prefix: --make_examples_extra_args
      position: 9

  postprocess_extra_args:
    type: string?
    doc: Extra arguments passed to postprocess_variants (e.g. --haploid_contigs=chrX)
    inputBinding:
      prefix: --postprocess_variants_extra_args
      position: 10

  shared_memory_size_gb:
    type: int?
    doc: Size of the /dev/shm region the GBZ is loaded into, in GB. The tool's default is 12, which holds a whole-genome graph (JaSaPaGe is 3.3 GB on disk); every concurrent step allocates its own, so raise the node's /dev/shm rather than this if they no longer fit.
    inputBinding:
      prefix: --gbz_shared_memory_size_gb
      position: 11

  prefix:
    type: string
    doc: Output file prefix

arguments:
  # The GBZ is loaded into a named /dev/shm region so that the make_examples
  # shards share one copy. The name is global, and this workflow runs five (or
  # more, once the autosome is chunked) calling steps at once under
  # `cwltool --parallel`, so it is derived from the per-step output prefix,
  # which is already unique, instead of leaving every step on the default
  # GBZ_SHARED_MEMORY.
  - position: 12
    prefix: --gbz_shared_memory_name
    valueFrom: $("GBZ_" + inputs.prefix.replace(/[^A-Za-z0-9_]/g, "_"))
  - position: 13
    prefix: --output_vcf
    valueFrom: $(inputs.prefix).vcf.gz
  - position: 14
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
