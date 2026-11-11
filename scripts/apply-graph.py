#!/usr/bin/env python3
"""Fill a job file's graph inputs from a graph preset (examples/graphs/<name>.json).

A sample's job file says where its reads are and what to call; the graph a run uses
is a separate choice with eight to ten inputs that must belong together (the giraffe
indexes, the snarls, the reference FASTA and paths, and for haplotype sampling the
clip graph and its .hapl). This script writes them in from one preset, so switching
graph is switching preset.

  apply-graph.py germline PRESET JOB OUT
      JOB with the preset's full graph (and its sv_exclude_bed when the preset
      has one and JOB does not set it).
  apply-graph.py haplotype-sample PRESET JOB OUT [--threads N]
      A Workflows/haplotype-sample.cwl job: JOB's fq1/fq2 and prefix with the
      preset's clip graph and .hapl.
  apply-graph.py personalized PRESET JOB GRAPH_PREFIX OUT
      JOB mapping to a personalized graph (GRAPH_PREFIX.{gbz,dist,min,zipcodes,
      snarls}, as haplotype-sample.cwl writes them) while keeping the preset's
      reference FASTA and paths: sampling keeps the reference paths, so those
      stay the graph release's.

Keys JOB already sets are overwritten for the graph inputs and kept for everything else.
Relative paths in JOB are taken relative to JOB itself, or, when nothing is
there, relative to this checkout, and written out absolute. The templates in
examples/jobs/ name the interval BEDs as interval_files/..., so a copy of one
works from any directory.

Paths in a preset are relative to where the graph releases are installed, given
with --data-root DIR (or $PGGL_DATA): JaSaPaGe_GRCh38/release/... resolves to
DIR/JaSaPaGe_GRCh38/release/.... A relative path missing there is looked up in
this checkout instead, which is where scripts/fetch-giab-repeat-bed.sh puts the
repeat BED (interval_files/). Absolute paths are used as they are.
"""
import argparse, json, os, sys

GRAPH_KEYS = ("gbz", "dist", "min", "zipcodes", "snarls")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def resolve(preset, data_root):
    """Turn the preset's relative File paths into absolute ones."""
    def fix(v):
        if isinstance(v, dict):
            if v.get("class") == "File" and not os.path.isabs(v["path"]):
                cands = ([os.path.join(data_root, v["path"])] if data_root else []) + [os.path.join(REPO, v["path"])]
                found = next((c for c in cands if os.path.exists(c)), None)
                if found is None and not data_root:
                    sys.exit(f"apply-graph.py: {v['path']} is relative to the graph data; "
                             "give --data-root DIR or set PGGL_DATA")
                # the repeat BED lives in the checkout, so that is where to report it missing
                fallback = cands[-1] if v["path"].startswith("interval_files/") else cands[0]
                return dict(v, path=os.path.abspath(found or fallback))
            return {k: fix(x) for k, x in v.items()}
        return v
    return fix(preset)


def absolutize(v, base):
    """Make the job's relative File paths absolute: against the job file's
    directory, else against the checkout."""
    if isinstance(v, list):
        return [absolutize(x, base) for x in v]
    if isinstance(v, dict):
        v = {k: absolutize(x, base) for k, x in v.items()}
        if v.get("class") == "File" and not os.path.isabs(v["path"]):
            here, repo = (os.path.normpath(os.path.join(d, v["path"])) for d in (base, REPO))
            v["path"] = repo if not os.path.exists(here) and os.path.exists(repo) else here
        return v
    return v


def load(path):
    with open(path) as fh:
        return json.load(fh)


def check(job):
    missing = [v["path"] for v in job.values() if isinstance(v, dict) and v.get("class") == "File" and not os.path.exists(v["path"])]
    for p in missing:
        print(f"apply-graph.py: warning: {p} does not exist", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("germline", "haplotype-sample", "personalized"))
    ap.add_argument("preset")
    ap.add_argument("job")
    ap.add_argument("rest", nargs="+", help="OUT, or GRAPH_PREFIX OUT for personalized")
    ap.add_argument("--threads", type=int, help="threads for the haplotype-sample job (default: the job's)")
    ap.add_argument("--data-root", default=os.environ.get("PGGL_DATA"),
                    help="directory the preset's relative paths are under (default: $PGGL_DATA)")
    a = ap.parse_args()
    preset = resolve(load(a.preset), a.data_root)
    job = absolutize(load(a.job), os.path.dirname(os.path.abspath(a.job)))

    if a.mode == "germline":
        (out,) = a.rest
        job.update(preset["germline"])
        if "sv_exclude_bed" in preset:
            job.setdefault("sv_exclude_bed", preset["sv_exclude_bed"])
    elif a.mode == "haplotype-sample":
        (out,) = a.rest
        if "fq1" not in job:
            sys.exit("apply-graph.py: haplotype-sample needs a job with fq1/fq2 (k-mers are counted from FASTQ)")
        job = {k: job[k] for k in ("fq1", "fq2", "prefix") if k in job}
        job.update(preset["haplotype_sample"])
        job["threads"] = a.threads or load(a.job).get("threads", 16)
        job.setdefault("diploid_sampling", True)
        job.setdefault("make_snarls", True)
    else:
        prefix, out = a.rest
        job.update({k: v for k, v in preset["germline"].items() if k not in GRAPH_KEYS})
        job.update({k: {"class": "File", "path": os.path.abspath(f"{prefix}.{k}")} for k in GRAPH_KEYS})
        if "sv_exclude_bed" in preset:
            job.setdefault("sv_exclude_bed", preset["sv_exclude_bed"])
    check(job)
    with open(out, "w") as fh:
        json.dump(job, fh, indent=1)
        fh.write("\n")
    print(f"wrote {out} ({a.mode}, {os.path.basename(a.preset)})")


if __name__ == "__main__":
    main()
