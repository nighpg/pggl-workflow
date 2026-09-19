#!/usr/bin/env cwl-runner

cwlVersion: v1.1
class: ExpressionTool
id: pick-pack
label: pick-pack
doc: Collect the scattered per-lane vg pack outputs into one flat array, dropping lanes that produced none (call_sv=false). Mirrors pick-gam.cwl.

requirements:
  InlineJavascriptRequirement: {}

inputs:
  pack_in:
    type: Any
    doc: Per-lane optional pack files (scattered output of the giraffe step; may contain nulls)

outputs:
  packs:
    type: File[]?
    doc: Flat array of the kept pack files (empty when call_sv=false)

expression: >-
  $({
    packs: (inputs.pack_in || []).filter(function (f) { return f !== null && f !== undefined; })
  })
