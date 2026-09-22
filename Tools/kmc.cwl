#!/usr/bin/env cwl-runner

class: CommandLineTool
id: kmc
label: kmc (count the sample's k-mers into a KFF)
cwlVersion: v1.1

doc: |
  Counts the sample's k-mers, which is how `vg haplotypes` decides which
  haplotypes of the pangenome the sample actually carries.

  kmer_length must match the .hapl used for sampling; vg builds that at k=29 by
  default. A mismatch is not diagnosed, it just scores badly.

  KMC cannot read CRAM -- it has its own BAM reader rather than htslib, and
  fails with "wrong EOF marker of BAM file" -- so this takes FASTQ. Read groups
  do not matter: every lane is counted as one sample.

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/kmc-count.sh
        basename: kmc-count.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/kmc:3.2.1--hf1761c0_2
    dockerFile: |
      # Runs under cwltool --no-container in this project, where kmc must be on
      # PATH; the SIFs stage the Ubuntu jammy deb the same way as biobambam2.

baseCommand: [bash, kmc-count.sh]

inputs:
  prefix:
    type: string
    doc: Output file prefix; produces <prefix>.kff
    inputBinding:
      position: 1

  kmer_length:
    type: int
    doc: k for counting. Must equal the k the .hapl was built with (vg's default is 29).
    default: 29
    inputBinding:
      position: 2

  threads:
    type: int
    doc: Number of threads
    default: 16
    inputBinding:
      position: 3

  max_memory_gb:
    type: int
    doc: KMC's memory budget in GB (-m). It spills to disk beyond this, so lowering it trades RAM for scratch space and time.
    default: 64
    inputBinding:
      position: 4

  min_count:
    type: int
    doc: Drop k-mers seen fewer than this many times (-ci). The default 2 removes sequencing-error k-mers; use 1 only on toy-scale data, where genuine k-mers are singletons too.
    default: 2
    inputBinding:
      position: 5

  fastq:
    type: File[]
    doc: Every read file of the sample, R1 and R2 of every lane together
    inputBinding:
      position: 6

outputs:
  kff:
    type: File
    doc: k-mer counts for vg haplotypes
    outputBinding:
      glob: $(inputs.prefix).kff
