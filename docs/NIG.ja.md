# 遺伝研スパコンでの実行メモ

遺伝研（NIG）スパコンと、そこから共有ストレージだけが見えるオフラインの GPU
クラスタで、このワークフローを動かすための施設固有の情報です。一般的な手順は
README と `docs/TUTORIAL.ja.md`、`docs/OFFLINE.md` にあります。

## 環境

| 項目 | 内容 |
| --- | --- |
| apptainer | `/opt/pkg/apptainer/1.4.5/bin/apptainer`（`PATH` になくても `scripts/submit-slurm.sh` が見つけます） |
| 共有データ | `/usr/local/shared_data`。オンライン側では `/lustre9/open/shared_data` としても見えますが、オフラインの GPU クラスタには `/usr/local/shared_data` しかないので、パスはこの形で書きます |
| パーティション | オンライン側の計算ノードは `test`（`/tmp` はノードあたり約 643 GB） |

`/usr/local/shared_data` は計算ノードからも見えます（2026-10-28 に a038、at155、at163 で確認）。
`submit-slurm.sh` はこの下の入力に対して `/usr/local/shared_data` をコンテナに bind します。

## 共有データの配置

```
/usr/local/shared_data/visc/data/          <- データルート（PGGL_DATA）
├── JaSaPaGe_GRCh38/release/               グラフ、giraffe インデックス、clip グラフと .hapl、参照 FASTA
├── combined_GRCh38/release/               738 ハプロタイプの combined グラフ（同じ構成）
└── pggl-workflow/
    ├── repo/pggl-workflow/                このリポジトリの clone（ここから実行）
    ├── sif/                               deepvariant-opencode-cpu-vg.sif
    │                                      deepvariant-pangenome-aware-cpu-vg.sif
    │                                      parabricks-vg.sif
    ├── interval_files/                    GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz
    └── SHA256SUMS
```

`visc/data` に書き込めるのは管理用のアカウントだけです。clone の更新（`git pull`）も、
そのアカウントで行います（所有者が違うと git が止めます）。

プリセットは繰り返し配列の BED を clone の `interval_files/` で探すので、clone を
作り直したときは一度だけコピーします。

```bash
R=/usr/local/shared_data/visc/data/pggl-workflow
cp $R/interval_files/GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz $R/repo/pggl-workflow/interval_files/
```

## 実行

オンライン側でもオフラインの GPU クラスタでも同じ手順です。作業ディレクトリは、
そのクラスタから書き込める場所にします。

```bash
R=/usr/local/shared_data/visc/data/pggl-workflow
export PGGL_DATA=/usr/local/shared_data/visc/data
cd $R/repo/pggl-workflow
W=/path/to/work                                  # 自分の作業ディレクトリ（clone の中には書けません）
cp examples/jobs/sample.cram.json $W/sample.json # または sample.fastq.json。リードのパスと prefix を書き換える

# JaSaPaGe、全体グラフ
scripts/apply-graph.py germline examples/graphs/JaSaPaGe_GRCh38.json $W/sample.json $W/job.json
scripts/submit-slurm.sh --job $W/job.json --workdir $W/run \
    --sif $R/sif/deepvariant-opencode-cpu-vg.sif --partition <partition>

# Parabricks（GPU）で呼び出す場合は、上に次を加え、$W/job.json に "num_gpus": <N> を書く
#   --variant parabricks --sif $R/sif/parabricks-vg.sif \
#   --call-sbatch "-p <GPUパーティション> --exclusive --mem=0 --cpus-per-task=<threads> --gres=gpu:<N>"
# --partition は CPU のまま。重複マーク（markdup）と SV（sv）は CPU ノードで並行して動き、
# GPU ノードを使うのは DeepVariant の call ジョブだけです（失敗したら --from dv）。

# combined グラフ: personalized グラフを作ってから使う
scripts/apply-graph.py haplotype-sample examples/graphs/combined.json $W/sample.json $W/hs.json --threads 128
#   $W/hs.json で Workflows/haplotype-sample.cwl を CPU の SIF の中で実行
#   （コマンドは README の *Haplotype sampling*）
scripts/apply-graph.py personalized examples/graphs/combined.json $W/sample.json <出力 prefix> $W/job.json
```

BWA などで解析済みの CRAM から personalized グラフで解析するまでは、
`scripts/run-cram-personalized.sh` 1 つで投入できます（TUTORIAL の 7.7）。

```bash
scripts/run-cram-personalized.sh --cram /path/to/SAMPLE.cram --cram-ref /path/to/CRAMの参照.fa \
  --prefix SAMPLE --workdir $W/SAMPLE --data-root $PGGL_DATA --partition <partition> \
  --sif $R/sif/deepvariant-opencode-cpu-vg.sif \
  --variant parabricks --call-sif $R/sif/parabricks-vg.sif --gpu-partition <GPUパーティション> --gpus 2
```

`--dry-run` をつけると、ジョブを投入せずに `<workdir>/env.sh` と各段階のスクリプトを
書き出します。`env.sh` の `--bind` に `/usr/local/shared_data` が入っていれば、
パスと bind は問題ありません。

## オフラインの GPU クラスタ

- GPU ノードのドライバが Parabricks 4.8（CUDA 12）に対応しているかを、一度
  `nvidia-smi` で確かめてください。
- 本番を `--variant parabricks` に切り替える前に、HG002 などのベンチマーク試料を
  CPU の DeepVariant と両方で動かし、結果を比べてください。
- SIF を差し替えるときは、`SHA256SUMS` の行も一緒に更新します。
