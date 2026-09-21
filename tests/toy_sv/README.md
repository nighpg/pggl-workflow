# SV toy fixture

A self-contained fixture for the `call_sv` (SV genotyping) track: the same tiny
reference as `tests/toy/` (chr20 2500 bp, chrX 2000 bp, chrY 1800 bp) with three
structural variants built into the pangenome graph, all heterozygous:

| Site | Type | Length |
| --- | --- | --- |
| chr20:1000 | deletion | 200 bp |
| chr20:1800 | insertion | 150 bp |
| chrX:800 | deletion | 120 bp |

Unlike `tests/toy/`, the graph uses plain contig names (`chr20`), so the job sets
`ref_path_prefix: ""`; the PanSN stripping path is covered by the `tests/toy/`
demo instead.

```bash
cwltool --no-container --outdir tests/toy_sv/demo_out \
  Workflows/germline-pangenome-cpu.cwl tests/toy_sv/jobs/toy_sv_job.json
```

`<prefix>.sv.vcf.gz` must contain exactly the three sites above, each `PASS` and
heterozygous, with the `##contig` block in `toy_sv.ref_paths.txt` order.

`jobs/toy_sv_dict_job.json` is the same run with `ref_paths` given as an HTSlib
sequence dictionary (`ref.dict`) instead of a path list — the form a graph whose
reference is stored as PanSN subranges needs. It must yield the same three sites
and the same `##contig` block:

```bash
cwltool --no-container --outdir tests/toy_sv/demo_out \
  Workflows/germline-pangenome-cpu.cwl tests/toy_sv/jobs/toy_sv_dict_job.json
```

## Rebuilding

`make_fixture.py` writes the phased VCF and simulates the reads (one haplotype
carrying every SV, one reference haplotype, 900 pairs each, 150 bp reads /
400 bp inserts, split over two lanes so the per-lane pack merge is exercised).
`ref.fa`, its `.fai`/`.dict` and the four interval BEDs are copied from
`tests/toy/`.

```bash
python3 tests/toy_sv/make_fixture.py tests/toy_sv
cd tests/toy_sv
bgzip -f -c sv.vcf > sv.vcf.gz && tabix -f -p vcf sv.vcf.gz
vg autoindex --workflow giraffe -r ref.fa -v sv.vcf.gz -p toy_sv -t 4
printf 'chr20\nchrX\nchrY\n' > toy_sv.ref_paths.txt
vg snarls -t 4 toy_sv.giraffe.gbz > toy_sv.snarls
```
