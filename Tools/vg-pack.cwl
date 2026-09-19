#!/usr/bin/env cwl-runner

class: CommandLineTool
id: vg-pack
label: vg-pack (sum per-lane read support)
cwlVersion: v1.1

requirements:
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
    doc: GBZ pangenome graph the packs were built against

  packs:
    type: File[]?
    doc: Per-lane coverage packs from the giraffe step; empty when call_sv is false, in which case no output is produced

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
    valueFrom: '$(inputs.packs != null && inputs.packs.length > 0 ? ["--packs"].concat(inputs.packs.map(function(f){ return f.path })) : [])'

outputs:
  pack:
    type: File?
    doc: Sample-wide read support for vg call (null when SV calling is disabled)
    outputBinding:
      glob: $(inputs.prefix).pack
