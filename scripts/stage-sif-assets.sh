#!/bin/bash
# Stage the build inputs required by sif-build.def / sif-build-gpu.def:
#   sif-stage/  -> vg v1.70.0 static binary, node v20.18.0, cwltool wheels
#   image/      -> deepvariant-opencode-cpu.sif (CPU base for the localimage
#                  bootstrap) and opencode-linux-x64-baseline.tar.gz (GPU SIF)
# Default source is the working repo (hackathon); when it is unavailable the
# script falls back to the original downloads (docker + nodejs.org + pip).
# Run this from the repo root ONCE per checkout, before `singularity build`:
#   ./scripts/stage-sif-assets.sh
set -euo pipefail

SRC="${PGGL_SRC:-/home/tago/hackathon}"
VG_VERSION="v1.70.0"
NODE_VERSION="v20.18.0"
NODE_BASE="node-${NODE_VERSION}-linux-x64"
CWLTOOL_VERSION="3.2.20260720092025"

mkdir -p sif-stage sif-stage/wheels image

fetch_vg() {
    docker create --name vgstage "quay.io/vgteam/vg:${VG_VERSION}" >/dev/null
    docker cp "vgstage:/vg" sif-stage/vg
    docker rm vgstage >/dev/null
}

echo "==> vg ${VG_VERSION}"
if [ ! -s sif-stage/vg ]; then
    if [ -s "${SRC}/sif-stage/vg" ]; then
        cp -f "${SRC}/sif-stage/vg" sif-stage/vg
    elif command -v docker >/dev/null; then
        fetch_vg
    else
        echo "ERROR: no 'sif-stage/vg' and no docker to fetch it from" >&2; exit 1
    fi
fi
chmod +x sif-stage/vg
sif-stage/vg version | head -1

echo "==> node ${NODE_VERSION}"
if [ ! -x sif-stage/node/bin/node ]; then
    if [ -x "${SRC}/sif-stage/node/bin/node" ]; then
        cp -r "${SRC}/sif-stage/node" sif-stage/node
    else
        curl -fsSLo "/tmp/${NODE_BASE}.tar.xz" \
            "https://nodejs.org/dist/${NODE_VERSION}/${NODE_BASE}.tar.xz"
        tar -C sif-stage -xf "/tmp/${NODE_BASE}.tar.xz"
        mv "sif-stage/${NODE_BASE}" sif-stage/node
    fi
fi
sif-stage/node/bin/node --version

echo "==> cwltool wheels (${CWLTOOL_VERSION})"
if [ -z "$(ls -A sif-stage/wheels)" ]; then
    if [ -n "$(ls -A "${SRC}/sif-stage/wheels" 2>/dev/null)" ]; then
        cp "${SRC}/sif-stage/wheels/"*.whl sif-stage/wheels/
    else
        python3 -m pip download --dest sif-stage/wheels --only-binary=:all: \
            "cwltool==${CWLTOOL_VERSION}"
    fi
fi
echo "    wheels: $(ls sif-stage/wheels | wc -l)"

echo "==> CPU base SIF (localimage bootstrap)"
if [ ! -s image/deepvariant-opencode-cpu.sif ]; then
    if [ -s "${SRC}/image/deepvariant-opencode-cpu.sif" ]; then
        cp -f "${SRC}/image/deepvariant-opencode-cpu.sif" image/
    else
        echo "ERROR: 'image/deepvariant-opencode-cpu.sif' not found anywhere;" >&2
        echo "       copy it into image/ (it is the working CPU environment)" >&2
        exit 1
    fi
fi

echo "==> opencode baseline tarball (GPU SIF)"
if [ ! -s image/opencode-linux-x64-baseline.tar.gz ]; then
    if [ -s "${SRC}/image/opencode-linux-x64-baseline.tar.gz" ]; then
        cp -f "${SRC}/image/opencode-linux-x64-baseline.tar.gz" image/
    else
        echo "ERROR: 'image/opencode-linux-x64-baseline.tar.gz' not found;" >&2
        echo "       copy it into image/ (no stable public URL exists)" >&2
        exit 1
    fi
fi

echo
echo "Staged. Next (on a host with singularity/apptainer):"
echo "  singularity build deepvariant-opencode-cpu-vg.sif sif-build.def"
echo "  singularity build deepvariant-opencode-gpu-vg.sif sif-build-gpu.def"