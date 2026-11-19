#!/usr/bin/env bash
#
# Re-map an aligned CRAM (e.g. BWA-MEM onto GRCh38) to a personalized pangenome
# graph sampled for that sample, then call small variants and graph SVs. Every
# step runs from the local checkout and SIFs, so it works offline.
#
#   1. prepare   (Slurm job)  the CRAM is decoded into one FASTQ pair per read
#                             group, with the CRAM's own reference
#   2. sample    (Slurm job,  KMC + vg haplotypes on those FASTQs ->
#                 after 1)    <prefix>.personalized.{gbz,dist,min,zipcodes,snarls}
#   3. submit    (Slurm job,  scripts/submit-slurm.sh on the same FASTQs and the
#                 after 2)    personalized graph: lane mapping, then the calling
#                             job (DeepVariant or Parabricks, and vg call)
#
# The three jobs are submitted at once, chained with afterok, so this script
# returns immediately. The FASTQs of step 1 feed both step 2 and step 3, so the
# CRAM is decoded once. The graph inputs come from a preset (scripts/apply-graph.py).
#
# Usage:
#   scripts/run-cram-personalized.sh --cram SAMPLE.cram --cram-ref REF.fa \
#       --prefix SAMPLE --workdir DIR --data-root GRAPHS --partition CPU \
#       [--variant parabricks --gpu-partition GPU --gpus 2] [options]
#
# Required:
#   --cram FILE          aligned CRAM (or BAM), with .crai/.bai next to it
#   --cram-ref FILE      the FASTA the CRAM was written with (+ .fai, .dict);
#                        only used to decode the CRAM
#   --prefix NAME        output prefix (and the personalized graph's name)
#   --workdir DIR        work directory every node can see
#   --data-root DIR      where the graph releases are (default: $PGGL_DATA)
#   --partition P        Slurm partition for the CPU jobs
#
# Before anything is submitted the preset's files are checked (also on their own:
# scripts/check-inputs.py PRESET --data-root DIR); the repeat BED comes from
# scripts/fetch-giab-repeat-bed.sh.
#
# Options:
#   --preset FILE        graph preset (default examples/graphs/combined.json)
#   --variant V          parabricks (default), cpu or gpu: the DeepVariant used
#                        in the calling job
#   --gpu-partition P    partition of the calling job (parabricks/gpu)
#   --gpus N             GPUs of the calling job (default 2)
#   --sif FILE           CPU image for steps 1 and 2 (default
#                        deepvariant-opencode-cpu-vg.sif in the checkout)
#   --call-sif FILE      image of step 3, lanes and calling job alike (default
#                        parabricks-vg.sif in the checkout for parabricks,
#                        deepvariant-opencode-gpu-vg.sif for gpu, --sif for cpu);
#                        the GPU images carry the mapping tools too
#   --threads N          threads of steps 1-2 and of the calling job (default 128)
#   --sample-threads N   cores of step 2 (default: --threads). The same number is the
#                        --cpus-per-task of the job and the threads of its tools
#   --sample-mem G       memory of step 2 in GB (default 0 = the whole node). Step 2
#                        shares the node, not --exclusive, only when both options
#                        are given: e.g. --sample-threads 50 --sample-mem 500 on a
#                        128-core, 1 TB node; with one of them it still takes the
#                        node. vg autoindex is given 300G, the most the step uses
#                        (KMC, 128G at most, runs before it)
#   --prepare-threads N  cores of step 1 (default 32); its decoding takes the threads
#                        from the job's cores
#   --prepare-mem G      memory of step 1 in GB (default 64)
#   --run-prepare-threads N, --run-prepare-mem G   cores and memory (GB) of the first job of
#                        step 3 (submit-slurm.sh's own prepare job: with FASTQ lanes, as
#                        here, it only lists the lanes and submits the lane, markdup, sv,
#                        call and cleanup jobs). Give both; default 32 cores, 64 GB
#   --lane-threads N     cores and threads of each lane task of step 3 (the
#                        submit-slurm.sh default: 32)
#   --lane-mem-per-chunk G  memory of a lane task in GB per align chunk (default
#                        100: a chunk is one vg giraffe holding ~80 GB of indexes)
#   --lane-align-chunks N   vg giraffe processes per lane task (default 1); a
#                        lane task asks for N x --lane-mem-per-chunk of memory
#   --markdup-threads N, --markdup-mem G   cores (and threads of its tools) and memory
#                        of the duplicate-marking job; --sv-threads N, --sv-mem G the
#                        same for the graph-SV job. --variant parabricks only, where
#                        they are separate jobs. Given both, the job shares its node;
#                        given one, it still takes the whole node (default: whole node)
#   --call-mem G         memory of the calling job in GB (default: the whole node,
#                        --exclusive); its cores are --threads. With --call-mem the
#                        job shares its node
#   --no-sv              do not call graph SVs
#   --keep-intermediates keep every intermediate file. By default each goes as
#                        soon as nothing reads it: the k-mer counts after step 2,
#                        the decoded FASTQs once every lane is mapped, the lane
#                        BAMs and GAMs after the calls that read them, and the
#                        personalized graph once step 3 has succeeded
#   --keep-graph         keep the personalized graph (~45 GB, ~1.3 h to rebuild)
#   --apptainer FILE     apptainer/singularity binary
#   --sbatch "S"         extra sbatch options for every job, the mapping and calling
#                        jobs of step 3 included (e.g. --time, --account)
#   --from STEP          sample or submit: start there, reusing what an earlier
#                        run left in DIR
#   --after SPEC         Slurm dependency of the first job submitted, e.g.
#                        afterany:12345 (scripts/run-cohort.sh uses it to start
#                        a sample once the previous one has left the sampling)
#   --dry-run            write the jobs and scripts, submit nothing
#   --status             with --workdir only: report which steps of an earlier
#                        run in DIR succeeded, the state of its Slurm jobs, and
#                        how to resume it
#   --resume             resume the run in --workdir where it stopped, with the
#                        same options as the first run: the first step that did not
#                        succeed (from the start, --from sample, --from submit, or
#                        the call, markdup, sv or DeepVariant job of step 3) is
#                        submitted again. A run whose jobs are still queued or
#                        running is left alone; if one of its jobs failed, the
#                        jobs that waited for it are cancelled first. When both
#                        markdup (or DeepVariant) and sv are to be redone, sv is
#                        submitted to wait for the cleanup of the first. A DIR with no jobs.tsv is submitted
#                        as a new sample. With --dry-run it only says where it would resume
set -euo pipefail

die() { echo "run-cram-personalized.sh: $*" >&2; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CRAM= CRAM_REF= PREFIX= WORKDIR= PARTITION= GPU_PARTITION=
DATA_ROOT=${PGGL_DATA:-}
PRESET=$REPO/examples/graphs/combined.json
VARIANT=parabricks GPUS=2 THREADS=128 SAMPLE_THREADS= SAMPLE_MEM=0 CALL_SV=true
SIF=$REPO/deepvariant-opencode-cpu-vg.sif CALL_SIF= APPTAINER= EXTRA= FROM= DRY_RUN=0
CLEANUP=1 KEEP_GRAPH=0 AFTER= LANE_THREADS= LANE_MEM= LANE_CHUNKS=
RESUME=0 RESUME_LATE= RESUME_THEN= RUNPREP_THREADS= RUNPREP_MEM=
PREP_THREADS=32 PREP_MEM=64 MARKDUP_THREADS= MARKDUP_MEM= SV_THREADS= SV_MEM= CALL_MEM=
while [ $# -gt 0 ]; do
    case "$1" in
        --cram) CRAM=$2; shift 2 ;;
        --cram-ref) CRAM_REF=$2; shift 2 ;;
        --prefix) PREFIX=$2; shift 2 ;;
        --workdir) WORKDIR=$2; shift 2 ;;
        --data-root) DATA_ROOT=$2; shift 2 ;;
        --partition) PARTITION=$2; shift 2 ;;
        --preset) PRESET=$2; shift 2 ;;
        --variant) VARIANT=$2; shift 2 ;;
        --gpu-partition) GPU_PARTITION=$2; shift 2 ;;
        --gpus) GPUS=$2; shift 2 ;;
        --sif) SIF=$2; shift 2 ;;
        --call-sif) CALL_SIF=$2; shift 2 ;;
        --threads) THREADS=$2; shift 2 ;;
        --sample-threads) SAMPLE_THREADS=$2; shift 2 ;;
        --sample-mem) SAMPLE_MEM=$2; shift 2 ;;
        --run-prepare-threads) RUNPREP_THREADS=$2; shift 2 ;;
        --run-prepare-mem) RUNPREP_MEM=$2; shift 2 ;;
        --prepare-threads) PREP_THREADS=$2; shift 2 ;;
        --prepare-mem) PREP_MEM=$2; shift 2 ;;
        --markdup-threads) MARKDUP_THREADS=$2; shift 2 ;;
        --markdup-mem) MARKDUP_MEM=$2; shift 2 ;;
        --sv-threads) SV_THREADS=$2; shift 2 ;;
        --sv-mem) SV_MEM=$2; shift 2 ;;
        --call-mem) CALL_MEM=$2; shift 2 ;;
        --lane-threads) LANE_THREADS=$2; shift 2 ;;
        --lane-mem-per-chunk) LANE_MEM=$2; shift 2 ;;
        --lane-align-chunks) LANE_CHUNKS=$2; shift 2 ;;
        --no-sv) CALL_SV=false; shift ;;
        --keep-intermediates) CLEANUP=0; shift ;;
        --keep-graph) KEEP_GRAPH=1; shift ;;
        --apptainer) APPTAINER=$2; shift 2 ;;
        --sbatch) EXTRA=$2; shift 2 ;;
        --from) FROM=$2; shift 2 ;;
        --after) AFTER=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --status) STATUS=1; shift ;;
        --resume) RESUME=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
done

# --status: each step writes its marker only when it succeeds, so the markers
# say how far the run got; the jobs.tsv files give the Slurm states.
if [ "${STATUS:-0}" = 1 ] || { [ "$RESUME" = 1 ] && [ -s "${WORKDIR:-/nonexistent}/jobs.tsv" ]; }; then
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || die "--status needs the --workdir of an earlier run"
    W=$(cd "$WORKDIR" && pwd)
    have() { [ -s "$1" ]; }
    mark() { if [ "$1" = 1 ]; then printf '  OK  %s\n' "$2"; else printf '  --  %s\n' "$2"; fi; }
    # the lists are empty before the lanes exist, and ls then fails
    nl=$(ls -d "$W"/run/lanes/*/ 2>/dev/null | wc -l || true)
    nd=$(ls "$W"/run/lanes/*/out.json 2>/dev/null | wc -l || true)
    s_prep=0; s_sample=0; s_submit=0; s_lanes=0; s_md=0; s_sv=0; s_call=0
    have "$W/prep/prepare.out.json" && s_prep=1
    have "$W/run/jobs.tsv" && s_submit=1
    [ "$nl" -gt 0 ] && [ "$nl" = "$nd" ] && s_lanes=1
    have "$W/run/out-markdup.json" && s_md=1
    have "$W/run/out-sv.json" && s_sv=1
    have "$W/run/out.json" && s_call=1
    # the graph is removed once everything succeeded, so later steps imply it
    { have "$W/pgraph/out.json" || [ "$s_submit" = 1 ]; } && s_sample=1
    if [ "$RESUME" = 0 ]; then
        echo "run in $W:"
        mark $s_prep   "1. prepare  (CRAM -> FASTQ)"
        mark $s_sample "2. sample   (personalized graph)"
        mark $s_submit "3. submit   (mapping and calling submitted)"
        mark $s_lanes  "   lanes    ($nd/$nl mapped)"
        mark $s_md     "   markdup"
        mark $s_sv     "   sv"
        mark $s_call   "   call     (DeepVariant)"
    fi
    if command -v sacct >/dev/null; then
        ids=$(cut -f2 "$W/jobs.tsv" "$W/run/jobs.tsv" 2>/dev/null | paste -sd, -)
        if [ -n "$ids" ]; then
            if [ "$RESUME" = 0 ]; then
                echo "Slurm jobs:"
                sacct -j "$ids" -X -n -o JobID%14,JobName%28,State%12,Elapsed 2>/dev/null | sed 's/^/  /'
            fi
            states=$(sacct -j "$ids" -X -n -o State 2>/dev/null || true)
            if echo "$states" | grep -qE 'RUNNING|REQUEUED|SUSPENDED|COMPLETING'; then
                echo "${PREFIX:-$(basename "$W")}: some jobs are still running: wait for them (or scancel them) before resuming"
                exit 0
            elif echo "$states" | grep -q 'PENDING'; then
                if [ "$RESUME" = 1 ] && echo "$states" | grep -qE 'FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED'; then
                    # a job failed, so the jobs that wait for it (afterok) will never start
                    for j in $(sacct -j "$ids" -X -n -P -o JobID,State 2>/dev/null | awk -F'|' '$2 ~ /^PENDING/ { print $1 }'); do
                        echo "${PREFIX:-$(basename "$W")}: cancelling ${j%%_*}, which waits for a job that failed"
                        [ "$DRY_RUN" = 1 ] || scancel "${j%%_*}" || true
                    done
                else
                    echo "${PREFIX:-$(basename "$W")}: some jobs are still pending: wait for them (or scancel them) before resuming"
                    exit 0
                fi
            fi
        fi
    fi
    cmd=$(sed -n '/submit-slurm.sh/,$p' "$W/3-submit.sh" 2>/dev/null | sed 's/\\$//' | tr -s ' \n' ' ' | sed "s#\\\$W#$W#g")
    if [ "$RESUME" = 1 ]; then
        : "${PREFIX:=$(basename "$W")}"
        if { [ "$s_md" = 1 ] && [ "$s_sv" = 1 ] && [ "$s_call" = 1 ]; } || { [ "$VARIANT" != parabricks ] && [ "$s_call" = 1 ]; }; then
            echo "$PREFIX: done (outputs in $W/run/out/)"
            exit 0
        fi
        late="" later=""
        if [ "$s_md" = 1 ] || [ "$s_sv" = 1 ]; then
            # one of the calling jobs succeeded and removed the lane files it read
            [ "$s_md" = 1 ] && [ "$s_call" = 0 ] && late=dv
            [ "$s_md" = 0 ] && late=markdup
            if [ -z "$late" ]; then
                late=sv
            elif [ "$s_sv" = 0 ]; then
                # each resubmission ends with a cleanup job that clears the scratch and the
                # graph, so the SV job is submitted to wait for that cleanup
                RESUME_THEN=sv
                later=" and then sv (waiting for the first to finish)"
            fi
        elif [ "$s_lanes" = 1 ]; then
            late=call
        elif [ "$s_sample" = 1 ] && [ -d "$W/prep/prepare-out" ]; then
            FROM=submit
        elif [ "$s_sample" = 1 ]; then
            echo "$PREFIX: cannot resume: the decoded FASTQs are gone, so the lanes cannot be remapped; remove $W and run it again"
            exit 1
        elif [ "$s_prep" = 1 ]; then
            FROM=sample
        else
            FROM=
        fi
        if [ -n "$late" ]; then FROM=submit; RESUME_LATE=$late; fi
        what=${RESUME_LATE:-${FROM:+--from $FROM}}
        if [ "$DRY_RUN" = 1 ]; then
            echo "$PREFIX: would resume at ${what:-the start}$later"
            exit 0
        fi
        echo "$PREFIX: resuming at ${what:-the start}$later"
    else
        echo "next:"
        if [ "$s_md" = 1 ] && [ "$s_sv" = 1 ] && [ "$s_call" = 1 ]; then
            echo "  nothing to resume: the outputs are in $W/run/out/"
        elif [ "$s_md" = 1 ] || [ "$s_sv" = 1 ]; then
            # one of the calling jobs succeeded and removed the lane files it read,
            # so resume only the parts that did not
            [ "$s_md" = 1 ] && [ "$s_call" = 0 ] && echo "  DeepVariant:    $cmd --from dv"
            [ "$s_md" = 0 ] && echo "  markdup + call: $cmd --from markdup"
            [ "$s_sv" = 0 ] && echo "  graph SVs:      $cmd --from sv"
            if [ "$s_sv" = 0 ] && { [ "$s_md" = 0 ] || [ "$s_call" = 0 ]; }; then
                # each resubmission ends with a cleanup job that clears the scratch
                # and the graph, so a second one running alongside would lose them
                echo "  submit these one at a time: the second only after the first has finished"
            fi
        elif [ "$s_lanes" = 1 ]; then
            echo "  the calling stage over the mapped lanes:"
            echo "    $cmd --from call"
        elif [ "$s_sample" = 1 ] && [ -d "$W/prep/prepare-out" ]; then
            echo "  rerun this script with the same options plus --from submit"
        elif [ "$s_sample" = 1 ]; then
            echo "  the decoded FASTQs are gone, so the lanes cannot be remapped: rerun from the start"
        elif [ "$s_prep" = 1 ]; then
            echo "  rerun this script with the same options plus --from sample"
        else
            echo "  rerun this script with the same options (no --from)"
        fi
        echo "logs: $W/logs/ (steps 1-3) and $W/run/logs/ (lanes, markdup, sv, call)"
        exit 0
    fi
fi

[ -n "$PREFIX" ] && [ -n "$WORKDIR" ] && [ -n "$PARTITION" ] || die "--prefix, --workdir and --partition are required"
[ -n "$DATA_ROOT" ] || die "give --data-root or set PGGL_DATA"
SHARE_NODE=0; [ -n "$SAMPLE_THREADS" ] && [ "$SAMPLE_MEM" != 0 ] && SHARE_NODE=1
: "${SAMPLE_THREADS:=$THREADS}"
case "$SAMPLE_THREADS$SAMPLE_MEM" in *[!0-9]*) die "--sample-threads and --sample-mem take whole numbers" ;; esac
case "$LANE_THREADS$LANE_MEM$LANE_CHUNKS" in *[!0-9]*) die "--lane-threads, --lane-mem-per-chunk and --lane-align-chunks take whole numbers" ;; esac
case "$PREP_THREADS$PREP_MEM$RUNPREP_THREADS$RUNPREP_MEM$MARKDUP_THREADS$MARKDUP_MEM$SV_THREADS$SV_MEM$CALL_MEM" in
    *[!0-9]*) die "--prepare-*, --run-prepare-*, --markdup-*, --sv-* and --call-mem take whole numbers" ;;
esac
if [ -n "$RUNPREP_THREADS$RUNPREP_MEM" ]; then
    [ -n "$RUNPREP_THREADS" ] && [ -n "$RUNPREP_MEM" ] || die "--run-prepare-threads and --run-prepare-mem go together"
fi
[ -n "$PREP_THREADS" ] && [ -n "$PREP_MEM" ] || die "--prepare-threads and --prepare-mem need a number"
LANE_OPT=""
[ -z "$RUNPREP_THREADS" ] || LANE_OPT+=" --prepare-sbatch \"--cpus-per-task=$RUNPREP_THREADS --mem=${RUNPREP_MEM}G\""
[ -z "$LANE_THREADS" ] || LANE_OPT+=" --lane-threads $LANE_THREADS"
[ -z "$LANE_MEM" ] || LANE_OPT+=" --lane-mem-per-chunk $LANE_MEM"
[ -z "$LANE_CHUNKS" ] || LANE_OPT+=" --lane-align-chunks $LANE_CHUNKS"
if [ -n "$MARKDUP_THREADS$MARKDUP_MEM$SV_THREADS$SV_MEM" ]; then
    [ "$VARIANT" = parabricks ] || die "--markdup-* and --sv-* need --variant parabricks (the other variants have no separate jobs)"
fi
[ -z "$MARKDUP_THREADS" ] || LANE_OPT+=" --markdup-threads $MARKDUP_THREADS"
[ -z "$MARKDUP_MEM" ] || LANE_OPT+=" --markdup-mem $MARKDUP_MEM"
[ -z "$SV_THREADS" ] || LANE_OPT+=" --sv-threads $SV_THREADS"
[ -z "$SV_MEM" ] || LANE_OPT+=" --sv-mem $SV_MEM"
case "$FROM" in "") [ -n "$CRAM" ] && [ -n "$CRAM_REF" ] || die "--cram and --cram-ref are required" ;; sample|submit) ;; *) die "--from takes sample or submit" ;; esac
case "$VARIANT" in
    parabricks) : "${CALL_SIF:=$REPO/parabricks-vg.sif}" ;;
    gpu) : "${CALL_SIF:=$REPO/deepvariant-opencode-gpu-vg.sif}" ;;
    cpu) : "${CALL_SIF:=$SIF}" ;;
    *) die "--variant takes parabricks, gpu or cpu" ;;
esac
if [ "$VARIANT" != cpu ]; then
    [ -n "$GPU_PARTITION" ] || die "--variant $VARIANT needs --gpu-partition"
fi
for f in "$SIF" "$CALL_SIF" "$PRESET"; do [ -s "$f" ] || die "$f not found"; done
# fail now, not hours later inside a job, when a graph file or the repeat BED is missing
python3 "$REPO/scripts/check-inputs.py" --data-root "$DATA_ROOT" "$PRESET" >&2 \
    || die "the preset's input files are missing (see above)"
if [ -z "$APPTAINER" ]; then
    APPTAINER=$(command -v apptainer || command -v singularity \
        || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1 || true)
fi
[ -n "$APPTAINER" ] && [ -x "$APPTAINER" ] || die "no apptainer/singularity found; pass --apptainer"
command -v sbatch >/dev/null || [ "$DRY_RUN" = 1 ] || die "sbatch not found"

mkdir -p "$WORKDIR"
W=$(cd "$WORKDIR" && pwd)
mkdir -p "$W/logs"
SIF=$(readlink -f "$SIF"); CALL_SIF=$(readlink -f "$CALL_SIF"); PRESET=$(readlink -f "$PRESET")
export PGGL_DATA=$DATA_ROOT
AG="python3 $REPO/scripts/apply-graph.py"
APP_OPT="--apptainer $APPTAINER"

# --- the sample's job, from the CRAM template ---------------------------------
if [ -z "$FROM" ]; then
    [ -s "$CRAM" ] || die "$CRAM not found"
    [ -s "$CRAM_REF.fai" ] || die "$CRAM_REF.fai not found (samtools faidx)"
    [ -s "${CRAM_REF%.*}.dict" ] || die "${CRAM_REF%.*}.dict not found (samtools dict)"
    python3 - "$REPO/examples/jobs/sample.cram.json" "$W/sample.cram.json" "$(readlink -f "$CRAM")" \
        "$PREFIX" "$THREADS" "$CALL_SV" <<'PY'
import json, sys
tpl, out, cram, prefix, threads, sv = sys.argv[1:]
j = json.load(open(tpl))
j.pop("cram", None)
j["bam" if cram.endswith(".bam") else "cram"] = {"class": "File", "path": cram}
j.update(prefix=prefix, threads=int(threads), call_sv=(sv == "true"))
json.dump(j, open(out, "w"), indent=1)
PY
    # Step 1 decodes the CRAM, so its job carries the CRAM's reference.
    $AG germline "$PRESET" "$W/sample.cram.json" "$W/prep.json"
    python3 - "$W/prep.json" "$(readlink -f "$CRAM_REF")" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j["ref"] = {"class": "File", "path": sys.argv[2]}
json.dump(j, open(sys.argv[1], "w"), indent=1)
PY
    # --dry-run makes 1-prepare.sh stop after the lanes are listed.
    "$REPO/scripts/submit-slurm.sh" --job "$W/prep.json" --workdir "$W/prep" --sif "$SIF" \
        --partition "$PARTITION" $APP_OPT --dry-run >/dev/null
fi

# --- step 2: personalized graph ------------------------------------------------
cat > "$W/2-sample.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
W=$W
export PGGL_DATA=$DATA_ROOT
[ -s "\$W/prep/prepare.out.json" ] || { echo "no \$W/prep/prepare.out.json: step 1 did not finish" >&2; exit 1; }
python3 - "\$W/prep/prepare.out.json" "\$W/sample.cram.json" "\$W/sample.fastq.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); j = json.load(open(sys.argv[2]))
j.pop("cram", None); j.pop("bam", None)
for k in ("fq1", "fq2"):
    j[k] = [{"class": "File", "path": f["path"]} for f in p[k]]
j["rg"] = p["rg"]
json.dump(j, open(sys.argv[3], "w"), indent=1)
PY
$AG haplotype-sample "$PRESET" "\$W/sample.fastq.json" "\$W/hs.json" --threads $SAMPLE_THREADS
python3 - "\$W/hs.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
j.setdefault("kmc_max_memory_gb", 128); j.setdefault("autoindex_target_mem", "300G")
json.dump(j, open(sys.argv[1], "w"), indent=1)
PY
BINDS=\$(python3 - "\$W/hs.json" "$REPO" "\$W" "$SIF" <<'PY'
import json, os, sys
paths = set(sys.argv[2:])
def walk(o):
    if isinstance(o, list):
        for v in o: walk(v)
    elif isinstance(o, dict):
        if o.get("class") == "File": paths.add(o["path"])
        for v in o.values(): walk(v)
walk(json.load(open(sys.argv[1])))
tops = set()
for p in paths:
    for q in (p, os.path.realpath(p)):
        parts = q.split("/")
        if len(parts) < 2 or not parts[1]: continue
        if parts[1] in ("usr", "opt"):
            if len(parts) > 4 and parts[3]: tops.add("/".join(parts[:4]))
        elif parts[1] not in ("etc", "proc", "sys", "dev"):
            tops.add("/" + parts[1])
print(" ".join("--bind " + t for t in sorted(tops)))
PY
)
rm -rf "\$W/tmp/sample" "\$W/tmp-out/sample"
mkdir -p "\$W/pgraph" "\$W/tmp/sample" "\$W/tmp-out/sample"
"$APPTAINER" exec --cleanenv --env PYTHONNOUSERSITE=1 \$BINDS --bind /tmp "$SIF" \\
    cwltool --no-container --timestamps --outdir "\$W/pgraph" \\
        --tmpdir-prefix "\$W/tmp/sample/" --tmp-outdir-prefix "\$W/tmp-out/sample/" \\
        "$REPO/Workflows/haplotype-sample.cwl" "\$W/hs.json" > "\$W/pgraph/out.json"
for e in gbz dist min zipcodes snarls; do
    [ -s "\$W/pgraph/$PREFIX.personalized.\$e" ] || { echo "missing \$W/pgraph/$PREFIX.personalized.\$e" >&2; exit 1; }
done
rm -rf "\$W/tmp/sample" "\$W/tmp-out/sample"
# the k-mer counts (~25 GB for 35x) are read by the sampling only
[ "$CLEANUP" = 0 ] || rm -f "\$W/pgraph/$PREFIX.kff"
EOF

# --- step 3: map to the personalized graph and call ----------------------------
# step 3 removes the decoded FASTQs once every lane is mapped, and the graph
# once it has succeeded
CLEAN_OPT=""
if [ "$CLEANUP" = 0 ]; then
    CLEAN_OPT="--keep-intermediates"
else
    CLEAN_OPT="--remove-after-lanes \"$W/prep/prepare-out\" --remove-after-success \"$W/prep/tmp\" --remove-after-success \"$W/prep/tmp-out\" --remove-after-success \"$W/tmp\" --remove-after-success \"$W/tmp-out\""
    [ "$KEEP_GRAPH" = 1 ] || CLEAN_OPT+=" --remove-after-success \"$W/pgraph\""
fi
SBATCH_OPT=""
[ -n "$EXTRA" ] && SBATCH_OPT="--sbatch \"$EXTRA\""
CALL_OPT=""
CALL_RES="--exclusive --mem=0"; [ -z "$CALL_MEM" ] || CALL_RES="--mem=${CALL_MEM}G"
if [ "$VARIANT" != cpu ]; then
    CALL_OPT="--call-sbatch \"-p $GPU_PARTITION $CALL_RES --cpus-per-task=$THREADS --gres=gpu:$GPUS\""
elif [ -n "$CALL_MEM" ]; then
    CALL_OPT="--call-sbatch \"$CALL_RES --cpus-per-task=$THREADS\""
fi
cat > "$W/3-submit.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
W=$W
export PGGL_DATA=$DATA_ROOT
$AG personalized "$PRESET" "\$W/sample.fastq.json" "\$W/pgraph/$PREFIX.personalized" "\$W/job.json"
python3 - "\$W/job.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
if "$VARIANT" == "parabricks": j["num_gpus"] = $GPUS
json.dump(j, open(sys.argv[1], "w"), indent=1)
PY
"$REPO/scripts/submit-slurm.sh" --job "\$W/job.json" --workdir "\$W/run" --variant $VARIANT \\
    --sif "$CALL_SIF" --partition "$PARTITION" $APP_OPT $SBATCH_OPT $CALL_OPT$LANE_OPT $CLEAN_OPT
EOF
chmod +x "$W/2-sample.sh" "$W/3-submit.sh"

# --resume of the calling stage: submit again only that part, with the options of this run
if [ -n "$RESUME_LATE" ]; then
    cmd=$(sed -n '/submit-slurm.sh/,$p' "$W/3-submit.sh" | sed 's/\\$//' | tr -s ' \n' ' ' | sed "s#\\\$W#$W#g")
    eval "$cmd --from $RESUME_LATE"
    if [ -n "$RESUME_THEN" ]; then
        # the last job recorded is the cleanup of the first resubmission (else its last job)
        last=$(tail -n 1 "$W/run/jobs.tsv" | cut -f2)
        [ -n "$last" ] || die "no job recorded in $W/run/jobs.tsv after resubmitting $RESUME_LATE"
        eval "$cmd --from $RESUME_THEN --after-job $last"
    fi
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "dry run: nothing submitted; the jobs would run $W/prep/1-prepare.sh, $W/2-sample.sh and $W/3-submit.sh"
    exit 0
fi

# --- submit -------------------------------------------------------------------
dep=""; [ -z "$AFTER" ] || dep="--dependency=$AFTER"
if [ -z "$FROM" ]; then
    J1=$(sbatch --parsable $dep -p "$PARTITION" -c "$PREP_THREADS" --mem="${PREP_MEM}G" $EXTRA -J "$PREFIX-prepare" \
        -o "$W/logs/1-prepare.%j.out" -e "$W/logs/1-prepare.%j.err" "$W/prep/1-prepare.sh")
    printf 'prepare\t%s\n' "$J1" >> "$W/jobs.tsv"; dep="--dependency=afterok:$J1"
fi
if [ "$FROM" != submit ]; then
    MEM_OPT=--mem=0; [ "$SAMPLE_MEM" != 0 ] && MEM_OPT=--mem=${SAMPLE_MEM}G
    EXCL=--exclusive; [ "$SHARE_NODE" = 1 ] && EXCL=
    J2=$(sbatch --parsable $dep -p "$PARTITION" $EXCL -c "$SAMPLE_THREADS" $MEM_OPT $EXTRA \
        -J "$PREFIX-sample" -o "$W/logs/2-sample.%j.out" -e "$W/logs/2-sample.%j.err" "$W/2-sample.sh")
    printf 'sample\t%s\n' "$J2" >> "$W/jobs.tsv"; dep="--dependency=afterok:$J2"
fi
J3=$(sbatch --parsable $dep -p "$PARTITION" -c 1 --mem=4G $EXTRA -J "$PREFIX-submit" \
    -o "$W/logs/3-submit.%j.out" -e "$W/logs/3-submit.%j.err" "$W/3-submit.sh")
printf 'submit\t%s\n' "$J3" >> "$W/jobs.tsv"
echo "submitted: ${J1:+prepare $J1, }${J2:+sample $J2, }submit $J3 (job IDs in $W/jobs.tsv)"
echo "the mapping and calling jobs appear in $W/run/jobs.tsv once $J3 has run; outputs in $W/run/out/"
