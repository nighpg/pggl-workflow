#!/usr/bin/env python3
"""Progress table and one-page HTML report of a run-cohort.sh cohort.

Every sample's work directory records the Slurm job IDs it submitted in
DIR/jobs.tsv (prepare, sample, submit) and DIR/run/jobs.tsv (lane array,
markdup, sv, call, cleanup). This script reads them all, asks sacct once for
the lot, and shows

  --status        a table with one row per sample: where it is, which steps are
                  done, running, pending or failed, and what it has used so far.
                  wall runs from the first job of the sample that started to its
                  last end (now, if it is not finished), so the wait for other
                  samples is not in it; wait is the part of the wall when none
                  of its jobs was running (jobs waiting in the queue)
  --jobs          every job and array task with its Slurm job ID, state, node,
                  start, elapsed time, CPUs, CPU hours and peak memory
  --html FILE     a single self-contained HTML page (no scripts, no downloads):
                  the cohort summary, the same table, the resources of each step
                  (time, CPU efficiency, peak memory, GPU hours), a timeline of
                  every job, and the failed jobs with where their logs are

Usage (normally through scripts/run-cohort.sh --status / --report):
  scripts/cohort-report.py --workdir-root DIR [--list SAMPLES.tsv] [--status] [--jobs] [--html FILE]

Without --list the samples are the sub-directories of DIR that have a jobs.tsv,
in the order they were submitted. --sacct-file reads saved `sacct -P` output
(with the header line) instead of running sacct.

Each job's TotalCPU and MaxRSS come from sacct, so they need the cluster's job
accounting to record them. Superseded jobs (a step resubmitted with --from)
stay in the resource totals; the table shows the latest job of each step.
"""
import argparse
import html
import os
import re
import subprocess
import sys
from datetime import datetime

FIELDS = ("JobID,JobName,Partition,State,ExitCode,Submit,Start,End,ElapsedRaw,"
          "TotalCPU,AllocCPUS,AllocTRES,ReqMem,MaxRSS,NodeList,ReqCPUS,ReqTRES")
# order of the steps of a sample; run-prepare is submit-slurm.sh's own prepare job
STAGES = ["prepare", "sample", "submit", "run-prepare", "lane", "markdup", "sv", "call", "cleanup"]
SHOWN = ["prepare", "sample", "submit", "lane", "markdup", "sv", "call", "cleanup"]
COLORS = {"prepare": "#8da0cb", "sample": "#66c2a5", "submit": "#bdbdbd", "run-prepare": "#d9d9d9",
          "lane": "#fc8d62", "markdup": "#e78ac3", "sv": "#a6d854", "call": "#ffd92f", "cleanup": "#b3b3b3"}
RUN = {"RUNNING", "COMPLETING", "REQUEUED", "SUSPENDED", "RESIZING", "SIGNALING", "STAGE_OUT"}
PEND = {"PENDING", "CONFIGURING", "REQUEUE_HOLD", "REQUEUE_FED", "RESV_DEL_HOLD", "SPECIAL_EXIT"}


def die(msg):
    sys.exit(f"cohort-report.py: {msg}")


# --- reading the work directories ---------------------------------------------
def read_jobs(w):
    """[(stage, job id)] in the order recorded; None if the sample was never submitted."""
    jobs, found = [], False
    for sub, rename in (("", {}), ("run", {"prepare": "run-prepare"})):
        path = os.path.join(w, sub, "jobs.tsv") if sub else os.path.join(w, "jobs.tsv")
        if not os.path.isfile(path):
            continue
        found = True
        for line in open(path):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2 and p[1].strip().isdigit():
                jobs.append((rename.get(p[0], p[0]), p[1].strip()))
    return jobs if found else None


def read_samples(root, list_file):
    if list_file:
        names = []
        for line in open(list_file):
            f = line.split("\t")[0].strip()
            if f and not f.startswith("#"):
                names.append(f)
        return names
    found = []
    for d in sorted(os.listdir(root)):
        j = read_jobs(os.path.join(root, d)) if os.path.isdir(os.path.join(root, d)) else None
        if j:
            found.append((min(int(i) for _, i in j), d))
    return [d for _, d in sorted(found)]


# --- sacct --------------------------------------------------------------------
def run_sacct(ids, sacct_file):
    if sacct_file:
        text = open(sacct_file).read()
    else:
        try:
            text = subprocess.run(["sacct", "-j", ",".join(ids), "-P", "--format=" + FIELDS],
                                  check=True, capture_output=True, text=True).stdout
        except FileNotFoundError:
            die("sacct not found (run this where Slurm is available, or give --sacct-file)")
        except subprocess.CalledProcessError as e:
            die(f"sacct failed: {e.stderr.strip()}")
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return []
    head = lines[0].split("|")
    return [dict(zip(head, l.split("|"))) for l in lines[1:]]


def parse_time(s):
    try:
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def parse_cpu(s):
    if not s:
        return 0.0
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    sec = 0.0
    for p in s.split(":"):
        sec = sec * 60 + float(p)
    return days * 86400 + sec


UNITS = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def parse_bytes(s):
    m = re.match(r"([\d.]+)\s*([KMGT])?", s or "")
    return float(m.group(1)) * UNITS.get(m.group(2), 1) if m else 0.0


def tres(s, key):
    m = re.search(r"(?:^|,)" + re.escape(key) + r"=([^,]+)", s or "")
    return m.group(1) if m else ""


def state_class(state):
    s = (state or "").split()[0].rstrip("+") if state else ""
    if s == "COMPLETED":
        return "ok"
    if s == "CANCELLED":
        return "cancel"
    if s in RUN:
        return "run"
    if s in PEND:
        return "pend"
    return "fail" if s else "unk"


def array_size(job_id):
    """tasks of a pending array row like 123_[4-20%3] or 123_[1,3,5]."""
    m = re.search(r"_\[([^\]%]+)", job_id)
    if not m:
        return 1
    n = 0
    for part in m.group(1).split(","):
        a, _, b = part.partition("-")
        n += int(b) - int(a) + 1 if b else 1
    return n


def collect(rows, now):
    """sacct rows -> {base job id: job}, a job being its tasks (an array has many)."""
    jobs = {}
    for r in rows:
        jid = r.get("JobID", "")
        m = re.match(r"(\d+)", jid)
        if not m:
            continue
        j = jobs.setdefault(m.group(1), {"tasks": [], "steps": [], "pending_extra": 0})
        if "." in jid:
            j["steps"].append(r)
        elif "[" in jid:
            j["pending_extra"] += array_size(jid)
            j["name"] = r.get("JobName", "")
            j["partition"] = r.get("Partition", "")
        else:
            j["tasks"].append(r)
    for base, j in jobs.items():
        out = []
        for r in j["tasks"]:
            el = float(r.get("ElapsedRaw") or 0)
            start, end = parse_time(r.get("Start")), parse_time(r.get("End"))
            cls = state_class(r.get("State"))
            if cls == "run" and start and not end:
                el = max(el, (now - start).total_seconds())
            # a job that has not started has no allocation yet: use what it requested (ReqCPUS, ReqTRES)
            ncpu = int(r.get("AllocCPUS") or 0) or int(r.get("ReqCPUS") or 0)
            ngpu = 0
            g = tres(r.get("AllocTRES"), "gres/gpu") or tres(r.get("ReqTRES"), "gres/gpu")
            if g.isdigit():
                ngpu = int(g)
            mem = parse_bytes(tres(r.get("AllocTRES"), "mem") or tres(r.get("ReqTRES"), "mem"))
            if not mem:  # ReqMem: 4Gc is per CPU, 150Gn (or no letter) per node
                m = re.match(r"([\d.]+)([KMGT]?)([nc]?)", r.get("ReqMem", "") or "")
                if m:
                    mem = float(m.group(1)) * UNITS.get(m.group(2), 1) * (ncpu if m.group(3) == "c" else 1)
            prefix = r["JobID"] + "."
            rss = max([parse_bytes(s["MaxRSS"]) for s in j["steps"] if s["JobID"].startswith(prefix)] or [0])
            out.append({"id": r["JobID"], "name": r.get("JobName", ""), "state": r.get("State", ""),
                        "cls": cls, "exit": r.get("ExitCode", ""), "partition": r.get("Partition", ""),
                        "submit": parse_time(r.get("Submit")), "start": start, "end": end,
                        "elapsed": el, "cpu": parse_cpu(r.get("TotalCPU")), "ncpu": ncpu, "ngpu": ngpu,
                        "mem": mem, "rss": rss, "node": r.get("NodeList", "")})
        j["t"] = out
    return jobs


def job_summary(j):
    """one state for a job: the worst of its tasks, and 'done/total' for arrays."""
    ts = j["t"]
    total = len(ts) + j["pending_extra"]
    ok = sum(t["cls"] == "ok" for t in ts)
    classes = {t["cls"] for t in ts}
    if "fail" in classes:
        cls = "fail"
    elif "run" in classes:
        cls = "run"
    elif "cancel" in classes:
        cls = "cancel"
    elif ok and ok < total:
        cls = "run"
    elif j["pending_extra"] or "pend" in classes:
        cls = "pend"
    elif ts and classes == {"ok"}:
        cls = "ok"
    else:
        cls = "unk"
    return cls, ok, total


# --- per sample ---------------------------------------------------------------
# which steps a step waits for; when one of them was submitted again later (a resume), the
# jobs recorded for the step before that belong to an older attempt and are not its state
PARENTS = {"prepare": [], "sample": ["prepare"], "submit": ["sample"], "run-prepare": ["submit"],
           "lane": ["run-prepare"], "markdup": ["lane"], "sv": ["lane"], "call": ["markdup", "lane"],
           "cleanup": ["call", "sv"]}


def ancestors(stage):
    seen, todo = set(), list(PARENTS.get(stage, []))
    while todo:
        a = todo.pop()
        if a not in seen:
            seen.add(a)
            todo += PARENTS.get(a, [])
    return seen


def current_records(recorded):
    """{step: job ID}: the newest job of each step that no later job of a step before it has replaced.
    Slurm job IDs grow with time, so the larger ID is the later submission."""
    latest = {}
    for stage, jid in recorded:
        if stage not in latest or int(jid) > int(latest[stage]):
            latest[stage] = jid
    return {st: jid for st, jid in latest.items()
            if not any(a in latest and int(latest[a]) > int(jid) for a in ancestors(st))}


def analyse(root, names, jobs, now):
    samples = []
    for i, name in enumerate(names, 1):
        w = os.path.join(root, name)
        recorded = read_jobs(w) if os.path.isdir(w) else None
        s = {"n": i, "name": name, "dir": w, "recorded": recorded, "stages": {}, "all": []}
        if recorded is None:
            s.update(state="not submitted", current="", flag="none")
            samples.append(s)
            continue
        current = current_records(recorded)
        for stage, jid in recorded:
            j = jobs.get(jid)
            if j and j["t"]:
                s["all"].append((stage, jid, j))  # every attempt counts in the resource totals
            if current.get(stage) == jid:
                s["stages"][stage] = (jid, j)
        first_fail = None
        # run-prepare (the stage-1 job of submit-slurm.sh) is not a column, but it submits markdup,
        # sv, call and cleanup: when it fails they are never submitted
        for st in STAGES:
            if st in s["stages"]:
                jid, j = s["stages"][st]
                summ = job_summary(j) if j and j["t"] else ("unk", 0, 0)
                s["stages"][st] = (jid, j) + summ
        for st in STAGES:
            if st in s["stages"] and s["stages"][st][2] == "fail":
                first_fail = st
                break
        running = [st for st in STAGES if st in s["stages"] and s["stages"][st][2] == "run"]
        pending = [st for st in STAGES if st in s["stages"] and s["stages"][st][2] == "pend"]
        cancelled = [st for st in STAGES if st in s["stages"] and s["stages"][st][2] == "cancel"]
        have_call = "call" in s["stages"]
        all_ok = all(v[2] == "ok" for v in s["stages"].values())
        run_prepare_only_failure = (
            first_fail == "run-prepare" and have_call
            and all(v[2] == "ok" for st, v in s["stages"].items() if st != "run-prepare")
        )
        label = lambda names: ", ".join(f"{st} {s['stages'][st][0]}" for st in names)
        if not any(v[2] != "unk" for v in s["stages"].values()):
            s.update(state="UNKNOWN", current="no sacct data for the jobs " + ",".join(j for _, j in recorded), flag="unk")
        elif first_fail and not run_prepare_only_failure:
            s.update(state="FAILED", current=label([first_fail]), flag="fail")
        elif running:
            s.update(state="RUNNING", current=label(running), flag="run")
        elif cancelled:
            s.update(state="CANCELLED", current=label(cancelled) + " (--resume runs it again)", flag="cancel")
        elif pending:
            s.update(state="PENDING", current=label(pending), flag="pend")
        elif (all_ok or run_prepare_only_failure) and have_call:
            current = ""
            if run_prepare_only_failure:
                failed_id = s["stages"]["run-prepare"][0]
                current = f"run-prepare {failed_id} failed; outputs complete"
                first_fail = None
            # run-prepare submits the later jobs; its own failure does not invalidate
            # completed outputs when every recorded downstream job succeeded.
            s.update(state="DONE", current=current, flag="ok")
        else:
            # everything that was submitted has ended, but the call job never was
            rp = s["stages"].get("run-prepare", (None,))[0]
            s.update(state="STALLED", flag="fail",
                     current="call was not submitted" + (f"; see run/logs/prepare.{rp}.err" if rp else ""))
        s["first_fail"] = first_fail
        s["first_cancel"] = cancelled[0] if cancelled else None
        starts = [t["start"] for _, _, j in s["all"] for t in j["t"] if t["start"]]
        ends = [t["end"] for _, _, j in s["all"] for t in j["t"] if t["end"]]
        s["t0"] = min(starts) if starts else None  # the first job to start, not the first submitted
        # a finished or failed sample stops at its last end; jobs left pending behind a failure do not count
        finished = s["flag"] in ("ok", "fail", "cancel") and ends
        s["t1"] = max(ends) if finished else (now if s["t0"] else None)
        s["wall"] = (s["t1"] - s["t0"]).total_seconds() if s["t0"] and s["t1"] else 0
        # time inside the wall when none of the sample's jobs was running: jobs waiting in the queue
        spans = sorted((t["start"], t["end"] or now) for _, _, j in s["all"] for t in j["t"] if t["start"])
        busy, cur_end = 0.0, None
        for a, b in spans:
            if cur_end is None or a > cur_end:
                busy += (b - a).total_seconds()
                cur_end = b
            elif b > cur_end:
                busy += (b - cur_end).total_seconds()
                cur_end = b
        s["wait"] = max(s["wall"] - busy, 0) if s["wall"] else 0
        s["cpu_s"] = sum(t["cpu"] for _, _, j in s["all"] for t in j["t"])
        s["gpu_s"] = sum(t["ngpu"] * t["elapsed"] for _, _, j in s["all"] for t in j["t"])
        samples.append(s)
    return samples


def log_files(s, st, jid):
    """where the output of a job goes (see the --output/--error of the sbatch calls)."""
    top = {"prepare": "logs/1-prepare.%s.err", "sample": "logs/2-sample.%s.err", "submit": "logs/3-submit.%s.err"}
    if st in top:
        return os.path.join(s["dir"], top[st] % jid)
    if st == "lane":
        return os.path.join(s["dir"], f"run/logs/lane-*.{jid}.err")
    name = "prepare" if st == "run-prepare" else st
    return os.path.join(s["dir"], f"run/logs/{name}.{jid}.err")


def cell(s, st):
    v = s["stages"].get(st)
    if s["recorded"] is None or v is None:
        block = s.get("first_fail") or s.get("first_cancel")
        if s["recorded"] is not None and block and STAGES.index(st) > STAGES.index(block):
            return "blk", "blocked"
        return "none", "-"
    jid, j, cls, ok, total = v
    block = s.get("first_fail") or s.get("first_cancel")
    if cls == "pend" and block and STAGES.index(block) < STAGES.index(st):
        return "blk", "blocked"
    word = {"ok": "OK", "run": "RUN", "pend": "PEND", "fail": "FAIL", "cancel": "CANCEL", "unk": "?"}[cls]
    if total > 1:
        word += f" {ok}/{total}"
    return cls, word


def dur(sec):
    sec = int(sec)
    d, r = divmod(sec, 86400)
    h, r = divmod(r, 3600)
    m = r // 60
    return (f"{d}d " if d else "") + f"{h}h{m:02d}m"


def ranges(nums):
    out, nums = [], sorted(nums)
    while nums:
        a = b = nums.pop(0)
        while nums and nums[0] == b + 1:
            b = nums.pop(0)
        out.append(f"#{a}" if a == b else f"#{a}-{b}")
    return ",".join(out)


def summary_line(samples):
    by = {}
    for s in samples:
        by.setdefault(s["flag"], []).append(s)
    parts = []
    if by.get("ok"):
        parts.append("done: " + ranges([s["n"] for s in by["ok"]]))
    prog = by.get("run", []) + by.get("pend", [])
    if prog:
        parts.append("in progress: " + ", ".join(
            f"#{s['n']} {s['current']} ({s['state']})" for s in sorted(prog, key=lambda s: s["n"])))
    if by.get("fail"):
        parts.append("failed: " + ", ".join(f"#{s['n']} {s['current']}" for s in by["fail"]))
    if by.get("cancel"):
        parts.append("cancelled (--resume runs them again): " + ", ".join(f"#{s['n']} {s['current'].split(' (')[0]}" for s in by["cancel"]))
    if by.get("unk"):
        parts.append("no sacct data: " + ranges([s["n"] for s in by["unk"]]))
    if by.get("none"):
        parts.append("not submitted: " + ranges([s["n"] for s in by["none"]]))
    return " | ".join(parts)


def counts_line(samples):
    c = {}
    for s in samples:
        c[s["state"]] = c.get(s["state"], 0) + 1
    return f"{len(samples)} samples: " + ", ".join(f"{v} {k}" for k, v in c.items())


def cpu_pct(cpu, alloc):
    """CPU efficiency: the CPU time used over the CPU time allocated (cores x elapsed)."""
    return f"{100 * cpu / alloc:.0f}%" if cpu > 0 and alloc > 0 else "-"


def cores_of(ncpus):
    """'32' for one value, '1-32' for a range, '-' when none is known."""
    ns = sorted(n for n in ncpus if n)
    return "-" if not ns else str(ns[0]) if ns[0] == ns[-1] else f"{ns[0]}-{ns[-1]}"


def resource_cell(s, st):
    """'cores cpu% maxmem/allocatedG #jobid' of the current job of a step of a sample: a job that has not started
    shows what it requested; '-' where there is no accounting data."""
    v = s["stages"].get(st)
    if not v:
        return "-"
    jid = f" #{v[0]}"  # the Slurm job ID (of the array, for the lanes)
    if not v[1] or not v[1]["t"]:
        return "-" + jid
    ts = v[1]["t"]
    started = [t for t in ts if t["start"]]
    eff = cpu_pct(sum(t["cpu"] for t in started), sum(t["ncpu"] * t["elapsed"] for t in started))
    rss = max([t["rss"] for t in started] or [0])
    cores = cores_of({t["ncpu"] for t in ts})
    mem = max([t["mem"] for t in ts] or [0])
    if cores == "-":
        return "-" + jid
    used = f"{rss / (1 << 30):.0f}" if rss else "-"
    return (f"{cores}c {eff} {used}/{mem / (1 << 30):.0f}G" if mem else f"{cores}c {eff} {used}G") + jid


def print_table(head, rows):
    width = [max(len(r[i]) for r in [head] + rows) for i in range(len(head))]
    for r in [head] + rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, width)).rstrip())


def print_resources(samples):
    stats = stage_stats(samples)
    if not stats:
        return
    print("\nresources by step (the current job of each step; a job not started yet shows its request):")
    rows = []
    for st in STAGES:
        d = stats.get(st)
        if not d:
            continue
        mem_pct = f"{100 * d['rss'] / d['mem']:.0f}%" if d["rss"] and d["mem"] else "-"
        rows.append([st, str(d["n"]), cores_of(d["ncpu"]), cpu_pct(d["cpu"], d["alloc"]), gib(d["rss"]), gib(d["mem"]),
                     mem_pct, dur(sum(d["el"]) / len(d["el"])) if d["el"] else "-", dur(max(d["el"])) if d["el"] else "-"])
    print_table(["step", "tasks", "cpus", "cpu%", "max-mem GiB", "alloc GiB", "mem%", "mean elapsed", "max elapsed"], rows)
    print("\nper sample: allocated cores (c), cpu%, max memory / allocated memory, and the Slurm job ID (#) of the current job of each step:")
    print_table(["#", "sample"] + SHOWN,
                [[str(s["n"]), s["name"]] + [resource_cell(s, st) for st in SHOWN] for s in samples])
    print("cpus = the CPUs allocated to a task (AllocCPUS); cpu% = TotalCPU / (allocated CPUs x elapsed); max memory = the largest MaxRSS of the job's tasks. "
          "'-' = not recorded (the job has not started, or the cluster's accounting does not keep it)")


def print_status(samples):
    head = ["#", "sample", "state", "now"] + SHOWN + ["wall", "wait", "cpu-h"]
    rows = []
    for s in samples:
        rows.append([str(s["n"]), s["name"], s["state"], s["current"]]
                    + [cell(s, st)[1] for st in SHOWN]
                    + [dur(s["wall"]) if s.get("wall") else "-",
                       dur(s["wait"]) if s.get("wall") else "-",
                       f"{s['cpu_s'] / 3600:.1f}" if s.get("cpu_s") else "-"])
    width = [max(len(r[i]) for r in [head] + rows) for i in range(len(head))]
    for r in [head] + rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, width)).rstrip())
    print()
    print(counts_line(samples))
    print(summary_line(samples))
    failed = [s for s in samples if s["flag"] == "fail"]
    if failed:
        print("\nlogs of the failed jobs:")
        for s in failed:
            st = s.get("first_fail")
            if st:
                print(f"  #{s['n']} {s['name']}: {log_files(s, st, s['stages'][st][0])}")
            else:
                rp = s["stages"].get("run-prepare")
                if rp:
                    print(f"  #{s['n']} {s['name']}: {log_files(s, 'run-prepare', rp[0])}")
    print("wall: from the first job that started to the last end (now, if not finished); "
          "wait: the part of it when none of the sample's jobs was running")
    print_resources(samples)


def print_jobs(samples):
    """every job and array task of every sample, with its Slurm job ID."""
    head = ["sample", "step", "jobid", "state", "partition", "node", "start", "elapsed", "cpus", "cpu-h", "max-mem-GiB"]
    rows = []
    for s in samples:
        for st, _, j in s["all"]:
            for t in j["t"]:
                rows.append([s["name"], st, t["id"], t["state"].split()[0] if t["state"] else "?",
                             t["partition"], t["node"], f"{t['start']:%m-%d %H:%M}" if t["start"] else "-",
                             dur(t["elapsed"]) if t["start"] else "-", str(t["ncpu"]) if t["ncpu"] else "-",
                             f"{t['cpu'] / 3600:.1f}", gib(t["rss"])])
        # jobs that sacct does not list (no accounting yet, or purged)
        listed = {jid for _, jid, _ in s["all"]}
        for st, jid in (read_jobs(s["dir"]) or []):
            if jid not in listed:
                rows.append([s["name"], st, jid, "?", "-", "-", "-", "-", "-", "-", "-"])
    width = [max(len(r[i]) for r in [head] + rows) for i in range(len(head))]
    for r in [head] + rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, width)).rstrip())


# --- the HTML page ------------------------------------------------------------
CSS = """
small{color:#666;font-size:11px}
body{font:14px/1.45 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;margin:24px;color:#222;max-width:1250px}
h1{margin:0 0 4px}h2{margin:28px 0 8px;border-bottom:1px solid #ddd;padding-bottom:3px}
.sub{color:#666;margin-bottom:14px}
.cards{display:flex;flex-wrap:wrap;gap:10px}
.card{border:1px solid #ddd;border-radius:6px;padding:8px 14px;min-width:120px}
.card b{display:block;font-size:20px}.card span{color:#666;font-size:12px}
table{border-collapse:collapse;margin:6px 0}
td,th{border:1px solid #ddd;padding:3px 8px;text-align:left;white-space:nowrap}
th{background:#f4f4f4}td.r{text-align:right}
td.ok{background:#d9f2d9}td.run{background:#cfe3ff}td.pend{background:#fff2c2}
td.cancel{background:#ffe0b3}td.fail{background:#ffcccc;font-weight:bold}td.blk,td.unk{background:#e8e8e8;color:#777}td.none{color:#aaa}
.legend span{display:inline-block;margin-right:12px}
.legend i{display:inline-block;width:12px;height:12px;vertical-align:-1px;margin-right:4px}
code{background:#f4f4f4;padding:0 3px}
"""


def e(x):
    return html.escape(str(x))


def stage_stats(samples):
    """per step, over the current job of the step in every sample (an older attempt that a resume
    replaced is left out, so a changed setting shows at once); a job not started yet only gives its request."""
    stats = {}
    for s in samples:
        for stage, v in s["stages"].items():
            j = v[1]
            if not j:
                continue
            for t in j["t"]:
                d = stats.setdefault(stage, {"n": 0, "el": [], "cpu": 0.0, "alloc": 0.0, "gpu": 0.0, "rss": 0.0,
                                             "mem": 0.0, "fail": 0, "ncpu": set()})
                d["ncpu"].add(t["ncpu"])
                d["mem"] = max(d["mem"], t["mem"])
                if t["cls"] == "pend":
                    continue
                d["n"] += 1
                d["el"].append(t["elapsed"])
                d["cpu"] += t["cpu"]
                d["alloc"] += t["ncpu"] * t["elapsed"]
                d["gpu"] += t["ngpu"] * t["elapsed"]
                d["rss"] = max(d["rss"], t["rss"])
                d["fail"] += t["cls"] == "fail"
    return stats


def gib(b):
    return f"{b / (1 << 30):.1f}" if b else "-"


def timeline(samples, now):
    items = [(s, st, jid, t) for s in samples for st, jid, j in s["all"] for t in j["t"] if t["submit"]]
    if not items:
        return "<p>no jobs yet</p>"
    t0 = min(t["submit"] for *_, t in items)
    t1 = max([t["end"] or now for *_, t in items])
    span = max((t1 - t0).total_seconds(), 1)
    left, width, row = 130, 1000, 16
    x = lambda dt: left + (dt - t0).total_seconds() / span * width
    h = row * len(samples) + 34
    out = [f'<svg width="{left + width + 20}" height="{h}" font-size="11" font-family="sans-serif">']
    for k in range(6):
        gx = left + width * k / 5
        label = dur(span * k / 5)
        out.append(f'<line x1="{gx:.0f}" y1="0" x2="{gx:.0f}" y2="{h - 22}" stroke="#eee"/>'
                   f'<text x="{gx:.0f}" y="{h - 8}" text-anchor="middle" fill="#666">+{label}</text>')
    for i, s in enumerate(samples):
        y = i * row
        out.append(f'<text x="{left - 6}" y="{y + 12}" text-anchor="end">#{s["n"]} {e(s["name"][:16])}</text>')
        for st, jid, j in s["all"]:
            for t in j["t"]:
                if not t["submit"]:
                    continue
                run_from = t["start"] or now
                if run_from > t["submit"]:  # time in the queue
                    out.append(f'<rect x="{x(t["submit"]):.1f}" y="{y + 7}" width="{max(x(run_from) - x(t["submit"]), 0.5):.1f}" '
                               f'height="2" fill="#bbb"/>')
                if t["start"]:
                    end = t["end"] or now
                    tip = f'{st} {t["id"]} {t["state"]}  {dur(t["elapsed"])}'
                    out.append(f'<rect x="{x(t["start"]):.1f}" y="{y + 2}" width="{max(x(end) - x(t["start"]), 1):.1f}" '
                               f'height="{row - 5}" fill="{COLORS.get(st, "#999")}" fill-opacity="0.85"'
                               f'{" stroke=#d00 stroke-width=1.5" if t["cls"] == "fail" else ""}><title>{e(tip)}</title></rect>')
    out.append("</svg>")
    legend = "".join(f'<span><i style="background:{COLORS[s]}"></i>{s}</span>' for s in SHOWN)
    return f'<div class="legend">{legend}<span><i style="background:#bbb;height:2px;vertical-align:4px"></i>queued</span></div>' + "".join(out)


def write_html(path, root, samples, now):
    stats = stage_stats(samples)
    jobs_all = [(s, st, jid, t) for s in samples for st, jid, j in s["all"] for t in j["t"]]
    wall = sum(s.get("wall", 0) for s in samples)
    cpu = sum(s.get("cpu_s", 0) for s in samples)
    gpu = sum(s.get("gpu_s", 0) for s in samples)
    t0s = [s["t0"] for s in samples if s.get("t0")]
    t1s = [s["t1"] for s in samples if s.get("t1")]
    span = (max(t1s) - min(t0s)).total_seconds() if t0s and t1s else 0
    ndone = sum(s["flag"] == "ok" for s in samples)
    cards = [(f"{ndone}/{len(samples)}", "samples done"),
             (str(sum(s["flag"] == "fail" for s in samples)), "failed"),
             (str(sum(s["flag"] in ("run", "pend") for s in samples)), "in progress"),
             (dur(span), "cohort wall time"),
             (f"{cpu / 3600:.0f}", "CPU hours used"),
             (f"{gpu / 3600:.1f}", "GPU hours"),
             (gib(max([t["rss"] for *_, t in jobs_all] or [0])) + " GiB", "peak memory of a job"),
             (str(len(jobs_all)), "Slurm jobs and array tasks")]
    o = ["<!DOCTYPE html><html><head><meta charset=utf-8><title>Cohort report</title>",
         f"<style>{CSS}</style></head><body>",
         "<h1>Cohort report</h1>",
         f'<div class="sub">{e(root)} &middot; generated {now:%Y-%m-%d %H:%M:%S} &middot; {e(counts_line(samples))}</div>',
         '<div class="cards">' + "".join(f"<div class=card><b>{e(a)}</b><span>{e(b)}</span></div>" for a, b in cards) + "</div>",
         f"<p>{e(summary_line(samples))}</p>",
         "<h2>Progress</h2><table><tr><th>#<th>sample<th>state<th>now" + "".join(f"<th>{st}" for st in SHOWN)
         + "<th>wall<th>wait<th>CPU h<th>GPU h"]
    for s in samples:
        cells = "".join(
            f'<td class="{c}">{e(txt)}' + (f' <small>{e(s["stages"][st][0])}</small>' if st in s["stages"] else "")
            for st, (c, txt) in ((st, cell(s, st)) for st in SHOWN))
        cls = {"ok": "ok", "run": "run", "pend": "pend", "fail": "fail", "cancel": "cancel", "unk": "unk"}.get(s["flag"], "none")
        wall = dur(s["wall"]) if s.get("wall") else "-"
        wait = dur(s["wait"]) if s.get("wall") else "-"
        cpuh = f'{s["cpu_s"] / 3600:.1f}' if s.get("cpu_s") else "-"
        gpuh = f'{s["gpu_s"] / 3600:.1f}' if s.get("gpu_s") else "-"
        o.append(f'<tr><td class=r>{s["n"]}<td>{e(s["name"])}<td class="{cls}">{e(s["state"])}<td>{e(s["current"])}'
                 f'{cells}<td class=r>{wall}<td class=r>{wait}<td class=r>{cpuh}<td class=r>{gpuh}')
    o.append("</table>")
    o.append("<h2>CPU and memory per sample</h2><p class=sub>Allocated cores (c), cpu%, the largest MaxRSS / "
             "the memory allocated, and the Slurm job ID (#), of the current job of each step (a job not started yet: "
             "what it requested).</p><table><tr><th>#<th>sample" + "".join(f"<th>{st}" for st in SHOWN))
    for s in samples:
        o.append(f'<tr><td class=r>{s["n"]}<td>{e(s["name"])}'
                 + "".join(f"<td class=r>{e(resource_cell(s, st))}" for st in SHOWN))
    o.append("</table>")
    o.append("<h2>Resources by step</h2><p class=sub>The current job of each step of each sample (an older attempt "
             "that a resume replaced is left out; a job that has not started shows what it requested). CPU efficiency = TotalCPU / (allocated CPUs &times; elapsed); memory is the largest MaxRSS "
             "of the step against the largest allocation.</p>"
             "<table><tr><th>step<th>jobs / tasks<th>failed<th>CPUs<th>mean elapsed<th>max elapsed<th>CPU h<th>CPU efficiency"
             "<th>peak mem GiB<th>allocated GiB<th>GPU h")
    for st in STAGES:
        d = stats.get(st)
        if not d:
            continue
        eff = f"{100 * d['cpu'] / d['alloc']:.0f}%" if d["alloc"] else "-"
        o.append(f"<tr><td>{st}<td class=r>{d['n']}<td class=r>{d['fail'] or ''}<td class=r>{cores_of(d['ncpu'])}"
                 f"<td class=r>{dur(sum(d['el']) / len(d['el'])) if d['el'] else '-'}"
                 f"<td class=r>{dur(max(d['el'])) if d['el'] else '-'}<td class=r>{d['cpu'] / 3600:.1f}<td class=r>{eff}"
                 f"<td class=r>{gib(d['rss'])}<td class=r>{gib(d['mem'])}<td class=r>{d['gpu'] / 3600:.1f}")
    o.append("</table>")
    o.append("<h2>Timeline</h2><p class=sub>One row per sample, from the first submission to now; "
             "hover a bar for the job. Failed jobs have a red outline.</p>" + timeline(samples, now))
    fails = [(s, st, jid, t) for s, st, jid, t in jobs_all if t["cls"] == "fail"]
    o.append(f"<h2>Failed jobs ({len(fails)})</h2>")
    if fails:
        o.append("<table><tr><th>sample<th>step<th>job<th>state<th>exit<th>node<th>logs")
        for s, st, jid, t in fails:
            logs = log_files(s, st, jid)
            o.append(f"<tr><td>{e(s['name'])}<td>{st}<td>{e(t['id'])}<td class=fail>{e(t['state'])}<td>{e(t['exit'])}"
                     f"<td>{e(t['node'])}<td><code>{e(logs)}</code>")
        o.append("</table>")
    else:
        o.append("<p>none</p>")
    stalled = [s for s in samples if s["state"] == "STALLED"]
    if stalled:
        o.append("<p>Stalled (no job is running or waiting, and the call job was never submitted): "
                 + "; ".join(f"#{s['n']} {e(s['name'])}: {e(s['current'])}" for s in stalled) + "</p>")
    o.append("<h2>All jobs</h2><details><summary>show</summary><table><tr><th>sample<th>step<th>job<th>state<th>partition"
             "<th>node<th>submitted<th>started<th>elapsed<th>CPUs<th>CPU h<th>peak mem GiB")
    for s, st, jid, t in jobs_all:
        o.append(f"<tr><td>{e(s['name'])}<td>{st}<td>{e(t['id'])}<td class={t['cls']}>{e(t['state'])}<td>{e(t['partition'])}"
                 f"<td>{e(t['node'])}<td>{t['submit'] or ''}<td>{t['start'] or ''}<td class=r>{dur(t['elapsed'])}"
                 f"<td class=r>{t['ncpu']}<td class=r>{t['cpu'] / 3600:.2f}<td class=r>{gib(t['rss'])}")
    o.append("</table></details></body></html>")
    with open(path, "w") as f:
        f.write("\n".join(o))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--workdir-root", required=True)
    ap.add_argument("--list")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--jobs", action="store_true", help="list every job with its Slurm job ID")
    ap.add_argument("--html")
    ap.add_argument("--sacct-file")
    ap.add_argument("--now", help="current time (ISO), for tests")
    a = ap.parse_args()
    if not os.path.isdir(a.workdir_root):
        die(f"{a.workdir_root} is not a directory")
    now = parse_time(a.now) if a.now else datetime.now()
    names = read_samples(a.workdir_root, a.list)
    if not names:
        die("no samples (give --list, or --workdir-root with sample directories that have a jobs.tsv)")
    ids = []
    for n in names:
        for _, jid in (read_jobs(os.path.join(a.workdir_root, n)) or []):
            if jid not in ids:
                ids.append(jid)
    jobs = collect(run_sacct(ids, a.sacct_file), now) if ids else {}
    samples = analyse(a.workdir_root, names, jobs, now)
    if a.jobs:
        print_jobs(samples)
    if a.status or not (a.html or a.jobs):
        print_status(samples)
    if a.html:
        write_html(a.html, a.workdir_root, samples, now)
        print(f"wrote {a.html}", file=sys.stderr)


if __name__ == "__main__":
    main()
