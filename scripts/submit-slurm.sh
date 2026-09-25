#!/usr/bin/env bash
#
# Runs a germline workflow on a Slurm cluster as separate jobs, so the lanes are
# mapped on as many nodes as are free instead of one after another on one node:
#
#   1. prepare  (1 job)            Workflows/parts/prepare-lanes.cwl
#                                  reads -> lanes; a CRAM/BAM is split by @RG
#   2. lane     (array, 1 task     Workflows/parts/lane-align.cwl
#               per lane)          vg giraffe -> surject -> lane BAM (+ GAM)
#   3. call     (1 job, after      Workflows/parts/call-<variant>.cwl
#               every lane)        duplicate marking, DeepVariant, graph SVs
#
# These are the same parts Workflows/germline-pangenome-<variant>.cwl runs in one
# cwltool process, fed from the same job file, so the outputs are the same as a
# single-node run. No Toil or other workflow engine is needed: each job runs
# cwltool on one part inside the SIF, and the jobs are chained with Slurm
# dependencies. The number of lanes is only known once stage 1 has read the
# input, so stage 1 submits stages 2 and 3 itself when it finishes.
#
# Usage:
#   scripts/submit-slurm.sh --job JOB.json --workdir DIR [options]
#
# Options:
#   --variant V          cpu (default), gpu or pangenome-aware-cpu
#   --sif FILE           image to run cwltool and the tools in
#                        (default: deepvariant-opencode-cpu-vg.sif in the repo)
#   --apptainer FILE     apptainer/singularity binary (default: first on PATH,
#                        else the newest /opt/pkg/apptainer/*/bin/apptainer)
#   --partition P        Slurm partition for every stage
#   --bind DIR           extra bind path for the container (repeatable); the
#                        top-level directories of the repo, the work dir and
#                        every input path are bound automatically
#   --prepare-sbatch S   extra sbatch options for stage 1
#                        (default: "--cpus-per-task=32 --mem=64G")
#   --lane-threads N     threads of each lane task (default 32), for stage 2
#                        only: DeepVariant in stage 3 keeps the job's `threads`.
#   --lane-align-chunks N  align_chunks of each lane task (default 1). Every
#                        chunk is one vg giraffe process holding the whole index
#                        set, ~80 GB for JaSaPaGe, whatever its thread count.
#   --lane-mem-per-chunk G  memory per chunk in GB (default 100)
#   --lane-whole-node    one lane per node instead: --exclusive --mem=0 and the
#                        job's own `threads` / `align_chunks`
#   --lane-sbatch S      sbatch options for each lane task, replacing the
#                        default "--cpus-per-task=<lane threads>
#                        --mem=<chunks x mem per chunk>G"
#
#   Why small lane tasks by default: vg giraffe spends a fixed ~85 s loading
#   the JaSaPaGe indexes whatever its thread count, and its mapping scales
#   well only to ~32 threads (measured on one lane, 7.9M reads: 94% efficiency
#   at 32 threads, 64% at 128, none gained beyond). Four 32-thread lanes on a
#   128-core node overlap their loading and did a lane every ~47 s; one lane
#   with the whole node took ~110-123 s however it was split.
#   --call-sbatch S      extra sbatch options for stage 3
#                        (default: "--exclusive --mem=0 --cpus-per-task=<threads>")
#   --max-lanes N        run at most N lane tasks at once (array %N)
#   --local-index DIR    node-local directory the lane tasks copy the graph and
#                        giraffe indexes into before mapping (default /tmp;
#                        needs ~55 GB free for JaSaPaGe). The copy is shared by
#                        every lane task on the node and removed by the last one
#                        to finish. vg memory-maps its indexes, and on Lustre
#                        several nodes mapping the same files stall on lock
#                        traffic.
#   --no-local-index     map straight from the shared copies
#   --dry-run            write the stage scripts and jobs, submit nothing
#
# The workflow files are taken from this checkout (so the parts always match the
# scripts next to them), and <threads> is the job file's `threads`.
#
# Everything lands under DIR: job.json (the job with absolute paths), stage
# scripts, per-stage cwltool logs in logs/, the lanes in lanes/NNNN/, and the
# final outputs in out/ -- the same files a single-node run writes to --outdir.
# DIR/jobs.tsv lists the Slurm job IDs as they are submitted.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

JOB=
WORKDIR=
VARIANT=cpu
SIF="$REPO/deepvariant-opencode-cpu-vg.sif"
APPTAINER=
PARTITION=
BINDS=()
PREPARE_SBATCH=
LANE_SBATCH=
CALL_SBATCH=
MAX_LANES=
LOCAL_INDEX=/tmp
LANE_THREADS=32
LANE_CHUNKS=1
LANE_MEM_PER_CHUNK=100
DRY_RUN=0

die() { echo "submit-slurm.sh: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --job) JOB=$2; shift 2 ;;
        --workdir) WORKDIR=$2; shift 2 ;;
        --variant) VARIANT=$2; shift 2 ;;
        --sif) SIF=$2; shift 2 ;;
        --apptainer) APPTAINER=$2; shift 2 ;;
        --partition) PARTITION=$2; shift 2 ;;
        --bind) BINDS+=( "$2" ); shift 2 ;;
        --prepare-sbatch) PREPARE_SBATCH=$2; shift 2 ;;
        --lane-sbatch) LANE_SBATCH=$2; shift 2 ;;
        --call-sbatch) CALL_SBATCH=$2; shift 2 ;;
        --max-lanes) MAX_LANES=$2; shift 2 ;;
        --local-index) LOCAL_INDEX=$2; shift 2 ;;
        --lane-threads) LANE_THREADS=$2; shift 2 ;;
        --lane-align-chunks) LANE_CHUNKS=$2; shift 2 ;;
        --lane-mem-per-chunk) LANE_MEM_PER_CHUNK=$2; shift 2 ;;
        --lane-whole-node) LANE_THREADS=; LANE_CHUNKS=; shift ;;
        --no-local-index) LOCAL_INDEX=; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$JOB" ] || die "--job is required"
[ -n "$WORKDIR" ] || die "--workdir is required"
[ -f "$JOB" ] || die "no such job file: $JOB"
[ -f "$SIF" ] || die "no such image: $SIF"
case "$VARIANT" in
    cpu|gpu|pangenome-aware-cpu) ;;
    *) die "--variant must be cpu, gpu or pangenome-aware-cpu" ;;
esac
if [ -z "$APPTAINER" ]; then
    APPTAINER=$(command -v apptainer 2>/dev/null \
        || ls -d /opt/pkg/apptainer/*/bin/apptainer 2>/dev/null | sort -V | tail -1 \
        || command -v singularity 2>/dev/null || true)
fi
[ -n "$APPTAINER" ] && [ -x "$APPTAINER" ] || die "no apptainer/singularity found; pass --apptainer"
command -v sbatch >/dev/null || [ "$DRY_RUN" = 1 ] || die "sbatch not found"

mkdir -p "$WORKDIR"
W=$(cd "$WORKDIR" && pwd)
mkdir -p "$W/logs" "$W/lanes" "$W/tmp" "$W/tmp-out"

PARTS="$REPO/Workflows/parts"
HELPER="$REPO/scripts/slurm-jobs.py"
python3 "$HELPER" absolutize "$JOB" "$W/job.json"

THREADS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("threads", 32))' "$W/job.json")
: "${PREPARE_SBATCH:=--cpus-per-task=32 --mem=64G}"
JOB_CHUNKS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("align_chunks", 1))' "$W/job.json")
LANE_SET=""
[ -n "$LANE_THREADS" ] && LANE_SET+=" --set threads=$LANE_THREADS"
[ -n "$LANE_CHUNKS" ] && LANE_SET+=" --set align_chunks=$LANE_CHUNKS"
if [ -n "$LANE_THREADS" ]; then
    : "${LANE_SBATCH:=--cpus-per-task=$LANE_THREADS --mem=$(( ${LANE_CHUNKS:-$JOB_CHUNKS} * LANE_MEM_PER_CHUNK ))G}"
else
    : "${LANE_SBATCH:=--exclusive --mem=0 --cpus-per-task=$THREADS}"
fi
: "${CALL_SBATCH:=--exclusive --mem=0 --cpus-per-task=$THREADS}"
PREPARE_THREADS=$(printf '%s\n' $PREPARE_SBATCH | sed -n 's/^--cpus-per-task=//p; s/^-c//p' | tail -1)
: "${PREPARE_THREADS:=$THREADS}"

# Bind the top-level directory of everything the jobs touch: the checkout, the
# work dir, the image, and every input path (both as written and as resolved,
# since shared data is often reached through symlinks).
mapfile -t AUTO_BINDS < <(python3 - "$W/job.json" "$REPO" "$W" "$SIF" <<'PY'
import json, os, sys
paths = set(sys.argv[2:])
def walk(o):
    if isinstance(o, list):
        for v in o: walk(v)
    elif isinstance(o, dict):
        if o.get("class") in ("File", "Directory"):
            for k in ("path", "location"):
                v = o.get(k)
                if isinstance(v, str):
                    paths.add(v[7:] if v.startswith("file://") else v)
        for v in o.values(): walk(v)
walk(json.load(open(sys.argv[1])))
tops = set()
for p in paths:
    for q in (p, os.path.realpath(p)):
        parts = q.split("/")
        if len(parts) > 1 and parts[1]:
            tops.add("/" + parts[1])
for t in sorted(tops):
    if t not in ("/usr", "/opt", "/etc", "/proc", "/sys", "/dev"):
        print(t)
PY
)
BIND_ARGS=""
for b in "${AUTO_BINDS[@]}" "${BINDS[@]+"${BINDS[@]}"}" /tmp ${LOCAL_INDEX:+"$LOCAL_INDEX"}; do
    BIND_ARGS+=" --bind $b"
done
GPU_ARG=""
[ "$VARIANT" = gpu ] && GPU_ARG=" --nv"

PART_OPT=""
[ -n "$PARTITION" ] && PART_OPT="--partition=$PARTITION"
ARRAY_LIMIT=""
[ -n "$MAX_LANES" ] && ARRAY_LIMIT="%$MAX_LANES"

PREFIX=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prefix"])' "$W/job.json")
# Names the node-local copy of the index set: the same files (path, size,
# mtime) give the same name, so lane tasks of any run on a node share one copy.
INDEX_KEY=$(python3 - "$W/job.json" <<'PY'
import hashlib, json, os, sys
j = json.load(open(sys.argv[1]))
h = hashlib.sha1()
for k in ("gbz", "dist", "min", "zipcodes"):
    p = os.path.realpath(j[k].get("path") or j[k]["location"].replace("file://", "", 1))
    st = os.stat(p)
    h.update(f"{k}={p}:{st.st_size}:{int(st.st_mtime)}\n".encode())
print(h.hexdigest()[:12])
PY
)

# Shared by the three stage scripts: run cwltool on one part inside the image.
cat > "$W/env.sh" <<EOF
# written by scripts/submit-slurm.sh
set -euo pipefail
W=$W
REPO=$REPO
PARTS=$PARTS
HELPER=$HELPER
SIF=$SIF
APPTAINER=$APPTAINER
VARIANT=$VARIANT
PART_OPT="$PART_OPT"
ARRAY_LIMIT="$ARRAY_LIMIT"
LANE_SBATCH="$LANE_SBATCH"
CALL_SBATCH="$CALL_SBATCH"
DRY_RUN=$DRY_RUN
LOCAL_INDEX="$LOCAL_INDEX"
INDEX_KEY=$INDEX_KEY
LANE_SET="$LANE_SET"
# run_part <stage-name> <part.cwl> <job.json> <out.json> [cwltool options...]
run_part() {
    local name=\$1 part=\$2 job=\$3 out=\$4
    shift 4
    echo "[\$(date -Is)] \$name on \$(hostname) (\$(nproc) cpus): \$part"
    "\$APPTAINER" exec --cleanenv$GPU_ARG$BIND_ARGS "\$SIF" \\
        cwltool --no-container --timestamps \\
            --tmpdir-prefix "\$W/tmp/\$name/" --tmp-outdir-prefix "\$W/tmp-out/\$name/" \\
            "\$@" "\$part" "\$job" > "\$out.partial"
    mv "\$out.partial" "\$out"
    echo "[\$(date -Is)] \$name done"
}
record() { printf '%s\\t%s\\n' "\$1" "\$2" >> "\$W/jobs.tsv"; }
EOF

# Stage 1: recover the lanes of a CRAM/BAM (FASTQ lanes need no stage 1), then
# submit the lane array and the calling job.
cat > "$W/1-prepare.sh" <<'EOF'
#!/usr/bin/env bash
source "__W__/env.sh"
todo=$(python3 "$HELPER" prepare "$W/job.json" "$PARTS/prepare-lanes.cwl" "$W/prepare.job.json" \
    --threads "${SLURM_CPUS_PER_TASK:-$(nproc)}")
if [ "$todo" = run ]; then
    run_part prepare "$PARTS/prepare-lanes.cwl" "$W/prepare.job.json" "$W/prepare.out.json" \
        --outdir "$W/prepare-out"
else
    echo "no cram/bam: the job's FASTQ lanes are used as they are"
fi
N=$(python3 "$HELPER" lanes "$W/job.json" "$W/prepare.out.json" "$PARTS/lane-align.cwl" "$W/lanes" $LANE_SET)
echo "lanes: $N"
if [ "$DRY_RUN" = 1 ]; then echo "dry run: not submitting stages 2 and 3"; exit 0; fi
LANE_JOB=$(sbatch --parsable $PART_OPT $LANE_SBATCH --job-name="${SLURM_JOB_NAME:-pggl}-lane" \
    --array="1-$N$ARRAY_LIMIT" --output="$W/logs/lane-%a.%A.out" --error="$W/logs/lane-%a.%A.err" \
    "$W/2-lane.sh")
record lane "$LANE_JOB"
CALL_JOB=$(sbatch --parsable $PART_OPT $CALL_SBATCH --job-name="${SLURM_JOB_NAME:-pggl}-call" \
    --dependency="afterok:$LANE_JOB" --kill-on-invalid-dep=yes \
    --output="$W/logs/call.%j.out" --error="$W/logs/call.%j.err" \
    "$W/3-call.sh")
record call "$CALL_JOB"
echo "submitted lane array $LANE_JOB ($N tasks) and call job $CALL_JOB"
EOF

# Stage 2: one lane per array task.
cat > "$W/2-lane.sh" <<'EOF'
#!/usr/bin/env bash
source "__W__/env.sh"
L=$(printf '%04d' "${SLURM_ARRAY_TASK_ID:?not an array task}")
D="$W/lanes/$L"
JOBFILE="$D/job.json"
if [ -n "$LOCAL_INDEX" ]; then
    # One copy per node, shared by every lane task running there: each task
    # registers under users/, the copy is made (or found) under the lock, and
    # the last task to leave -- or the first to find only dead tasks listed --
    # removes it.
    ME=${SLURM_JOB_ID:-$$}
    C="$LOCAL_INDEX/pggl-index-$(id -un)-$INDEX_KEY"
    exec 9> "$C.lock"
    release_index() {
        flock 9
        rm -f "$C/users/$ME"
        for m in "$C"/users/*; do
            [ -e "$m" ] || continue
            squeue -h -j "${m##*/}" -o %T 2>/dev/null | grep -q . || rm -f "$m"
        done
        if [ -z "$(ls -A "$C/users" 2>/dev/null)" ]; then
            rm -rf "$C"
            echo "[$(date -Is)] removed the node-local index copy $C"
        fi
        flock -u 9
    }
    trap release_index EXIT
    flock 9
    mkdir -p "$C/users"
    : > "$C/users/$ME"
    echo "[$(date -Is)] staging the graph and indexes in $C"
    python3 "$HELPER" stage-local "$JOBFILE" "$C" "$D/job.local.json" gbz dist min zipcodes
    flock -u 9
    echo "[$(date -Is)] staged"
    JOBFILE="$D/job.local.json"
fi
run_part "lane-$L" "$PARTS/lane-align.cwl" "$JOBFILE" "$D/out.json" --outdir "$D/out"
EOF

# Stage 3: duplicate marking, variant calling and SVs, into out/.
cat > "$W/3-call.sh" <<'EOF'
#!/usr/bin/env bash
source "__W__/env.sh"
python3 "$HELPER" call "$W/job.json" "$W/prepare.out.json" "$W/lanes" "$PARTS/call-$VARIANT.cwl" "$W/call.job.json"
run_part call "$PARTS/call-$VARIANT.cwl" "$W/call.job.json" "$W/out.json" --outdir "$W/out"
EOF
# sbatch runs a spooled copy of each script, so they cannot find env.sh
# relative to themselves; the work dir is written in instead.
sed -i "s#__W__#$W#" "$W/1-prepare.sh" "$W/2-lane.sh" "$W/3-call.sh"
chmod +x "$W/1-prepare.sh" "$W/2-lane.sh" "$W/3-call.sh"

NAME="pggl-$PREFIX"
if [ "$DRY_RUN" = 1 ]; then
    echo "dry run: stage scripts written to $W (run $W/1-prepare.sh by hand to test stage 1)"
    exit 0
fi
PREP_JOB=$(sbatch --parsable $PART_OPT $PREPARE_SBATCH --job-name="$NAME" \
    --output="$W/logs/prepare.%j.out" --error="$W/logs/prepare.%j.err" \
    "$W/1-prepare.sh")
printf 'prepare\t%s\n' "$PREP_JOB" >> "$W/jobs.tsv"
echo "submitted prepare job $PREP_JOB; it submits the lane array and the call job when it finishes"
echo "work dir: $W   (job IDs: $W/jobs.tsv, outputs: $W/out/)"
