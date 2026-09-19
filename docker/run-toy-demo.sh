#!/usr/bin/env bash
#
# Runs one toy-demo job inside the toy runtime image (docker/Dockerfile.toy),
# with cwltool --no-container, i.e. exactly the way the SIF images run it.
# The image is built on first use.
#
# Usage:
#   docker/run-toy-demo.sh [job.json] [outdir] [extra cwltool args...]
#
# Environment:
#   IMAGE     image tag to build/use      (default pggl-toy:latest)
#   WORKFLOW  workflow to run             (default Workflows/germline-pangenome-cpu.cwl)
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${IMAGE:-pggl-toy:latest}
WORKFLOW=${WORKFLOW:-Workflows/germline-pangenome-cpu.cwl}
JOB=${1:-tests/toy/jobs/toy_job.json}
OUTDIR=${2:-tests/toy/demo_out/docker_fastq_track}
shift 2 2>/dev/null || true

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "==> building $IMAGE (first run only)" >&2
    docker build --platform linux/amd64 -t "$IMAGE" -f "$REPO/docker/Dockerfile.toy" "$REPO/docker"
fi

mkdir -p "$REPO/$OUTDIR"

exec docker run --platform linux/amd64 --rm \
    -v "$REPO:/work" -w /work \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    "$IMAGE" \
    cwltool --no-container --outdir "$OUTDIR" "$@" "$WORKFLOW" "$JOB"
