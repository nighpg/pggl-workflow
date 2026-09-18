#!/bin/bash
# Stage the build inputs required by sif-build.def / sif-build-gpu.def:
#   sif-stage/  -> vg v1.70.0 static binary, node v20.18.0, cwltool wheels and
#                  biobambam2/bamsormadup (+ libmaus2/libgpgme/libnettle)
#   image/      -> deepvariant-opencode-cpu.sif (CPU base for the localimage
#                  bootstrap) and opencode-linux-x64-baseline.tar.gz (GPU SIF)
# Default source is the working repo (hackathon); when it is unavailable the
# script falls back to the original downloads (GitHub releases + nodejs.org +
# pip + the Ubuntu jammy archive).  No docker is required anywhere.
# Run this from the repo root ONCE per checkout, before `singularity build`:
#   ./scripts/stage-sif-assets.sh
set -euo pipefail

SRC="${PGGL_SRC:-/home/tago/hackathon}"
VG_VERSION="v1.70.0"
NODE_VERSION="v20.18.0"
NODE_BASE="node-${NODE_VERSION}-linux-x64"
CWLTOOL_VERSION="3.2.20260720092025"
# biobambam2 "bamsormadup" (B) for the markdup stage; jammy build (glibc 2.34,
# matches the Ubuntu 22.04 DeepVariant base).
BIOBAMBAM2_VERSION="2.0.183+ds-1"
LIBMAUS2_VERSION="2.0.810+ds-1"
LIBGPGME11_VERSION="1.16.0-1.2ubuntu4"
LIBNETTLE8_VERSION="3.7.3-1build2"

mkdir -p sif-stage sif-stage/wheels image

# Stage bamsormadup + its private shared libraries into sif-stage/biobambam2/.
# The jammy debs are used (glibc 2.34) because the DeepVariant 1.10 base is
# Ubuntu 22.04; they are read from, in order: $PGGL_BIOBAMBAM2_DEBS,
# ${SRC}/sif-stage/biobambam2-debs, or the Ubuntu archive.
stage_biobambam2() {
    local dest="sif-stage/biobambam2"
    if [ ! -x "${dest}/bin/bamsormadup" ]; then
        mkdir -p "${dest}/bin" "${dest}/lib"
        local tmp
        tmp="$(mktemp -d)"
        local arch=amd64
        local -a pkgs=(
            "universe/b/biobambam2/biobambam2_${BIOBAMBAM2_VERSION}_${arch}.deb"
            "universe/libm/libmaus2/libmaus2-2_${LIBMAUS2_VERSION}_${arch}.deb"
            "main/g/gpgme1.0/libgpgme11_${LIBGPGME11_VERSION}_${arch}.deb"
            "main/n/nettle/libnettle8_${LIBNETTLE8_VERSION}_${arch}.deb"
        )
        local rel f
        for rel in "${pkgs[@]}"; do
            f="$(basename "$rel")"
            if [ -n "${PGGL_BIOBAMBAM2_DEBS:-}" ] && [ -s "${PGGL_BIOBAMBAM2_DEBS}/${f}" ]; then
                cp -f "${PGGL_BIOBAMBAM2_DEBS}/${f}" "${tmp}/${f}"
            elif [ -s "${SRC}/sif-stage/biobambam2-debs/${f}" ]; then
                cp -f "${SRC}/sif-stage/biobambam2-debs/${f}" "${tmp}/${f}"
            else
                echo "    downloading ${f}"
                curl -fsSLo "${tmp}/${f}" \
                    "http://archive.ubuntu.com/ubuntu/pool/${rel}"
            fi
            dpkg-deb -x "${tmp}/${f}" "${tmp}/root"
        done
        install -m 0755 "${tmp}/root/usr/bin/bamsormadup" "${dest}/bin/bamsormadup"
        cp -a "${tmp}/root/usr/lib/x86_64-linux-gnu/libmaus2"*.so* "${dest}/lib/" 2>/dev/null || true
        cp -a "${tmp}/root/usr/lib/x86_64-linux-gnu/libgpgme"*.so* "${dest}/lib/" 2>/dev/null || true
        cp -a "${tmp}/root/usr/lib/x86_64-linux-gnu/libnettle.so.8"* "${dest}/lib/" 2>/dev/null || true
        rm -rf "${tmp}"
    fi
    test -x "${dest}/bin/bamsormadup"
    test -n "$(ls -A "${dest}/lib")"
    if LD_LIBRARY_PATH="${dest}/lib" ldd "${dest}/bin/bamsormadup" | grep -q 'not found'; then
        echo "ERROR: bamsormadup has unresolved shared libraries:" >&2
        LD_LIBRARY_PATH="${dest}/lib" ldd "${dest}/bin/bamsormadup" | grep 'not found' >&2
        exit 1
    fi
}

echo "==> vg ${VG_VERSION}"
if [ ! -s sif-stage/vg ]; then
    if [ -s "${SRC}/sif-stage/vg" ]; then
        cp -f "${SRC}/sif-stage/vg" sif-stage/vg
    elif command -v curl >/dev/null; then
        echo "    downloading vg from GitHub releases (no docker required)"
        curl -fsSLo sif-stage/vg \
            "https://github.com/vgteam/vg/releases/download/${VG_VERSION}/vg"
    else
        echo "ERROR: no 'sif-stage/vg' and no curl (GitHub releases) available" >&2
        exit 1
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

echo "==> bamsormadup (biobambam2 ${BIOBAMBAM2_VERSION})"
stage_biobambam2
echo "    bamsormadup: $(ls -l sif-stage/biobambam2/bin/bamsormadup | awk '{print $5" bytes"}'), libs: $(ls sif-stage/biobambam2/lib | wc -l)"

echo
echo "Staged. Next (on a host with singularity/apptainer):"
echo "  singularity build deepvariant-opencode-cpu-vg.sif sif-build.def"
echo "  singularity build deepvariant-opencode-gpu-vg.sif sif-build-gpu.def"