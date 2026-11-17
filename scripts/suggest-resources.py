#!/usr/bin/env python3
"""Suggest the cores and memory of each Slurm job from the size of a compute node.

Every job of the workflow has a range of cores and memory it is worth running in
(RANGES below). Given the CPUs and memory of a node, this script divides the node
among the jobs of one kind: it picks how many of them share a node, gives each the
node's cores and memory divided by that number, and keeps the result inside the
range. It prints the options to hand to scripts/run-cohort.sh (after --), or to
run-cohort-nig.sh as environment variables.

The ranges are provisional: where a measurement exists (docs/BENCHMARK-HG002.md,
the lane notes in scripts/submit-slurm.sh) it says so, the others are guesses.
Replace them with what `scripts/run-cohort.sh --report` shows (peak memory, CPU
efficiency) once there are runs.

Usage (also: scripts/run-cohort.sh --suggest ...):
  scripts/suggest-resources.py --node-cpus 128 --node-mem 1000 \\
      [--gpu-node-cpus N --gpu-node-mem G --gpu-node-gpus 4 --gpus 4] \\
      [--pack large|many] [--only options|env]

  --node-cpus, --node-mem    a CPU node: cores, memory in GB
  --gpu-node-cpus/-mem       the GPU node of the calling job (default: the CPU node)
  --gpu-node-gpus N          GPUs in that node (default 4)
  --gpus N                   GPUs the calling job uses (default 4)
  --pack large               as few jobs per node as the ranges' upper ends allow:
                             each job as big as it may be (default)
  --pack many                as many jobs per node as the lower ends allow
  --only options|env         print just the option line, for scripts

The sizes are per kind of job: jobs of different kinds (a sample and some lanes) are
not planned together, so they may share a node or queue for one. This is a starting
point, not a scheduler.
"""
import argparse
import math
import sys

# job: (min cores, max cores, min GB, max GB, basis)
RANGES = {
    "prepare": (8, 32, 32, 64, "guess: samtools decoding the CRAM; so far 32 cores, 64 GB"),
    "run-prepare": (1, 4, 2, 8, "lists the lanes and submits the later jobs; no decoding when the lanes are FASTQs"),
    "sample": (32, 50, 300, 500, "KMC then vg autoindex; autoindex peaks near 300 GB; 128 cores took 41-78 min"),
    "lane": (16, 32, 100, 150, "one vg giraffe holds ~80 GB of index; 94% efficient at 32 threads, 64% at 128"),
    "markdup": (16, 64, 64, 256, "guess"),
    "sv": (16, 64, 64, 256, "guess"),
    "call": (32, 128, 128, 500, "guess; the GPU job of the calling stage, sized to its share of the GPU node"),
}
ORDER = ["prepare", "run-prepare", "sample", "lane", "markdup", "sv", "call"]
# job: (cores option, memory option, cores variable, memory variable)
OPTIONS = {
    "prepare": ("--prepare-threads", "--prepare-mem", "PREP_THREADS", "PREP_MEM"),
    "run-prepare": ("--run-prepare-threads", "--run-prepare-mem", "RUNPREP_THREADS", "RUNPREP_MEM"),
    "sample": ("--sample-threads", "--sample-mem", "SAMPLE_THREADS", "SAMPLE_MEM"),
    "lane": ("--lane-threads", "--lane-mem-per-chunk", "LANE_THREADS", "LANE_MEM"),
    "markdup": ("--markdup-threads", "--markdup-mem", "MARKDUP_THREADS", "MARKDUP_MEM"),
    "sv": ("--sv-threads", "--sv-mem", "SV_THREADS", "SV_MEM"),
    "call": ("--threads", "--call-mem", "CALL_THREADS", "CALL_MEM"),
}


def clamp(x, lo, hi):
    return max(lo, min(x, hi))


def plan(cpus, mem, rng, pack):
    """cores, GB and jobs per node for a job kind that has the node to itself."""
    cmin, cmax, mmin, mmax = rng[:4]
    fit = min(cpus // cmin, mem // mmin)
    if fit < 1:
        return None
    n = fit if pack == "many" else min(max(math.ceil(cpus / cmax), math.ceil(mem / mmax)), fit)
    cores = clamp(cpus // n, cmin, cmax)
    gb = clamp(mem // n, mmin, mmax)
    return cores, gb, min(cpus // cores, mem // gb)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--node-cpus", type=int, required=True)
    ap.add_argument("--node-mem", type=int, required=True)
    ap.add_argument("--gpu-node-cpus", type=int)
    ap.add_argument("--gpu-node-mem", type=int)
    ap.add_argument("--gpu-node-gpus", type=int, default=4)
    ap.add_argument("--gpus", type=int, default=4)
    ap.add_argument("--pack", choices=["large", "many"], default="large")
    ap.add_argument("--only", choices=["options", "env"])
    a = ap.parse_args()
    if min(a.node_cpus, a.node_mem, a.gpu_node_gpus, a.gpus) < 1:
        sys.exit("suggest-resources.py: the node sizes and the GPU counts must be positive")
    if a.gpus > a.gpu_node_gpus:
        sys.exit("suggest-resources.py: --gpus is more than --gpu-node-gpus")
    gcpus = a.gpu_node_cpus or a.node_cpus
    gmem = a.gpu_node_mem or a.node_mem

    rows, notes = [], []
    for job in ORDER:
        rng = RANGES[job]
        if job == "call":
            share = a.gpu_node_gpus // a.gpus
            c_eff, m_eff = gcpus // share, gmem // share
            cores, gb = min(rng[1], c_eff), min(rng[3], m_eff)
            per_node = share
            if cores < rng[0] or gb < rng[2]:
                notes.append(f"call: its share of the GPU node ({c_eff} cores, {m_eff} GB) is below the "
                             f"range ({rng[0]}+ cores, {rng[2]}+ GB)")
        else:
            p = plan(a.node_cpus, a.node_mem, rng, a.pack)
            if p is None:
                notes.append(f"{job}: the node ({a.node_cpus} cores, {a.node_mem} GB) is below the range's "
                             f"lower end ({rng[0]} cores, {rng[2]} GB)")
                continue
            cores, gb, per_node = p
        rows.append((job, rng, cores, gb, per_node))

    opts, env = [], []
    for job, _, cores, gb, _ in rows:
        oc, om, vc, vm = OPTIONS[job]
        opts += [f"{oc} {cores}", f"{om} {gb}"]
        env += [f"{vc}={cores}", f"{vm}={gb}"]

    if a.only == "options":
        print(" ".join(opts))
        return
    if a.only == "env":
        print(" ".join(env))
        return
    print(f"CPU node: {a.node_cpus} cores, {a.node_mem} GB    "
          f"GPU node: {gcpus} cores, {gmem} GB, {a.gpu_node_gpus} GPUs (the calling job uses {a.gpus})    pack: {a.pack}")
    print()
    head = ["job", "range cores", "range GB", "cores", "GB", "per node", "basis"]
    body = [[j, f"{r[0]}-{r[1]}", f"{r[2]}-{r[3]}", str(c), str(g), str(n), r[4]] for j, r, c, g, n in rows]
    width = [max(len(x[i]) for x in [head] + body) for i in range(len(head))]
    for x in [head] + body:
        print("  ".join(v.ljust(w) for v, w in zip(x, width)).rstrip())
    for n in notes:
        print(f"warning: {n}")
    print()
    print("run-cohort.sh options (after --):")
    print("  " + " ".join(opts))
    print("run-cohort-nig.sh environment:")
    print("  " + " ".join(env))
    print()
    print("per node = how many jobs of that kind fit on one node at the same time. Jobs of different\n"
          "kinds are not planned together. The ranges are provisional (see the top of this script).")


if __name__ == "__main__":
    main()
