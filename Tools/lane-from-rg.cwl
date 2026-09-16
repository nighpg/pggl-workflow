cwlVersion: v1.1
class: ExpressionTool
id: lane-from-rg
label: lane-from-rg
doc: Extract per-lane IDs from read group strings to name intermediate per-lane outputs.

requirements:
  InlineJavascriptRequirement: {}

inputs:
  rg:
    type: string[]
    doc: Read group string. This option can be used multiple times.

outputs:
  lane_names:
    type: string[]
    doc: Lane ID extracted from each read group string (@RG\tID:...).

expression: >-
  $({
    "lane_names": inputs.rg.map(function (s) {
      var m = String(s).replace(/\\t/g, "\t").match(/@RG\tID:([^\t]+)/);
      return m ? m[1] : "lane";
    })
  })