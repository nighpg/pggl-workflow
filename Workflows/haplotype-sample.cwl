#!/usr/bin/env cwl-runner

# Builds a sample's personalized pangenome and its giraffe indexes, for the
# germline workflows to then run against unchanged: only their gbz / dist / min
# / zipcodes inputs move to the outputs of this workflow. Everything else --
# ref, ref_paths, ref_path_prefix, the interval BEDs -- is unaffected, because
# sampling keeps the reference paths exactly as they were.
#
# Kept separate from the germline workflows on purpose. The personalized graph
# is an asset of the *sample*, not of one run: the same one serves the standard
# and the pangenome-aware caller, and any re-run, instead of being rebuilt each
# time (about an hour for a 38x genome).
#
# The haplotype information (hapl) is an input: it belongs to the *graph*, costs
# an r-index plus its own pass, and is identical for every sample.
#
#   vg gbwt -Z graph.gbz -r graph.ri
#   vg haplotypes -d graph.dist -r graph.ri -H graph.hapl graph.gbz
#
# Reads come in as FASTQ. KMC cannot read CRAM anyway (it has its own BAM
# reader, not htslib), so a CRAM has to be decoded first either way -- and the
# germline workflows' own CRAM track does that internally without exposing the
# FASTQs. Read groups are irrelevant here: every lane is counted as one sample.

class: Workflow
id: haplotype-sample
label: haplotype-sample
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}
  StepInputExpressionRequirement: {}
  # R1 and R2 of every lane are merged into the single list KMC counts
  MultipleInputFeatureRequirement: {}

inputs:
  fq1:
    type: File[]
    doc: FASTQ file 1, one entry per lane

  fq2:
    type: File[]
    doc: FASTQ file 2, one entry per lane

  gbz:
    type: File
    doc: The full pangenome graph to sample from

  hapl:
    type: File
    doc: Haplotype information for this graph (vg haplotypes -H). Rebuild it with the local vg rather than reusing a downloaded one; the format is versioned and vg 1.70 rejects version 4.

  ref_sample:
    type: string
    doc: PanSN sample name of the reference to keep in the sampled graph (GRCh38, CHM13v2). Dropping the reference would leave vg surject with no target, so this is checked after sampling.
    default: "GRCh38"

  prefix:
    type: string
    doc: Output file prefix, normally the sample name

  threads:
    type: int
    doc: Number of threads for every step
    default: 16

  kmer_length:
    type: int
    doc: k for KMC. Must match the k the hapl was built with (vg's default is 29).
    default: 29

  kmc_max_memory_gb:
    type: int
    doc: KMC memory budget in GB; it spills to disk beyond this
    default: 64

  kmc_min_count:
    type: int
    doc: Drop k-mers seen fewer than this many times. 1 only for toy-scale data.
    default: 2

  diploid_sampling:
    type: boolean
    doc: Choose the best pair of candidate haplotypes (vg's recommendation; wants >=20x coverage)
    default: true

  autoindex_target_mem:
    type: string?
    doc: Memory budget for vg autoindex (-M, e.g. 80G)

  make_snarls:
    type: boolean
    doc: Also compute snarls for the sampled graph. Needed only for the germline workflows' call_sv track, whose snarls must match the graph being genotyped.
    default: false

steps:
  count_kmers:
    run: ../Tools/kmc.cwl
    in:
      prefix: prefix
      kmer_length: kmer_length
      threads: threads
      max_memory_gb: kmc_max_memory_gb
      min_count: kmc_min_count
      fastq:
        source: [fq1, fq2]
        linkMerge: merge_flattened
    out:
      - kff

  sample_haplotypes:
    run: ../Tools/vg-haplotypes.cwl
    in:
      gbz: gbz
      hapl: hapl
      kff: count_kmers/kff
      ref_sample: ref_sample
      prefix: prefix
      threads: threads
      diploid_sampling: diploid_sampling
    out:
      - personalized_gbz

  index_personalized:
    run: ../Tools/vg-autoindex.cwl
    in:
      gbz: sample_haplotypes/personalized_gbz
      prefix:
        source: prefix
        valueFrom: $(self + ".personalized")
      threads: threads
      target_mem: autoindex_target_mem
    out:
      - dist
      - min
      - zipcodes

  snarls_personalized:
    run: ../Tools/vg-snarls.cwl
    in:
      gbz: sample_haplotypes/personalized_gbz
      prefix:
        source: prefix
        valueFrom: $(self + ".personalized")
      threads: threads
      make_snarls: make_snarls
    out:
      - snarls

outputs:
  personalized_gbz:
    type: File
    doc: The sample's personalized pangenome; pass as `gbz` to a germline workflow
    outputSource: sample_haplotypes/personalized_gbz

  dist:
    type: File
    doc: giraffe distance index of the personalized graph
    outputSource: index_personalized/dist

  min:
    type: File
    doc: giraffe minimizer index of the personalized graph
    outputSource: index_personalized/min

  zipcodes:
    type: File
    doc: giraffe zipcode index of the personalized graph
    outputSource: index_personalized/zipcodes

  snarls:
    type: File?
    doc: Snarls of the personalized graph (only when make_snarls is true); pass as `snarls` to a germline workflow running call_sv
    outputSource: snarls_personalized/snarls

  kff:
    type: File
    doc: The sample's k-mer counts, kept so the sampling can be redone without recounting
    outputSource: count_kmers/kff
