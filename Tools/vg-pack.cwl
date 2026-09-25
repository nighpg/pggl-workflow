#!/usr/bin/env cwl-runner

class: CommandLineTool
id: vg-pack
label: vg-pack (build read support from every lane's GAM)
cwlVersion: v1.1

requirements:
  # Reserve the cores this step actually uses, so `cwltool --parallel` only
  # starts it when they are free instead of oversubscribing the node.
  ResourceRequirement:
    coresMin: $(inputs.threads)
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/vg-pack.sh
        basename: vg-pack.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/vgteam/vg:v1.70.0

baseCommand: [bash, vg-pack.sh]

inputs:
  gbz:
    type: File
    doc: GBZ pangenome graph the alignments were made against

  gams:
    type: File[]?
    doc: Per-lane graph-space GAMs from the giraffe step; empty when call_sv is false, in which case no output is produced. They are concatenated and packed in one pass rather than packed per lane and summed, because vg pack -i segfaults summing packs on a whole-genome graph.

  prefix:
    type: string
    doc: Output file prefix; produces <prefix>.pack

  threads:
    type: int
    doc: Number of threads
    default: 1

arguments:
  - position: 1
    valueFrom: $(inputs.gbz.path)
  - position: 2
    valueFrom: $(inputs.prefix)
  - position: 3
    valueFrom: $(inputs.threads)
  - position: 4
    valueFrom: '$(inputs.gams != null && inputs.gams.length > 0 ? ["--gams"].concat(inputs.gams.map(function(f){ return f.path })) : [])'

outputs:
  pack:
    type: File?
    doc: Sample-wide read support for vg call (null when SV calling is disabled)
    outputBinding:
      glob: $(inputs.prefix).pack
