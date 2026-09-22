#!/bin/bash
# Stage the build inputs shared by sif-build.def, sif-build-gpu.def and
# sif-build-pangenome-aware.def:
#   sif-stage/  -> vg v1.70.0 static binary, node v20.18.0, cwltool wheels,
#                  biobambam2/bamsormadup (+ libmaus2/libgpgme/libnettle) and
#                  kmc (for Workflows/haplotype-sample.cwl)
#   image/      -> deepvariant-opencode-cpu.sif (CPU base for the localimage
#                  bootstrap) and image/opencode/ (optional opencode tarball
#                  for the GPU SIF)
# Sources are tried in this order:
#   1. $PGGL_SRC            (explicit; e.g. an unpacked offline bundle)
#   2. ./offline-bundle     (created by scripts/fetch-offline-bundle.sh)
#   3. /home/tago/hackathon (the original working repo)
#   4. the original downloads (GitHub releases + nodejs.org + pip + the Ubuntu
#      jammy archive + `apptainer build docker://google/deepvariant:1.10.0`)
# Set PGGL_OFFLINE=1 to forbid step 4 (air-gapped hosts): the script then fails
# with a clear message instead of hanging on a download.  Set
# PGGL_SKIP_BASE_SIF=1 to stage only the build inputs on a host without
# apptainer/singularity.  No docker is required anywhere.
# Run this from the repo root ONCE per checkout, before `singularity build`:
#   ./scripts/stage-sif-assets.sh
set -euo pipefail

if [ -n "${PGGL_SRC:-}" ]; then
    SRC="${PGGL_SRC}"
elif [ -d offline-bundle ]; then
    SRC="offline-bundle"
else
    SRC="/home/tago/hackathon"
fi
OFFLINE="${PGGL_OFFLINE:-0}"

VG_VERSION="v1.70.0"
NODE_VERSION="v20.18.0"
NODE_BASE="node-${NODE_VERSION}-linux-x64"
CWLTOOL_VERSION="${PGGL_CWLTOOL_VERSION:-3.2.20260720092025}"
DV_CPU_IMAGE="google/deepvariant:1.10.0"
# biobambam2 "bamsormadup" (B) for the markdup stage; jammy build (glibc 2.34,
# matches the Ubuntu 22.04 DeepVariant base).
BIOBAMBAM2_VERSION="2.0.183+ds-1"
LIBMAUS2_VERSION="2.0.810+ds-1"
LIBGPGME11_VERSION="1.16.0-1.2ubuntu4"
LIBNETTLE8_VERSION="3.7.3-1build2"
# KMC counts the sample k-mers that drive haplotype sampling; jammy build, same
# glibc as the DeepVariant base.
KMC_VERSION="3.2.1+dfsg-1"

mkdir -p sif-stage sif-stage/wheels image image/opencode

echo "==> source: ${SRC}$([ "${OFFLINE}" = 1 ] && echo ' (offline: downloads disabled)')"

# Fail with an actionable message instead of reaching for the network when the
# host is air-gapped.
need_network() {
    if [ "${OFFLINE}" = 1 ]; then
        echo "ERROR: $1 is missing and PGGL_OFFLINE=1 forbids downloading it." >&2
        echo "       Stage it on an online host with scripts/fetch-offline-bundle.sh" >&2
        echo "       and point PGGL_SRC at the unpacked bundle." >&2
        exit 1
    fi
}

apptainer_bin() {
    command -v apptainer 2>/dev/null || command -v singularity 2>/dev/null || true
}

# curl only counts a few conditions as retryable -- timeouts and some HTTP
# statuses -- and a connection reset part-way through a transfer is not one of
# them. That is exactly how archive.ubuntu.com fails under load ("curl: (56)
# Recv failure: Connection reset by peer"), and one such blip aborts a staging
# run that has already spent several GB and many minutes. --retry-all-errors
# covers it but only exists from curl 7.71, so retry in the shell as well and
# stay version-independent.
CURL_RETRY=( --retry 3 --retry-delay 2 --retry-connrefused )
if curl --retry-all-errors --version >/dev/null 2>&1; then
    CURL_RETRY+=( --retry-all-errors )
fi

fetch() {
    local dest=$1 url=$2 attempt
    for attempt in 1 2 3; do
        if curl -fsSL "${CURL_RETRY[@]}" -o "${dest}" "${url}"; then
            return 0
        fi
        rm -f "${dest}"
        echo "    download failed (attempt ${attempt}/3): ${url}" >&2
        if [ "${attempt}" -lt 3 ]; then
            sleep $(( attempt * 5 ))
        fi
    done
    echo "ERROR: could not download ${url} after 3 attempts" >&2
    return 1
}

# Stage bamsormadup + its private shared libraries into sif-stage/biobambam2/.
# A prebuilt tree (offline bundle / working repo) is copied as is; otherwise the
# jammy debs are unpacked (glibc 2.34, because the DeepVariant 1.10 base is
# Ubuntu 22.04).  Debs are read from, in order: $PGGL_BIOBAMBAM2_DEBS,
# ${SRC}/sif-stage/biobambam2-debs, or the Ubuntu archive.
stage_biobambam2() {
    local dest="sif-stage/biobambam2"
    if [ ! -x "${dest}/bin/bamsormadup" ] && [ -x "${SRC}/sif-stage/biobambam2/bin/bamsormadup" ]; then
        echo "    copying prebuilt tree from ${SRC}/sif-stage/biobambam2"
        rm -rf "${dest}"
        cp -R "${SRC}/sif-stage/biobambam2" "${dest}"
    fi
    if [ ! -x "${dest}/bin/bamsormadup" ]; then
        if ! command -v dpkg-deb >/dev/null; then
            echo "ERROR: no prebuilt sif-stage/biobambam2 tree and no 'dpkg-deb' to unpack" >&2
            echo "       the debs; stage it on a Debian/Ubuntu host (or run" >&2
            echo "       scripts/fetch-offline-bundle.sh there) and copy it over." >&2
            exit 1
        fi
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
                need_network "the biobambam2 deb ${f}"
                echo "    downloading ${f}"
                fetch "${tmp}/${f}" \
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
    # Only meaningful on x86_64 Linux; skip the check when staging from a Mac.
    if command -v ldd >/dev/null \
        && LD_LIBRARY_PATH="${dest}/lib" ldd "${dest}/bin/bamsormadup" 2>/dev/null | grep -q 'not found'; then
        echo "ERROR: bamsormadup has unresolved shared libraries:" >&2
        LD_LIBRARY_PATH="${dest}/lib" ldd "${dest}/bin/bamsormadup" | grep 'not found' >&2
        exit 1
    fi
}

# Stage kmc/kmc_tools into sif-stage/kmc/.  Same shape as stage_biobambam2: a
# prebuilt tree is copied as is, otherwise the jammy deb is unpacked.  kmc is a
# static-ish binary with no private libraries, so there is nothing else to carry.
stage_kmc() {
    local dest="sif-stage/kmc"
    if [ ! -x "${dest}/kmc" ] && [ -x "${SRC}/sif-stage/kmc/kmc" ]; then
        echo "    copying prebuilt tree from ${SRC}/sif-stage/kmc"
        rm -rf "${dest}"
        cp -R "${SRC}/sif-stage/kmc" "${dest}"
    fi
    if [ ! -x "${dest}/kmc" ]; then
        if ! command -v dpkg-deb >/dev/null; then
            echo "ERROR: no prebuilt sif-stage/kmc tree and no 'dpkg-deb' to unpack the deb" >&2
            exit 1
        fi
        mkdir -p "${dest}"
        local tmp f
        tmp="$(mktemp -d)"
        f="kmc_${KMC_VERSION}_amd64.deb"
        if [ -n "${PGGL_KMC_DEB:-}" ] && [ -s "${PGGL_KMC_DEB}" ]; then
            cp -f "${PGGL_KMC_DEB}" "${tmp}/${f}"
        elif [ -s "${SRC}/sif-stage/kmc-debs/${f}" ]; then
            cp -f "${SRC}/sif-stage/kmc-debs/${f}" "${tmp}/${f}"
        else
            need_network "the kmc deb ${f}"
            echo "    downloading ${f}"
            fetch "${tmp}/${f}" "http://archive.ubuntu.com/ubuntu/pool/universe/k/kmc/${f}"
        fi
        dpkg-deb -x "${tmp}/${f}" "${tmp}/root"
        install -m 0755 "${tmp}/root/usr/bin/kmc" "${dest}/kmc"
        install -m 0755 "${tmp}/root/usr/bin/kmc_tools" "${dest}/kmc_tools"
        install -m 0755 "${tmp}/root/usr/bin/kmc_dump" "${dest}/kmc_dump" 2>/dev/null || true
        rm -rf "${tmp}"
    fi
    test -x "${dest}/kmc"
}

echo "==> vg ${VG_VERSION}"
if [ ! -s sif-stage/vg ]; then
    if [ -s "${SRC}/sif-stage/vg" ]; then
        cp -f "${SRC}/sif-stage/vg" sif-stage/vg
    else
        need_network "the vg ${VG_VERSION} binary"
        if ! command -v curl >/dev/null; then
            echo "ERROR: no 'sif-stage/vg' and no curl (GitHub releases) available" >&2
            exit 1
        fi
        echo "    downloading vg from GitHub releases (no docker required)"
        fetch sif-stage/vg \
            "https://github.com/vgteam/vg/releases/download/${VG_VERSION}/vg"
    fi
fi
chmod +x sif-stage/vg
# The staged vg is a linux/x86_64 binary; it only runs here on such a host.
if [ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ]; then
    sif-stage/vg version | head -1
else
    echo "    staged ($(uname -s) host: not executed)"
fi

echo "==> node ${NODE_VERSION}"
if [ ! -x sif-stage/node/bin/node ]; then
    if [ -x "${SRC}/sif-stage/node/bin/node" ]; then
        cp -R "${SRC}/sif-stage/node" sif-stage/node
    else
        need_network "the node ${NODE_VERSION} tarball"
        fetch "/tmp/${NODE_BASE}.tar.xz" \
            "https://nodejs.org/dist/${NODE_VERSION}/${NODE_BASE}.tar.xz"
        tar -C sif-stage -xf "/tmp/${NODE_BASE}.tar.xz"
        mv "sif-stage/${NODE_BASE}" sif-stage/node
    fi
fi
if [ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ]; then
    sif-stage/node/bin/node --version
else
    echo "    staged ($(uname -s) host: not executed)"
fi

echo "==> CPU base SIF (localimage bootstrap)"
if [ "${PGGL_SKIP_BASE_SIF:-0}" = 1 ] && [ ! -s image/deepvariant-opencode-cpu.sif ]; then
    echo "    skipped (PGGL_SKIP_BASE_SIF=1); the SIF cannot be built without it"
elif [ ! -s image/deepvariant-opencode-cpu.sif ]; then
    APPTAINER="$(apptainer_bin)"
    DV_ARCHIVE=""
    for cand in "${SRC}/image/deepvariant-1.10.0.docker-archive.tar" \
                image/deepvariant-1.10.0.docker-archive.tar; do
        if [ -s "$cand" ]; then DV_ARCHIVE="$cand"; break; fi
    done
    if [ -s "${SRC}/image/deepvariant-opencode-cpu.sif" ]; then
        cp -f "${SRC}/image/deepvariant-opencode-cpu.sif" image/
    elif [ -n "${DV_ARCHIVE}" ] && [ -n "${APPTAINER}" ]; then
        echo "    building the base from the staged docker archive ${DV_ARCHIVE}"
        "${APPTAINER}" build image/deepvariant-opencode-cpu.sif \
            "docker-archive:$(cd "$(dirname "${DV_ARCHIVE}")" && pwd)/$(basename "${DV_ARCHIVE}")"
    elif [ -n "${APPTAINER}" ]; then
        need_network "the CPU base image (docker://${DV_CPU_IMAGE})"
        echo "    pulling docker://${DV_CPU_IMAGE} as the base image"
        "${APPTAINER}" build image/deepvariant-opencode-cpu.sif "docker://${DV_CPU_IMAGE}"
    else
        echo "ERROR: 'image/deepvariant-opencode-cpu.sif' not found anywhere and no" >&2
        echo "       apptainer/singularity to build it from docker://${DV_CPU_IMAGE};" >&2
        echo "       copy the SIF into image/ (or run scripts/fetch-offline-bundle.sh" >&2
        echo "       on an online host)." >&2
        exit 1
    fi
fi
if [ -s image/deepvariant-opencode-cpu.sif ]; then
    echo "    image/deepvariant-opencode-cpu.sif ($(du -h image/deepvariant-opencode-cpu.sif | cut -f1))"
fi

echo "==> cwltool wheels (${CWLTOOL_VERSION})"
if [ -z "$(ls -A sif-stage/wheels)" ]; then
    if [ -n "$(ls -A "${SRC}/sif-stage/wheels" 2>/dev/null)" ]; then
        cp "${SRC}/sif-stage/wheels/"*.whl sif-stage/wheels/
    else
        need_network "the cwltool ${CWLTOOL_VERSION} wheels"
        # The wheel set has to resolve for the interpreter that %post installs
        # it with -- python 3.10 in the DeepVariant/Ubuntu 22.04 base -- not for
        # the staging host's.  `pip download --python-version` only steers wheel
        # *tag* selection; environment markers are still evaluated against the
        # running interpreter, so on a host with python >= 3.11 a dependency
        # like rdflib's `isodate; python_version < "3.11"` is silently left out
        # and `pip install --no-index` then fails inside the build.  Resolving
        # in the base image (staged just above) is exact, so it is preferred.
        APPTAINER="$(apptainer_bin)"
        if [ -n "${APPTAINER}" ] && [ -s image/deepvariant-opencode-cpu.sif ]; then
            echo "    resolving inside the base image (its own python 3.10)"
            "${APPTAINER}" exec --cleanenv --bind "${PWD}:/repo" \
                image/deepvariant-opencode-cpu.sif \
                python3 -m pip download --dest /repo/sif-stage/wheels \
                    --only-binary=:all: "cwltool==${CWLTOOL_VERSION}"
        else
            echo "    WARNING: no base image available to resolve in; falling back"
            echo "             to the host $(python3 -V 2>&1).  On anything but"
            echo "             python 3.10 this can miss marker-gated dependencies."
            python3 -m pip download --dest sif-stage/wheels --only-binary=:all: \
                --python-version 3.10 --implementation cp --abi cp310 \
                --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 \
                --platform manylinux_2_28_x86_64 \
                "cwltool==${CWLTOOL_VERSION}"
        fi
    fi
fi
echo "    wheels: $(ls sif-stage/wheels | wc -l)"

echo "==> opencode baseline tarball (GPU SIF, optional)"
if [ ! -s image/opencode/opencode-linux-x64-baseline.tar.gz ]; then
    for cand in "${SRC}/image/opencode/opencode-linux-x64-baseline.tar.gz" \
                "${SRC}/image/opencode-linux-x64-baseline.tar.gz" \
                image/opencode-linux-x64-baseline.tar.gz; do
        if [ -s "$cand" ]; then
            cp -f "$cand" image/opencode/opencode-linux-x64-baseline.tar.gz
            break
        fi
    done
fi
if [ -s image/opencode/opencode-linux-x64-baseline.tar.gz ]; then
    echo "    staged (the GPU image will ship opencode)"
else
    echo "    not found - the GPU image is built without opencode (it is an"
    echo "    optional dev tool, the pipeline does not use it)"
fi

echo "==> bamsormadup (biobambam2 ${BIOBAMBAM2_VERSION})"
stage_biobambam2
echo "    bamsormadup: $(ls -l sif-stage/biobambam2/bin/bamsormadup | awk '{print $5" bytes"}'), libs: $(ls sif-stage/biobambam2/lib | wc -l)"

echo "==> kmc ${KMC_VERSION}"
stage_kmc
echo "    kmc: $(sif-stage/kmc/kmc 2>&1 | head -1)"

echo
echo "Staged. Next (on a host with singularity/apptainer):"
echo "  singularity build deepvariant-opencode-cpu-vg.sif sif-build.def"
echo "  singularity build deepvariant-opencode-gpu-vg.sif sif-build-gpu.def"
echo "  singularity build deepvariant-pangenome-aware-cpu-vg.sif sif-build-pangenome-aware.def"
