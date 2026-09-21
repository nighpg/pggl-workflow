#!/bin/bash
# Collect EVERYTHING the pangenome workflow needs into one directory that can be
# carried to an air-gapped (offline) host on a disk / via a file transfer.
#
# Run this on an ONLINE host (the only step that needs the network):
#
#   ./scripts/fetch-offline-bundle.sh              # apptainer image + assets
#   ./scripts/fetch-offline-bundle.sh --gpu        # also the GPU image
#   ./scripts/fetch-offline-bundle.sh --archive    # + a single .tar to copy
#
# On the offline host:
#
#   tar xf pggl-offline-bundle-*.tar               # (when --archive was used)
#   ./scripts/setup-offline.sh --bundle offline-bundle --verify
#
# What ends up in the bundle:
#   sif/            ready-to-run apptainer images (built here when apptainer is
#                   available) -> the offline host needs nothing else
#   image/          base images (docker://google/deepvariant:...) as .sif or, on
#                   a host with only docker, as docker-archive tarballs, so the
#                   offline host can still BUILD the images itself
#   sif-stage/      vg, node, cwltool wheels, bamsormadup (+libs) build inputs
#   tool-images/    optional per-tool SIFs for `cwltool --singularity`
#   repo/           snapshot of this checkout (workflows, tools, toy data)
#   SHA256SUMS, BUNDLE_INFO.txt, README-offline.md
#
# NOT included: the pangenome graph + giraffe indexes + linear reference
# (~54 GB for the T2T-CHM13 backbone).  Copy those to the offline host
# separately; see docs/OFFLINE.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

OUTDIR="${REPO}/offline-bundle"
WANT_GPU=0
WANT_BUILD=1
WANT_BASE=0
WANT_TOOL_IMAGES=0
WANT_REPO=1
WANT_ARCHIVE=0
SPLIT_SIZE=""

DV_CPU_IMAGE="google/deepvariant:1.10.0"
DV_GPU_IMAGE="google/deepvariant:1.10.0-gpu"
CPU_SIF="deepvariant-opencode-cpu-vg.sif"
GPU_SIF="deepvariant-opencode-gpu-vg.sif"

usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
    cat <<'USAGE'

Options:
  -o, --outdir DIR   bundle directory (default ./offline-bundle)
      --gpu          also fetch/build the GPU image (large: ~10 GB base)
      --no-build     only fetch the build inputs, do not build the runnable SIFs
      --with-base    keep the base images in the bundle even when the runnable
                     SIFs were built here (lets the offline host rebuild)
      --tool-images  also fetch the per-tool docker images (vg, samtools, ...)
                     as SIFs, for running the CWL with `cwltool --singularity`
      --no-repo      do not include the repo snapshot
      --archive      pack the bundle into a single .tar next to it
      --split SIZE   split that .tar into SIZE chunks (e.g. 20G); implies
                     --archive
  -h, --help         this help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--outdir)    OUTDIR="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --gpu)          WANT_GPU=1; shift ;;
        --no-build)     WANT_BUILD=0; shift ;;
        --with-base)    WANT_BASE=1; shift ;;
        --tool-images)  WANT_TOOL_IMAGES=1; shift ;;
        --no-repo)      WANT_REPO=0; shift ;;
        --archive)      WANT_ARCHIVE=1; shift ;;
        --split)        SPLIT_SIZE="$2"; WANT_ARCHIVE=1; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

APPTAINER="$(command -v apptainer 2>/dev/null || command -v singularity 2>/dev/null || true)"

# A def-file build runs %post as root, which apptainer escalates to on its own.
# Without an /etc/subuid entry it falls back to a root-mapped user namespace and
# injects its own libfakeroot; that library is linked against a newer glibc than
# the DeepVariant base (Ubuntu 22.04, glibc 2.35) provides, so %post dies with
#   /bin/sh: .../libc.so.6: version `GLIBC_2.38' not found
# The root-mapped namespace on its own is all these %post sections need -- they
# only copy files and pip-install -- so tell apptainer to skip the fakeroot
# command in that case. singularity-ce has no such flag, hence the probe.
DEF_BUILD_ARGS=()
if [ -n "${APPTAINER}" ] \
   && ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
   && "${APPTAINER}" build --ignore-fakeroot-command --help >/dev/null 2>&1; then
    DEF_BUILD_ARGS+=( --ignore-fakeroot-command )
fi
DOCKER="$(command -v docker 2>/dev/null || true)"

if [ -z "${APPTAINER}" ] && [ -z "${DOCKER}" ]; then
    echo "ERROR: neither apptainer/singularity nor docker is available; one of" >&2
    echo "       them is needed to fetch the container images." >&2
    exit 1
fi
if [ -z "${APPTAINER}" ]; then
    echo "NOTE: no apptainer/singularity here - images are fetched as docker"
    echo "      archives and the offline host converts/builds them (needs"
    echo "      apptainer there).  Re-run this on a host with apptainer to ship"
    echo "      ready-to-run SIFs instead."
    WANT_BUILD=0
    WANT_BASE=1
fi

mkdir -p "${OUTDIR}"/{sif,image,sif-stage,repo}

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
hsize() { du -sh "$1" 2>/dev/null | cut -f1; }

# Fetch one docker image as an apptainer SIF, or (no apptainer) as a
# docker-archive tarball that the offline host can build from.
# fetch_image <docker-ref> <dest-without-extension>
fetch_image() {
    local ref="$1" dest="$2"
    if [ -n "${APPTAINER}" ]; then
        if [ -s "${dest}.sif" ]; then
            echo "    ${dest}.sif already present ($(hsize "${dest}.sif"))"
            return
        fi
        echo "    apptainer build ${dest}.sif docker://${ref}"
        "${APPTAINER}" build "${dest}.sif" "docker://${ref}"
    else
        if [ -s "${dest}.docker-archive.tar" ]; then
            echo "    ${dest}.docker-archive.tar already present ($(hsize "${dest}.docker-archive.tar"))"
            return
        fi
        echo "    docker pull ${ref} -> ${dest}.docker-archive.tar"
        "${DOCKER}" pull --platform linux/amd64 "${ref}"
        "${DOCKER}" save "${ref}" -o "${dest}.docker-archive.tar"
    fi
}

echo "==> [1/6] base image: ${DV_CPU_IMAGE}"
if [ -n "${APPTAINER}" ]; then
    # sif-build.def bootstraps from this exact path.
    mkdir -p "${REPO}/image"
    if [ ! -s "${REPO}/image/deepvariant-opencode-cpu.sif" ]; then
        if [ -s "${OUTDIR}/image/deepvariant-opencode-cpu.sif" ]; then
            cp -f "${OUTDIR}/image/deepvariant-opencode-cpu.sif" "${REPO}/image/"
        else
            "${APPTAINER}" build "${REPO}/image/deepvariant-opencode-cpu.sif" "docker://${DV_CPU_IMAGE}"
        fi
    fi
    echo "    image/deepvariant-opencode-cpu.sif ($(hsize "${REPO}/image/deepvariant-opencode-cpu.sif"))"
else
    fetch_image "${DV_CPU_IMAGE}" "${OUTDIR}/image/deepvariant-1.10.0"
    mkdir -p "${REPO}/image"
    cp -f "${OUTDIR}/image/deepvariant-1.10.0.docker-archive.tar" "${REPO}/image/"
fi

if [ "${WANT_GPU}" = 1 ]; then
    echo "==> base image: ${DV_GPU_IMAGE}"
    fetch_image "${DV_GPU_IMAGE}" "${OUTDIR}/image/deepvariant-1.10.0-gpu"
fi

echo "==> [2/6] build inputs (vg, node, cwltool wheels, bamsormadup)"
if [ -z "${APPTAINER}" ]; then
    # No apptainer -> the base SIF cannot be built here; the assets still can.
    PGGL_SKIP_BASE_SIF=1 PGGL_SRC="${PGGL_SRC:-${OUTDIR}}" "${REPO}/scripts/stage-sif-assets.sh"
else
    PGGL_SRC="${PGGL_SRC:-${OUTDIR}}" "${REPO}/scripts/stage-sif-assets.sh"
fi
rm -rf "${OUTDIR}/sif-stage"
cp -R "${REPO}/sif-stage" "${OUTDIR}/sif-stage"
if [ -s "${REPO}/image/opencode/opencode-linux-x64-baseline.tar.gz" ]; then
    mkdir -p "${OUTDIR}/image/opencode"
    cp -f "${REPO}/image/opencode/opencode-linux-x64-baseline.tar.gz" "${OUTDIR}/image/opencode/"
fi

echo "==> [3/6] runnable workflow images"
if [ "${WANT_BUILD}" = 1 ]; then
    if [ ! -s "${OUTDIR}/sif/${CPU_SIF}" ]; then
        echo "    building ${CPU_SIF} (this takes a few minutes)"
        "${APPTAINER}" build ${DEF_BUILD_ARGS[@]+"${DEF_BUILD_ARGS[@]}"} \
            "${OUTDIR}/sif/${CPU_SIF}" "${REPO}/sif-build.def"
    fi
    echo "    sif/${CPU_SIF} ($(hsize "${OUTDIR}/sif/${CPU_SIF}"))"
    if [ "${WANT_GPU}" = 1 ]; then
        if [ ! -s "${OUTDIR}/sif/${GPU_SIF}" ]; then
            # sif-build-gpu.def bootstraps from docker://; reuse the base image
            # fetched above instead of pulling those ~10 GB a second time.
            gpu_def="${REPO}/sif-build-gpu.def"
            gpu_base="${OUTDIR}/image/deepvariant-1.10.0-gpu.sif"
            if [ -s "${gpu_base}" ]; then
                mkdir -p "${REPO}/.offline-build"
                gpu_def="${REPO}/.offline-build/sif-build-gpu.local.def"
                sed -e 's|^Bootstrap: docker$|Bootstrap: localimage|' \
                    -e "s|^From: ${DV_GPU_IMAGE}\$|From: ${gpu_base}|" \
                    "${REPO}/sif-build-gpu.def" > "${gpu_def}"
                grep -q "^From: ${gpu_base}$" "${gpu_def}" \
                    || { echo "ERROR: could not rewrite the GPU bootstrap" >&2; exit 1; }
                echo "    building ${GPU_SIF} from the staged base image"
            else
                echo "    building ${GPU_SIF}"
            fi
            "${APPTAINER}" build ${DEF_BUILD_ARGS[@]+"${DEF_BUILD_ARGS[@]}"} \
                "${OUTDIR}/sif/${GPU_SIF}" "${gpu_def}"
        fi
        echo "    sif/${GPU_SIF} ($(hsize "${OUTDIR}/sif/${GPU_SIF}"))"
    fi
else
    echo "    skipped (--no-build): the offline host builds them from image/ + sif-stage/"
fi

# The base images are only needed on the offline host when it has to build the
# workflow images itself; drop them from the bundle otherwise (they are ~5-10 GB).
if [ "${WANT_BUILD}" = 1 ] && [ "${WANT_BASE}" = 0 ]; then
    rm -f "${OUTDIR}"/image/deepvariant-*.sif "${OUTDIR}"/image/*.docker-archive.tar
    echo "    base images left out of the bundle (pass --with-base to keep them)"
elif [ -n "${APPTAINER}" ]; then
    cp -f "${REPO}/image/deepvariant-opencode-cpu.sif" "${OUTDIR}/image/"
fi

echo "==> [4/6] per-tool images"
if [ "${WANT_TOOL_IMAGES}" = 1 ]; then
    mkdir -p "${OUTDIR}/tool-images"
    # cwltool looks up a pulled image as "<dockerPull with / replaced by _>.sif"
    # in $CWL_SINGULARITY_CACHE, so keep exactly that naming.
    refs=$(grep -h 'dockerPull:' "${REPO}"/Tools/*.cwl "${REPO}"/Workflows/*.cwl \
           | awk '{print $2}' | sort -u)
    for ref in ${refs}; do
        case "${ref}" in
            *-gpu) [ "${WANT_GPU}" = 1 ] || { echo "    skipping ${ref} (no --gpu)"; continue; } ;;
        esac
        name="$(echo "${ref}" | tr '/' '_')"
        if [ -n "${APPTAINER}" ]; then
            [ -s "${OUTDIR}/tool-images/${name}.sif" ] || \
                "${APPTAINER}" build "${OUTDIR}/tool-images/${name}.sif" "docker://${ref}"
            echo "    tool-images/${name}.sif"
        else
            fetch_image "${ref}" "${OUTDIR}/tool-images/${name}"
        fi
    done
else
    echo "    skipped (pass --tool-images to include them)"
fi

echo "==> [5/6] repo snapshot"
if [ "${WANT_REPO}" = 1 ] && git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1; then
    rev="$(git -C "${REPO}" rev-parse --short HEAD)"
    git -C "${REPO}" archive --format=tar.gz --prefix="pggl-workflow/" \
        -o "${OUTDIR}/repo/pggl-workflow-${rev}.tar.gz" HEAD
    echo "    repo/pggl-workflow-${rev}.tar.gz (HEAD=${rev}, $(hsize "${OUTDIR}/repo/pggl-workflow-${rev}.tar.gz"))"
    if [ -n "$(git -C "${REPO}" status --porcelain)" ]; then
        echo "    WARNING: the checkout has uncommitted changes - they are NOT in the"
        echo "             snapshot (commit them first if the offline host needs them)"
    fi
else
    rmdir "${OUTDIR}/repo" 2>/dev/null || true
    echo "    skipped"
fi

echo "==> [6/6] manifest and checksums"
cat > "${OUTDIR}/BUNDLE_INFO.txt" <<INFO
pggl-workflow offline bundle
created      : $(date '+%Y-%m-%d %H:%M:%S %Z')
created on   : $(uname -s) $(uname -m), $(hostname 2>/dev/null || echo host)
repo HEAD    : $(git -C "${REPO}" rev-parse HEAD 2>/dev/null || echo 'n/a')
builder      : ${APPTAINER:-none} $("${APPTAINER:-true}" --version 2>/dev/null || true)
CPU base     : ${DV_CPU_IMAGE}
GPU base     : $([ "${WANT_GPU}" = 1 ] && echo "${DV_GPU_IMAGE}" || echo 'not included')
runnable SIF : $([ "${WANT_BUILD}" = 1 ] && echo 'yes (sif/)' || echo 'no - build on the offline host')

contents:
$(cd "${OUTDIR}" && du -h -d 2 . | sort -k2)
INFO

cp -f "${REPO}/docs/OFFLINE.md" "${OUTDIR}/README-offline.md" 2>/dev/null || true

( cd "${OUTDIR}" && : > SHA256SUMS.tmp
  find . -type f ! -name 'SHA256SUMS*' -print | LC_ALL=C sort | while read -r f; do
      sha256_of "$f" >> SHA256SUMS.tmp
  done
  mv SHA256SUMS.tmp SHA256SUMS )
echo "    $(wc -l < "${OUTDIR}/SHA256SUMS") files checksummed"

if [ "${WANT_ARCHIVE}" = 1 ]; then
    stamp="$(date '+%Y%m%d')"
    tarball="$(dirname "${OUTDIR}")/pggl-offline-bundle-${stamp}.tar"
    echo "==> packing ${tarball}"
    tar -C "$(dirname "${OUTDIR}")" -cf "${tarball}" "$(basename "${OUTDIR}")"
    sha256_of "${tarball}" > "${tarball}.sha256"
    if [ -n "${SPLIT_SIZE}" ]; then
        echo "    splitting into ${SPLIT_SIZE} chunks"
        split -b "${SPLIT_SIZE}" "${tarball}" "${tarball}.part-"
        rm -f "${tarball}"
        echo "    reassemble with: cat ${tarball##*/}.part-* > ${tarball##*/}"
    fi
    echo "    $(ls -lh "${tarball}"* | awk '{print $9" ("$5")"}' | tr '\n' ' ')"
fi

echo
echo "Bundle ready: ${OUTDIR} ($(hsize "${OUTDIR}"))"
echo "Copy it (or the .tar) to the offline host, then run there:"
echo "  ./scripts/setup-offline.sh --bundle <bundle dir> --verify"
