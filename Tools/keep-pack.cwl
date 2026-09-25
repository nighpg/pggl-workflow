#!/usr/bin/env cwl-runner

cwlVersion: v1.1
class: ExpressionTool
id: keep-pack
label: keep-pack
doc: |
  Pass the sample-wide vg pack through to the workflow output only when keep is
  true. The pack is always built when call_sv is set, because vg call needs it;
  this only controls whether it survives in the output directory.

  Worth keeping: the pack is the read support in graph space, independent of
  ploidy and of which reference paths are called, so with it (and the graph's
  snarls) vg call can be re-run for a few tens of minutes -- at another ploidy,
  against another reference sample, with other thresholds -- instead of
  re-mapping the sample. Measured on a 30x sample against JaSaPaGe: 3.6 GB to
  keep, against about 9 hours of mapping to rebuild.

requirements:
  InlineJavascriptRequirement: {}

inputs:
  pack_in:
    type: File?
    doc: Sample-wide pack from the vg-pack step; null when call_sv is false

  keep:
    type: boolean
    doc: When false the pack is not exposed as a workflow output

outputs:
  pack:
    type: File?

expression: >-
  $({
    pack: (inputs.keep && inputs.pack_in !== null && inputs.pack_in !== undefined)
            ? inputs.pack_in : null
  })
