#!/usr/bin/env python3
"""Split one germline job-order file into the per-stage jobs of the Slurm path.

scripts/submit-slurm.sh runs a germline workflow as three kinds of Slurm job,
one CWL part each, instead of one cwltool process on one node:

  prepare   Workflows/parts/prepare-lanes.cwl   reads -> lanes (1 job)
  lane      Workflows/parts/lane-align.cwl      one lane each  (1 array task per lane)
  call      Workflows/parts/call-<variant>.cwl  markdup, DeepVariant, SV (1 job)

Every stage takes the same job file the single-node workflow would, so this
script only has to keep the keys a part declares as inputs, turn relative paths
into absolute ones (the per-stage jobs live elsewhere), and wire the outputs of
one stage into the inputs of the next.

FASTQ lanes given in the job skip stage 1: they are already lanes, and passing
them through a cwltool run would copy every FASTQ into its output directory.
Only a CRAM/BAM goes through prepare-lanes.cwl, and its lanes are appended to
the FASTQ ones -- the same order as the combine-lanes step of the workflows. The
lane IDs and the sample name of FASTQ lanes are derived here the way
Tools/lane-from-rg.cwl derives them.

Subcommands:
  absolutize JOB OUT                           JOB with every path absolute
  prepare    JOB PART OUT [--threads N]        stage-1 job for the CRAM/BAM; prints
                                               "run", or "skip" when there is none
  lanes      JOB PREPARE_OUT PART LANES_DIR [--set KEY=INT ...]
                                               stage-2 jobs LANES_DIR/NNNN/job.json;
                                               prints the lane count (PREPARE_OUT
                                               may be missing when stage 1 skipped);
                                               --set overrides an input of the lane
                                               jobs only (threads, align_chunks)
  call       JOB PREPARE_OUT LANES_DIR PART OUT
                                               stage-3 job from the lane outputs
  stage-local JOB DIR OUT KEY...               copy the files of KEY... (e.g. the
                                               giraffe indexes) into DIR, reusing a
                                               complete copy already there, and write
                                               JOB with those paths to OUT
"""
import json
import os
import re
import shutil
import sys


def part_inputs(cwl_path):
    """Input ids of a CWL file, read from its top-level `inputs:` block."""
    ids, in_inputs = [], False
    with open(cwl_path) as fh:
        for line in fh:
            if re.match(r"^inputs:\s*$", line):
                in_inputs = True
                continue
            if in_inputs:
                if re.match(r"^\S", line):
                    break
                m = re.match(r"^  ([A-Za-z_][A-Za-z0-9_]*):\s*$", line)
                if m:
                    ids.append(m.group(1))
    if not ids:
        sys.exit(f"slurm-jobs.py: no inputs found in {cwl_path}")
    return ids


def absolutize(obj, base):
    """Make every File/Directory path or location in a job object absolute."""
    if isinstance(obj, list):
        return [absolutize(v, base) for v in obj]
    if isinstance(obj, dict):
        out = {k: absolutize(v, base) for k, v in obj.items()}
        if obj.get("class") in ("File", "Directory"):
            for key in ("path", "location"):
                v = out.get(key)
                if isinstance(v, str) and "://" not in v and not os.path.isabs(v):
                    out[key] = os.path.normpath(os.path.join(base, v))
        return out
    return obj


def load_job(path):
    with open(path) as fh:
        job = json.load(fh)
    return absolutize(job, os.path.dirname(os.path.abspath(path)))


def load(path):
    with open(path) as fh:
        return json.load(fh)


def dump(obj, path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")


def subset(job, keys):
    return {k: v for k, v in job.items() if k in keys}


def lane_id(rg):
    """Tools/lane-from-rg.cwl: the ID of an @RG string (literal \\t accepted)."""
    m = re.search(r"@RG\tID:([^\t]+)", str(rg).replace("\\t", "\t"))
    return m.group(1) if m else "lane"


def sample_of(rgs):
    """Tools/lane-from-rg.cwl: SM of the first read group carrying one."""
    for rg in rgs:
        m = re.search(r"\tSM:([^\t]+)", str(rg).replace("\\t", "\t"))
        if m:
            return m.group(1)
    return "SAMPLE"


def all_lanes(job, prep_out):
    """FASTQ lanes of the job, then the lanes stage 1 recovered from a CRAM/BAM."""
    fq1, fq2, rg = job.get("fq1") or [], job.get("fq2") or [], job.get("rg") or []
    if not (len(fq1) == len(fq2) == len(rg)):
        sys.exit("slurm-jobs.py: fq1, fq2 and rg must have one entry per lane")
    lanes = [dict(fq1=a, fq2=b, rg=r, lane=lane_id(r)) for a, b, r in zip(fq1, fq2, rg)]
    if prep_out and os.path.exists(prep_out):
        p = load(prep_out)
        n = len(p["lane"])
        if not (len(p["fq1"]) == len(p["fq2"]) == len(p["rg"]) == n):
            sys.exit(f"slurm-jobs.py: prepare output does not line up ({prep_out})")
        lanes += [dict(fq1=p["fq1"][i], fq2=p["fq2"][i], rg=p["rg"][i], lane=p["lane"][i])
                  for i in range(n)]
    if not lanes:
        sys.exit("slurm-jobs.py: no lanes: give fq1/fq2/rg or a cram/bam")
    ids = [l["lane"] for l in lanes]
    if len(set(ids)) != len(ids):
        sys.exit(f"slurm-jobs.py: lane IDs are not unique: {ids}")
    return lanes


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, args = argv[1], argv[2:]

    if cmd == "absolutize":
        job, out = args
        dump(load_job(job), out)

    elif cmd == "prepare":
        job, part, out = args[:3]
        j = load_job(job)
        if not (j.get("cram") or j.get("bam")):
            print("skip")
            return
        # FASTQ lanes are handled without stage 1 (see the module doc).
        p = subset(j, set(part_inputs(part)) - {"fq1", "fq2", "rg"})
        if "--threads" in args:
            p["threads"] = int(args[args.index("--threads") + 1])
        dump(p, out)
        print("run")

    elif cmd == "lanes":
        job, prep_out, part, lanes_dir = args[:4]
        j = load_job(job)
        lanes = all_lanes(j, prep_out)
        common = subset(j, set(part_inputs(part)) - {"fq1", "fq2", "rg", "lane"})
        rest = args[4:]
        while rest:
            if rest[0] != "--set" or len(rest) < 2 or "=" not in rest[1]:
                sys.exit(f"slurm-jobs.py lanes: expected --set KEY=INT, got {rest[:2]}")
            k, v = rest[1].split("=", 1)
            if k not in part_inputs(part):
                sys.exit(f"slurm-jobs.py lanes: {k} is not an input of {part}")
            common[k] = int(v)
            rest = rest[2:]
        for i, l in enumerate(lanes):
            lj = dict(common)
            lj.update(l)
            dump(lj, os.path.join(lanes_dir, f"{i + 1:04d}", "job.json"))
        print(len(lanes))

    elif cmd == "call":
        job, prep_out, lanes_dir, part, out = args
        j = load_job(job)
        lanes = all_lanes(j, prep_out)
        outs = []
        for i, l in enumerate(lanes):
            f = os.path.join(lanes_dir, f"{i + 1:04d}", "out.json")
            if not os.path.exists(f):
                sys.exit(f"slurm-jobs.py: lane {i + 1} ({l['lane']}) has no output: {f}")
            outs.append(load(f))
        c = subset(j, part_inputs(part))
        c["sample_name"] = sample_of([l["rg"] for l in lanes])
        c["namecol_bams"] = [o["namecol_bam"] for o in outs]
        c["gams"] = [o.get("gam") for o in outs]
        c["pack_gams"] = [o.get("pack_gam") for o in outs]
        dump(c, out)

    elif cmd == "stage-local":
        # vg memory-maps parts of its indexes, so on Lustre every page fault is
        # a distributed-lock round trip; with several nodes mapping the same
        # files at once those stall the mappers almost completely (measured:
        # 80% idle CPU, threads parked in ldlm_completion_ast, lanes 40x slower).
        # A node-local copy costs one sequential read per lane instead.
        job, dest, out = args[:3]
        j = load_job(job)
        os.makedirs(dest, exist_ok=True)
        for key in args[3:]:
            f = j.get(key)
            if not isinstance(f, dict) or f.get("class") != "File":
                continue
            src = f.get("path") or f["location"].replace("file://", "", 1)
            real = os.path.realpath(src)
            dst = os.path.join(dest, key + "." + os.path.basename(src))
            # A copy is only ever renamed into place once complete, so a file
            # of the right size is a finished copy of this source.
            if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(real):
                how = "reused"
            else:
                shutil.copyfile(real, dst + ".partial")
                os.replace(dst + ".partial", dst)
                how = "copied"
            j[key] = {"class": "File", "path": dst}
            print(f"{how} {key}: {src} -> {dst} ({os.path.getsize(dst) / 2**30:.1f} GiB)", file=sys.stderr)
        dump(j, out)

    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
