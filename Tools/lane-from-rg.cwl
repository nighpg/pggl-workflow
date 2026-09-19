cwlVersion: v1.1
class: ExpressionTool
id: lane-from-rg
label: lane-from-rg
doc: Extract per-lane IDs from read group strings to name intermediate per-lane outputs, and the sample name (SM) used for the SV VCF.

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

  sample_name:
    type: string
    doc: Sample name from the first read group that carries an SM field (falls back to SAMPLE); used as the vg call sample so the SV VCF matches the gVCFs.

expression: >-
  $({
    "lane_names": inputs.rg.map(function (s) {
      var m = String(s).replace(/\\t/g, "\t").match(/@RG\tID:([^\t]+)/);
      return m ? m[1] : "lane";
    }),
    "sample_name": (function () {
      for (var i = 0; i < inputs.rg.length; i++) {
        var m = String(inputs.rg[i]).replace(/\\t/g, "\t").match(/\tSM:([^\t]+)/);
        if (m) { return m[1]; }
      }
      return "SAMPLE";
    })()
  })