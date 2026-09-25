cwlVersion: v1.1
class: ExpressionTool
id: combine-lanes
label: combine-lanes
doc: Concatenate user-provided FASTQ lanes with the CRAM-recovered lane (if any) into one set of arrays for the aligner.

requirements:
  InlineJavascriptRequirement: {}

inputs:
  user_fq1:
    type: File[]?
    doc: FASTQ file 1 per user lane
    default: []

  user_fq2:
    type: File[]?
    doc: FASTQ file 2 per user lane
    default: []

  user_rg:
    type: string[]?
    doc: Read group string per user lane
    default: []

  cram_fq1:
    type: File[]?
    doc: Recovered read-1 FASTQs (CRAM/BAM track), one per read group
    default: []

  cram_fq2:
    type: File[]?
    doc: Recovered read-2 FASTQs (CRAM/BAM track), parallel to cram_fq1
    default: []

  cram_rg:
    type: File?
    doc: File holding the recovered @RG lines, one per line, parallel to cram_fq1

outputs:
  fq1:
    type: File[]
  fq2:
    type: File[]
  rg:
    type: string[]

expression: |
  ${
    // The recovered lanes are numbered <prefix>.cram2fq.<NNNN>.R?.fastq and the
    // rg file lists their @RG lines in that order; sort by name so the pairing
    // does not depend on the glob order of the runner.
    function byName(a, b) { return a.basename < b.basename ? -1 : a.basename > b.basename ? 1 : 0; }
    var cfq1 = (inputs.cram_fq1 || []).slice().sort(byName);
    var cfq2 = (inputs.cram_fq2 || []).slice().sort(byName);
    var crg = inputs.cram_rg
      ? String(inputs.cram_rg.contents || "").split("\n")
          .map(function (l) { return l.replace(/\r$/, ""); })
          .filter(function (l) { return l.trim() !== ""; })
      : [];
    if (cfq1.length !== cfq2.length || cfq1.length !== crg.length) {
      throw "combine-lanes: recovered lanes do not line up (" + cfq1.length + " R1, " +
            cfq2.length + " R2, " + crg.length + " @RG lines)";
    }
    return {
      fq1: (inputs.user_fq1 || []).concat(cfq1),
      fq2: (inputs.user_fq2 || []).concat(cfq2),
      rg: (inputs.user_rg || []).concat(crg)
    };
  }
