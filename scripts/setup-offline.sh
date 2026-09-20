#!/bin/bash
# Install an offline bundle (scripts/fetch-offline-bundle.sh) on an air-gapped
# host: verify it, put the apptainer image(s) in place - building them locally
# when the bundle only carries the build inputs - and smoke-test the result.
# Nothing here touches the network.
#
#   ./scripts/setup-offline.sh --bundle offline-bundle --verify
#   ./scripts/setup-offline.sh --bundle pggl-offline-bundle-20260920.tar --verify
#
# After this, run the workflow entirely from the image:
#
#   apptainer exec deepvariant-opencode-cpu-vg.sif \
#     /opt/pangenome/run-pangenome.sh --cram ... --prefix SAMPLE --outdir out/
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

BUNDLE="${REPO}/offline-bundle"
INSTALL_DIR="${REPO}"
WANT_GPU=0
WANT_BUILD=auto
WANT_VERIFY=0
CHECKSUM=1

CPU_SIF="deepvariant-opencode-cpu-vg.sif"
GPU_SIF="deepvariant-opencode-gpu-vg.sif"

usage() {
    cat <<'USAGE'
Usage: scripts/setup-offline.sh [options]

  -b, --bundle PATH    bundle directory or .tar produced by
                       scripts/fetch-offline-bundle.sh (default ./offline-bundle)
  -d, --install-dir D  where to put the runnable .sif (default: repo root)
      --gpu            also install/build the GPU image
      --build          build the images from the bundle even if a prebuilt
                       .sif is shipped in it
      --no-build       never build; fail if the bundle has no runnable .sif
      --verify         validate the workflow inside the image and run the toy
                       demo (a couple of minutes)
      --no-checksum    skip the SHA256SUMS verification
  -h, --help           this help
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bundle)      BUNDLE="$2"; shift 2 ;;
        -d|--install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --gpu)            WANT_GPU=1; shift ;;
        --build)          WANT_BUILD=force; shift ;;
        --no-build)       WANT_BUILD=never; shift ;;
        --verify)         WANT_VERIFY=1; shift ;;
        --no-checksum)    CHECKSUM=0; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

APPTAINER="$(command -v apptainer 2>/dev/null || command -v singularity 2>/dev/null || true)"

echo "==> [1/5] bundle"
if [ -f "${BUNDLE}" ]; then
    case "${BUNDLE}" in
        *.tar|*.tar.gz|*.tgz)
            dest="$(cd "$(dirname "${BUNDLE}")" && pwd)"
            echo "    unpacking ${BUNDLE} into ${dest}"
            tar -C "${dest}" -xf "${BUNDLE}"
            BUNDLE="${dest}/$(tar -tf "${BUNDLE}" | head -1 | cut -d/ -f1)"
            ;;
        *) echo "ERROR: --bundle must be a directory or a .tar archive" >&2; exit 1 ;;
    esac
fi
[ -d "${BUNDLE}" ] || { echo "ERROR: bundle not found: ${BUNDLE}" >&2; exit 1; }
BUNDLE="$(cd "${BUNDLE}" && pwd)"
echo "    ${BUNDLE}"
[ -f "${BUNDLE}/BUNDLE_INFO.txt" ] && sed -n '1,8p' "${BUNDLE}/BUNDLE_INFO.txt" | sed 's/^/    /'

echo "==> [2/5] checksums"
if [ "${CHECKSUM}" = 1 ] && [ -f "${BUNDLE}/SHA256SUMS" ]; then
    if command -v sha256sum >/dev/null; then CHK="sha256sum -c --quiet"
    elif command -v shasum >/dev/null; then CHK="shasum -a 256 -c -s"
    else CHK=""; fi
    if [ -n "${CHK}" ]; then
        ( cd "${BUNDLE}" && ${CHK} SHA256SUMS ) \
            && echo "    OK ($(wc -l < "${BUNDLE}/SHA256SUMS") files)" \
            || { echo "ERROR: checksum mismatch - the bundle was damaged in transfer" >&2; exit 1; }
    else
        echo "    skipped (no sha256sum/shasum on this host)"
    fi
else
    echo "    skipped"
fi

echo "==> [3/5] installing"
mkdir -p "${INSTALL_DIR}"
installed_cpu=""
installed_gpu=""
if [ -s "${BUNDLE}/sif/${CPU_SIF}" ] && [ "${WANT_BUILD}" != force ]; then
    cp -f "${BUNDLE}/sif/${CPU_SIF}" "${INSTALL_DIR}/"
    installed_cpu="${INSTALL_DIR}/${CPU_SIF}"
    echo "    ${installed_cpu}"
fi
if [ "${WANT_GPU}" = 1 ] && [ -s "${BUNDLE}/sif/${GPU_SIF}" ] && [ "${WANT_BUILD}" != force ]; then
    cp -f "${BUNDLE}/sif/${GPU_SIF}" "${INSTALL_DIR}/"
    installed_gpu="${INSTALL_DIR}/${GPU_SIF}"
    echo "    ${installed_gpu}"
fi
if [ -d "${BUNDLE}/tool-images" ]; then
    mkdir -p "${REPO}/tool-images"
    cp -f "${BUNDLE}/tool-images/"*.sif "${REPO}/tool-images/" 2>/dev/null || true
    echo "    tool-images/ (export CWL_SINGULARITY_CACHE=${REPO}/tool-images to use"
    echo "    them with 'cwltool --singularity')"
fi

echo "==> [4/5] images"
need_build=0
[ -z "${installed_cpu}" ] && need_build=1
[ "${WANT_GPU}" = 1 ] && [ -z "${installed_gpu}" ] && need_build=1
if [ "${need_build}" = 1 ] && [ "${WANT_BUILD}" = never ]; then
    echo "ERROR: the bundle carries no runnable .sif and --no-build was given." >&2
    exit 1
fi
if [ "${need_build}" = 1 ]; then
    [ -n "${APPTAINER}" ] || {
        echo "ERROR: no apptainer/singularity on this host, and the bundle carries" >&2
        echo "       no prebuilt image.  Install apptainer, or re-create the bundle" >&2
        echo "       on an online host that has it (it then ships sif/*.sif)." >&2
        exit 1; }
    echo "    staging build inputs from the bundle (offline)"
    PGGL_OFFLINE=1 PGGL_SRC="${BUNDLE}" "${REPO}/scripts/stage-sif-assets.sh"

    if [ -z "${installed_cpu}" ]; then
        echo "    building ${CPU_SIF}"
        "${APPTAINER}" build "${INSTALL_DIR}/${CPU_SIF}" "${REPO}/sif-build.def"
        installed_cpu="${INSTALL_DIR}/${CPU_SIF}"
    fi

    if [ "${WANT_GPU}" = 1 ] && [ -z "${installed_gpu}" ]; then
        # sif-build-gpu.def bootstraps from docker://; offline it has to come
        # from the base image staged in the bundle.
        base_sif="${BUNDLE}/image/deepvariant-1.10.0-gpu.sif"
        base_tar="${BUNDLE}/image/deepvariant-1.10.0-gpu.docker-archive.tar"
        mkdir -p "${REPO}/.offline-build"
        def="${REPO}/.offline-build/sif-build-gpu.local.def"
        if [ -s "${base_sif}" ]; then
            boot="localimage"; from="${base_sif}"
        elif [ -s "${base_tar}" ]; then
            boot="docker-archive"; from="${base_tar}"
        else
            echo "ERROR: no GPU base image in the bundle (re-run" >&2
            echo "       scripts/fetch-offline-bundle.sh --gpu on the online host)." >&2
            exit 1
        fi
        sed -e "s|^Bootstrap: docker$|Bootstrap: ${boot}|" \
            -e "s|^From: google/deepvariant:1.10.0-gpu$|From: ${from}|" \
            "${REPO}/sif-build-gpu.def" > "${def}"
        grep -q "^From: ${from}$" "${def}" || {
            echo "ERROR: could not rewrite the GPU bootstrap in sif-build-gpu.def" >&2
            exit 1; }
        echo "    building ${GPU_SIF} from ${boot}:${from}"
        "${APPTAINER}" build "${INSTALL_DIR}/${GPU_SIF}" "${def}"
        installed_gpu="${INSTALL_DIR}/${GPU_SIF}"
    fi
fi

echo "==> [5/5] verification"
if [ "${WANT_VERIFY}" = 1 ]; then
    [ -n "${APPTAINER}" ] || { echo "ERROR: --verify needs apptainer/singularity" >&2; exit 1; }
    echo "    cwltool --validate (inside the image)"
    "${APPTAINER}" exec "${installed_cpu}" \
        cwltool --validate --no-container /opt/pangenome/Workflows/germline-pangenome-cpu.cwl
    out="${REPO}/tests/toy/demo_out/offline_check"
    rm -rf "${out}"; mkdir -p "${out}"
    echo "    toy demo -> ${out}"
    "${APPTAINER}" exec --bind "${REPO}:${REPO}" "${installed_cpu}" \
        env HOME=/tmp bash -c "cd '${REPO}' && cwltool --no-container --outdir '${out}' \
            Workflows/germline-pangenome-cpu.cwl tests/toy/jobs/toy_job.json"
    px="$(sed -n 's/.*"prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          "${REPO}/tests/toy/jobs/toy_job.json" | head -1)"
    missing=0
    for f in bam bam.bai markdup.metrics autosome.g.vcf.gz PAR.g.vcf.gz \
             chrX_female.g.vcf.gz chrX_male.g.vcf.gz chrY.g.vcf.gz; do
        if [ ! -s "${out}/${px}.${f}" ]; then echo "    MISSING: ${px}.${f}"; missing=1; fi
    done
    if [ "${missing}" = 1 ]; then
        echo "ERROR: the toy demo did not produce the expected outputs:" >&2
        ls -1 "${out}" | sed 's/^/      /' >&2
        exit 1
    fi
    echo "    toy demo OK (BAM + 5 gVCFs in ${out})"
    if [ "${WANT_GPU}" = 1 ] && [ -n "${installed_gpu}" ]; then
        "${APPTAINER}" exec "${installed_gpu}" \
            cwltool --validate --no-container /opt/pangenome/Workflows/germline-pangenome-gpu.cwl
        echo "    GPU workflow validated (a real GPU run needs 'apptainer exec --nv')"
    fi
else
    echo "    skipped (pass --verify to validate and run the toy demo)"
fi

cat <<DONE

Done.
  image      : ${installed_cpu}
  run        : apptainer exec ${installed_cpu} \\
                 /opt/pangenome/run-pangenome.sh --help
DONE
if [ -n "${installed_gpu}" ]; then
cat <<DONE
  GPU image  : ${installed_gpu}
  run (GPU)  : apptainer exec --nv ${installed_gpu} \\
                 /opt/pangenome/run-pangenome-gpu.sh ...
DONE
fi
cat <<DONE

Still to copy onto this host (NOT part of the bundle): the pangenome graph and
its giraffe indexes (.gbz/.dist/.min/.zipcodes/.ref_paths(/.snarls)) plus the
linear reference FASTA (+.fai/.dict).  See docs/OFFLINE.md.
DONE
