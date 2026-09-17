#!/usr/bin/env cwl-runner

cwlVersion: v1.1
class: ExpressionTool
id: pick-gam
label: pick-gam
doc: Collect the scattered per-lane GAM outputs into one flat array, dropping lanes that produced none (emit_gam=false).

requirements:
  InlineJavascriptRequirement: {}

inputs:
  gam_in:
    type: Any
    doc: Per-lane optional GAM files (scattered output of vg giraffe; may contain nulls)

outputs:
  gam:
    type: File[]?
    doc: Flat array of the kept GAM files (empty when emit_gam=false)

expression: >-
  $({
    gam: (inputs.gam_in || []).filter(function (f) { return f !== null && f !== undefined; })
  })