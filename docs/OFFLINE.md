# Running the pangenome workflow on an offline (air-gapped) host

The pipeline itself never needs the network: `cwltool --no-container` inside the
apptainer image runs `vg`, `samtools`, `bamsormadup` and DeepVariant from inside
that image. Only **getting the image and its build inputs** requires internet
access. The two scripts below split exactly along that line:

| Script | Where it runs | What it does |
| --- | --- | --- |
| `scripts/fetch-offline-bundle.sh` | **online** host | downloads/builds everything into one `offline-bundle/` directory (optionally a single `.tar`) |
| `scripts/setup-offline.sh` | **offline** host | verifies the bundle, installs (or builds) the apptainer image, smoke-tests it |

Everything else (`scripts/stage-sif-assets.sh`, the `.def` files) works unchanged;
`stage-sif-assets.sh` just learned to read its inputs from a bundle and to refuse
to touch the network when `PGGL_OFFLINE=1`.

## 1. On the online host

```bash
git clone <this repo> && cd pggl-workflow
./scripts/fetch-offline-bundle.sh --archive          # CPU image
./scripts/fetch-offline-bundle.sh --gpu --archive    # CPU + GPU images
```

This produces `offline-bundle/` and `pggl-offline-bundle-<date>.tar` (+ `.sha256`):

```
offline-bundle/
├── sif/          deepvariant-opencode-cpu-vg.sif      <- ready to run, ~6 GB
│                 deepvariant-opencode-gpu-vg.sif      (only with --gpu)
├── image/        base images (only with --with-base / --no-build)
├── sif-stage/    vg, node, cwltool wheels, bamsormadup + its libs
├── tool-images/  per-tool SIFs (only with --tool-images)
├── repo/         snapshot of this checkout (git archive HEAD)
├── SHA256SUMS, BUNDLE_INFO.txt, README-offline.md
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--gpu` | also fetch/build the GPU image (the GPU base is ~10 GB) |
| `--no-build` | ship only the build inputs; the offline host builds the image |
| `--with-base` | keep the base images in the bundle so the offline host can rebuild later |
| `--tool-images` | also fetch `quay.io/vgteam/vg`, `samtools`, ... as SIFs, for running the CWL with `cwltool --singularity` instead of the all-in-one image |
| `--archive` / `--split 20G` | pack (and split) the bundle for transfer |
| `--no-repo` | leave out the source snapshot |

Requirements on the online host: `apptainer`/`singularity` (preferred — it can
build the final images) **or** `docker` (then the images are exported as
docker-archive tarballs and the offline host converts them; that needs apptainer
there). `curl`, `python3 -m pip` and `dpkg-deb` are used for the non-image
assets; the cwltool wheels are downloaded for linux/cp310, so a macOS or ARM
host can stage them too.

## 2. Transfer

Copy `pggl-offline-bundle-<date>.tar` (or the whole `offline-bundle/` directory)
and the repo to the offline host. The `.tar` was split with `split -b` when
`--split` was used:

```bash
cat pggl-offline-bundle-20260920.tar.part-* > pggl-offline-bundle-20260920.tar
sha256sum -c pggl-offline-bundle-20260920.tar.sha256
```

## 3. On the offline host

```bash
tar xf pggl-offline-bundle-20260920.tar        # -> offline-bundle/
tar xzf offline-bundle/repo/pggl-workflow-*.tar.gz   # if the repo is not there yet
cd pggl-workflow
./scripts/setup-offline.sh --bundle ../offline-bundle --verify
```

`setup-offline.sh`

1. verifies `SHA256SUMS` (transfer damage is the most common failure),
2. copies `sif/*.sif` next to the checkout — or, when the bundle only carries
   the build inputs, runs `PGGL_OFFLINE=1 scripts/stage-sif-assets.sh` and
   `apptainer build` locally (for the GPU image it rewrites the `Bootstrap:
   docker` line of `sif-build-gpu.def` to the staged base image),
3. with `--verify`: runs `cwltool --validate` inside the image and the full toy
   demo (`tests/toy/jobs/toy_job.json`), checking that the BAM and the five
   gVCFs come out.

## 4. Reference data (not in the bundle)

The pangenome graph, its giraffe indexes and the linear reference are **not**
bundled (~54 GB for the T2T-CHM13 backbone). Copy these onto the offline host
separately:

```
graph.gbz  graph.dist  graph.min  graph.zipcodes  graph.ref_paths.txt
graph.snarls                      # only for call_sv=true
reference.fa  reference.fa.fai    # (+ .dict)
```

The index preparation itself is offline-capable, because `vg` lives in the
image:

```bash
apptainer exec deepvariant-opencode-cpu-vg.sif \
  /opt/pangenome/scripts/prepare_pangenome_indexes.sh graph.gbz mygraph CHM13v2 reference.fa
```

The interval BEDs ship with the repo (`interval_files/`, and inside the image at
`/opt/pangenome/interval_files/`).

## 5. Running

```bash
apptainer exec --bind /data:/data deepvariant-opencode-cpu-vg.sif \
  /opt/pangenome/run-pangenome.sh \
  --cram /data/sample.cram --ref /data/jasa.chm13.fa --ref_path_prefix 'CHM13v2#0#' \
  --gbz /data/JaSaPaGe.gbz --dist /data/jasa.dist --min /data/jasa.min \
  --zipcodes /data/jasa.zipcodes --ref_paths /data/jasa.ref_paths.txt \
  --autosome_interval /opt/pangenome/interval_files/chm13_t2t/autosome.bed \
  --PAR_interval      /opt/pangenome/interval_files/chm13_t2t/PAR.bed \
  --chrX_interval     /opt/pangenome/interval_files/chm13_t2t/chrX.bed \
  --chrY_interval     /opt/pangenome/interval_files/chm13_t2t/chrY.bed \
  --prefix SAMPLE --threads 64 --outdir out/
```

Add `--nv` and `run-pangenome-gpu.sh` for the GPU image. Bind-mount every host
directory the job touches (`--bind`), because apptainer only maps `$HOME`, the
working directory and `/tmp` by default.

Running the CWL directly (a checkout + `cwltool` outside the image) also works
offline as long as every tool is on `$PATH`; the CWL `DockerRequirement`s are
hints, so `--no-container` never pulls anything. If you would rather let cwltool
use per-tool containers, ship them with `--tool-images` and point cwltool at
them:

```bash
export CWL_SINGULARITY_CACHE=$PWD/tool-images
cwltool --singularity --parallel --outdir out/ Workflows/germline-pangenome-cpu.cwl job.json
```

cwltool looks for `<dockerPull with '/' replaced by '_'>.sif` in that directory,
which is exactly how the bundle names them — but it is the less-tested path; the
all-in-one image with `--no-container` is the supported one.

## Notes and gotchas

- **`docker/run-toy-demo.sh` is online-only.** It builds `docker/Dockerfile.toy`,
  which downloads vg/cwltool at build time. Use the apptainer image offline.
- **No `opencode` needed.** The GPU image used to require
  `image/opencode-linux-x64-baseline.tar.gz`, a file with no public URL. It is
  now optional: when `image/opencode/` is empty the GPU image is built without
  that (pipeline-irrelevant) developer tool.
- **`PGGL_OFFLINE=1`** makes `scripts/stage-sif-assets.sh` fail fast with an
  explanatory message instead of blocking on a download; `PGGL_SRC=<dir>` points
  it at an unpacked bundle (it also picks up `./offline-bundle` automatically).
- **Rebuilding offline** requires `--with-base` (or `--no-build`) at fetch time,
  otherwise the multi-GB base images are left out of the bundle.
- **Versions are pinned** in `scripts/stage-sif-assets.sh` (vg `v1.70.0`, node
  `v20.18.0`, cwltool, biobambam2). Change them there and re-run the fetch so
  the online and offline sides cannot drift apart.
