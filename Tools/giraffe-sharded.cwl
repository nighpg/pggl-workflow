#!/usr/bin/env cwl-runner

class: CommandLineTool
id: giraffe-sharded
label: vg-giraffe (parallel sharded, GAM + surject to BAM)
cwlVersion: v1.1

$namespaces:
  cwltool: http://commonwl.org/cwltool#

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/giraffe-sharded.sh
        basename: giraffe-sharded.sh
      - class: File
        location: ../scripts/vg-giraffe.sh
        basename: vg-giraffe.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0

baseCommand: [bash, giraffe-sharded.sh]

inputs:
  gbz:
    type: File
    doc: GBZ pangenome graph
    inputBinding:
      position: 1

  dist:
    type: File
    doc: giraffe distance index (.dist)
    inputBinding:
      position: 2

  min:
    type: File
    doc: giraffe minimizer index (.min)
    inputBinding:
      position: 3

  zipcodes:
    type: File
    doc: giraffe zipcode index (.zipcodes)
    inputBinding:
      position: 4

  ref_paths:
    type: File
    doc: Ordered reference paths of the graph, either one path name per line or an HTSlib sequence dictionary (.dict); drives giraffe @SQ and surjection. The dictionary form is required when the reference is stored as PanSN subranges (chr1[585988]), because the contig names and lengths then come from the header instead of from the split paths.
    inputBinding:
      position: 5

  threads:
    type: int
    doc: Number of mapping threads; split across the chunks (each chunk gets ceil(threads/chunks))
    inputBinding:
      position: 6

  read_group:
    type: string
    doc: Read group string applied to the output alignments (-R); the full @RG header is applied afterwards with samtools addreplacerg
    default: ""
    inputBinding:
      position: 7

  sample:
    type: string
    doc: Sample name (sets SM) applied to the output alignments (-N)
    default: ""
    inputBinding:
      position: 8

  fq1:
    type: File
    doc: FASTQ file 1
    inputBinding:
      position: 9

  fq2:
    type: File
    doc: FASTQ file 2
    inputBinding:
      position: 10

  lane:
    type: string
    doc: Lane / read-group ID used to name the output BAM and GAM; must be unique per lane
    inputBinding:
      position: 11

  emit_gam:
    type: boolean?
    doc: Keep the per-lane graph-space GAM (lane.gam) as a workflow output. When false only the surjected BAM is kept -- unless call_sv is set, which needs the GAM regardless and takes it through the pack_gam output instead.
    default: false

  chunks:
    type: int
    doc: Shard the FASTQ pair into this many read-pair blocks and map them in parallel (1 = single process). A block never splits a read pair, so the alignment of every read is identical to a single-process run.
    default: 1
    inputBinding:
      position: 13

  call_sv:
    type: boolean?
    doc: Keep this lane's GAM so the SV track can pack it. Nothing is packed here; the packing is done once for the whole sample, over every lane's GAM concatenated, because vg pack -i segfaults summing per-lane packs on a whole-genome graph.
    default: false

arguments:
  - position: 12
    valueFrom: '$(inputs.emit_gam ? "true" : "false")'
  - position: 14
    valueFrom: '$(inputs.call_sv ? "true" : "false")'

outputs:
  bam:
    type: File
    doc: Aligned BAM, surjected onto the reference paths in the --ref-paths file
    outputBinding:
      glob: $(inputs.lane).bam

  gam:
    type: File?
    doc: Per-lane graph-space alignment in GAM format (kept only when emit_gam is set)
    outputBinding:
      # The file also exists when only call_sv asked for it, and that copy
      # belongs to pack_gam, not to the workflow's gam output -- so glob a name
      # that cannot match unless emit_gam really was set.
      glob: '$(inputs.emit_gam ? inputs.lane + ".gam" : "emit-gam-was-not-set")'

  pack_gam:
    type: File?
    doc: Per-lane graph-space alignment handed to the sample-wide vg pack (produced only when call_sv is set)
    outputBinding:
      glob: '$(inputs.call_sv ? inputs.lane + ".gam" : "call-sv-was-not-set")'