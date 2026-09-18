#!/usr/bin/env cwl-runner

class: ExpressionTool
id: autosome-regions
label: Resolve autosome DeepVariant chunks and per-chunk shard counts
cwlVersion: v1.1

requirements:
  InlineJavascriptRequirement: {}

inputs:
  autosome_chunks:
    type:
      - type: array
        items: File
      - "null"
    doc: Optional list of BED files partitioning the autosome (e.g. one per chromosome). Non-HS37 DNA sites (e.g. decoy contigs) that are not in any chunk are dropped. When empty or null, the whole autosome_interval is used as a single chunk.
    default: []

  autosome_interval:
    type: File
    doc: Mandatory autosome BED (autosomes + non-HS37 DNA sites). Always subset to this interval; chunks are only used to slice it into parallel jobs.

  base_shards:
    type: int
    doc: "Total DeepVariant shard budget (CPU: total threads; GPU: number of GPU sessions). It is divided evenly across the chunks."

  prefix:
    type: string
    doc: Output prefix used to derive the per-chunk DeepVariant prefixes

outputs:
  chunks:
    type:
      type: array
      items: File
    doc: BED files to scatter DeepVariant over (chunks if given, else the full autosome_interval)

  prefixes:
    type:
      type: array
      items: string
    doc: Per-chunk output prefixes, parallel to chunks

  shards:
    type:
      type: array
      items: int
    doc: Per-chunk num_shards (base_shards / chunks, at least 1), parallel to chunks

expression: |
  ${
    var ch = (inputs.autosome_chunks && inputs.autosome_chunks.length > 0) ? inputs.autosome_chunks : [inputs.autosome_interval];
    var n = ch.length;
    var base = Math.max(1, inputs.base_shards);
    var sh = Math.max(1, Math.floor(base / n));
    var prefixes = ch.map(function (c, i) { return inputs.prefix + ".autosome.c" + (i + 1); });
    var shards = ch.map(function () { return sh; });
    return { chunks: ch, prefixes: prefixes, shards: shards };
  }