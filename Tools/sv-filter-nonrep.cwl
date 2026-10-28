#!/usr/bin/env cwl-runner

class: CommandLineTool
id: sv-filter-nonrep
label: keep simple graph DEL/INS outside repeats
cwlVersion: v1.1

doc: |
  Writes <name>.nonrep.vcf.gz next to each graph SV VCF it is given: simple
  deletions and insertions the sample carries, PASS, QUAL >= min_qual, whose REF
  span does not overlap exclude_bed (normally GIAB's tandem repeats and
  homopolymers). See scripts/filter-sv-nonrep.sh for the rules and the HG002
  numbers behind them. Without exclude_bed nothing is written, so the step is a
  no-op unless asked for.

requirements:
  InlineJavascriptRequirement: {}
  InitialWorkDirRequirement:
    listing:
      - class: File
        location: ../scripts/filter-sv-nonrep.sh
        basename: filter-sv-nonrep.sh

hints:
  DockerRequirement:
    dockerPull: quay.io/biocontainers/bcftools:1.19--h8b25389_0

baseCommand: [bash, -c]

inputs:
  sv_vcf:
    type: File?
    doc: Autosomes + PAR SV VCF from vg-call-sv
  sv_vcf_chrX_female:
    type: File?
  sv_vcf_chrX_male:
    type: File?
  sv_vcf_chrY:
    type: File?
  exclude_bed:
    type: File?
    doc: Regions to drop (e.g. GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz). Null skips the step.
  min_qual:
    type: float
    default: 30
  max_short_allele:
    type: int
    doc: A record is a simple DEL/INS when its shorter allele (REF or ALT, padding base included) is at most this long
    default: 10
  min_length:
    type: int
    doc: Minimum |ALT - REF|, normally the same as sv_min_length
    default: 50

arguments:
  - valueFrom: |
      ${
        if (inputs.exclude_bed === null) return "true";
        var cmds = [];
        var vcfs = [inputs.sv_vcf, inputs.sv_vcf_chrX_female, inputs.sv_vcf_chrX_male, inputs.sv_vcf_chrY];
        for (var i = 0; i < vcfs.length; i++) {
          var f = vcfs[i];
          if (f === null) continue;
          var out = f.basename.replace(/\.vcf\.gz$/, "") + ".nonrep.vcf.gz";
          cmds.push(["bash", "filter-sv-nonrep.sh", "'" + f.path + "'", "'" + out + "'",
                     "'" + inputs.exclude_bed.path + "'", inputs.min_qual,
                     inputs.max_short_allele, inputs.min_length].join(" "));
        }
        return cmds.length ? "set -euo pipefail; " + cmds.join(" && ") : "true";
      }

outputs:
  nonrep_vcf:
    type: File?
    outputBinding:
      glob: '$(inputs.sv_vcf === null ? "__none__" : inputs.sv_vcf.basename.replace(/\.vcf\.gz$/, "") + ".nonrep.vcf.gz")'
    secondaryFiles:
      - pattern: ".tbi"
  nonrep_vcf_chrX_female:
    type: File?
    outputBinding:
      glob: '$(inputs.sv_vcf_chrX_female === null ? "__none__" : inputs.sv_vcf_chrX_female.basename.replace(/\.vcf\.gz$/, "") + ".nonrep.vcf.gz")'
    secondaryFiles:
      - pattern: ".tbi"
  nonrep_vcf_chrX_male:
    type: File?
    outputBinding:
      glob: '$(inputs.sv_vcf_chrX_male === null ? "__none__" : inputs.sv_vcf_chrX_male.basename.replace(/\.vcf\.gz$/, "") + ".nonrep.vcf.gz")'
    secondaryFiles:
      - pattern: ".tbi"
  nonrep_vcf_chrY:
    type: File?
    outputBinding:
      glob: '$(inputs.sv_vcf_chrY === null ? "__none__" : inputs.sv_vcf_chrY.basename.replace(/\.vcf\.gz$/, "") + ".nonrep.vcf.gz")'
    secondaryFiles:
      - pattern: ".tbi"
