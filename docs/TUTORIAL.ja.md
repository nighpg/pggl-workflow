# チュートリアル: エアギャップ環境のセットアップから Slurm での実行まで

このチュートリアルでは、インターネットに接続できない（エアギャップ）Slurm クラスタで、
パンゲノム germline ワークフローを動かせるようにします。最後に、実データ
（1000 Genomes の CRAM）を JaSaPaGe グラフにマップし、GRCh38 座標の BAM・gVCF・SV VCF
を得るところまで進めます。

```
 オンライン側のホスト                      エアギャップ側の Slurm クラスタ
┌─────────────────────────┐   転送    ┌──────────────────────────────────────────┐
│ 1. リポジトリを用意      │ ───────▶ │ 4. バンドルを展開・検証 (setup-offline.sh) │
│ 2. バンドルを作る        │  tar     │ 5. 参照データを配置                         │
│    (fetch-offline-bundle)│  +sha256 │ 6. toy データで Slurm 動作確認              │
│ 3. 参照データを揃える    │          │ 7. 実データを投入 (submit-slurm.sh)         │
└─────────────────────────┘           └──────────────────────────────────────────┘
```

ワークフローそのものは実行時にネットワークを使いません。ネットワークが必要なのは、
apptainer イメージとその材料を集める手順 1〜3 だけです。

---

## 0. 前提

**オンライン側のホスト**

| 必要なもの | 用途 |
| --- | --- |
| apptainer（推奨 1.4 以降）または docker | イメージのビルド・取得 |
| `git`, `curl`, `python3 -m pip`, `dpkg-deb` | ビルド材料（vg, node, cwltool, biobambam2, kmc）の取得 |
| 空きディスク 約 15 GB（CPU イメージのみ）＋参照データ分 | バンドルと参照データ |

**エアギャップ側のクラスタ**

| 必要なもの | 用途 |
| --- | --- |
| apptainer（ログインノードと計算ノードの両方） | イメージの実行（と、必要ならビルド） |
| Slurm（`sbatch`, `squeue`, `sacct` が計算ノードからも使えること） | 段階 1 のジョブが段階 2・3 を自分で投入するため |
| `python3`（ログインノードと計算ノード） | ジョブファイルの分割（`scripts/slurm-jobs.py`） |
| 全ノードから見える共有ストレージ（Lustre など） | リポジトリ・入力・作業ディレクトリ |
| 計算ノードのローカルディスク 約 60 GB 以上（`/tmp`） | グラフとインデックスのローカルコピー |
| 計算ノード 1 台あたりメモリ 約 100 GB × 同時に走らせたいレーン数 | 1 レーン = giraffe 1 プロセス ≒ 80 GB |

**参照データ（バンドルには含まれません。別途転送します）**

| ファイル | サイズ（JaSaPaGe） | 備考 |
| --- | --- | --- |
| `JaSaPaGe.gbz` | 3.3 GB | グラフ |
| `jasapage.dist` / `jasapage.shortread.withzip.min` / `jasapage.shortread.zipcodes` | 7.6 / 37 / 2.5 GB | giraffe インデックス |
| `JaSaPaGe.snarls` | 177 MB | SV ジェノタイピング（`call_sv`）を使う場合 |
| 線形参照 FASTA（例: `GRCh38_full_analysis_set_plus_decoy_hla.fa`） | 3.1 GB | 入力 CRAM を作ったときの参照と同じもの |

> **インデックスはオンライン側（または計算資源のある環境）で作っておくのがおすすめです。**
> `vg autoindex` は JaSaPaGe で 32 コア・240 GB・数時間〜1 日かかります。

---

## 1. オンライン側: リポジトリを用意する

```bash
git clone <このリポジトリ> pggl-workflow
cd pggl-workflow
git status            # 何も表示されない（クリーン）ことを確認
```

**必ずコミット済みの状態にしてください。** バンドルに入るソースは `git archive HEAD`
で作られるので、コミットしていない変更はエアギャップ側に届きません。

apptainer をコマンド名 `apptainer` で呼べるようにしておきます。`singularity`
（SingularityCE）が先に見つかると、`/etc/subuid` の登録がないホストではビルドが
`could not use fakeroot: no valid mapping entry found` で失敗します。

```bash
# 例: apptainer が PATH にないサイト（NIG スパコンでの場所は docs/NIG.ja.md）
export PATH=/path/to/apptainer/bin:$PATH
apptainer --version
export APPTAINER_TMPDIR=/path/to/big/tmp      # 数 GB 以上の空きがある場所
export APPTAINER_CACHEDIR=/path/to/big/cache
```

## 2. オンライン側: バンドルを作る

```bash
./scripts/fetch-offline-bundle.sh --archive --with-base
```

- `--archive`: 転送用に 1 つの `.tar` にまとめます（`pggl-offline-bundle-<日付>.tar`
  と `.sha256` ができます）。
- `--with-base`: ベースイメージも入れておきます。エアギャップ側でイメージを作り直す
  （例: vg のバージョンを変える）可能性があるなら付けてください。
- GPU イメージも必要なら `--gpu` を足します（ベースだけで約 10 GB）。
- 大きすぎて一度に運べない場合は `--split 20G` で分割できます。

できあがるもの:

```
offline-bundle/
├── sif/          deepvariant-opencode-cpu-vg.sif     <- そのまま実行できるイメージ
├── image/        ベースイメージ（--with-base のとき）
├── sif-stage/    vg, node, cwltool wheel, bamsormadup, kmc（イメージの材料）
├── repo/         pggl-workflow-<rev>.tar.gz          <- コミット済みソース
└── SHA256SUMS, BUNDLE_INFO.txt, README-offline.md
```

`BUNDLE_INFO.txt` の `HEAD=` が、手順 1 で確認したコミットと一致することを確かめて
ください。

## 3. オンライン側: 参照データを揃える

グラフ・インデックス・参照 FASTA を 1 か所に集め、チェックサムを取ります。

```bash
mkdir -p refbundle/JaSaPaGe refbundle/GRCh38
cp JaSaPaGe.gbz JaSaPaGe.snarls jasapage.dist \
   jasapage.shortread.withzip.min jasapage.shortread.zipcodes  refbundle/JaSaPaGe/
cp GRCh38_full_analysis_set_plus_decoy_hla.fa                   refbundle/GRCh38/
( cd refbundle && find . -type f -print0 | xargs -0 sha256sum > SHA256SUMS )
```

`.fai`・`.dict`・`GRCh38.pansn.dict` は小さいので、エアギャップ側で作ります（手順 5）。
シンボリックリンクではなく実体をコピーしてください。

---

## 4. エアギャップ側: バンドルを展開・検証する

転送したファイルを共有ストレージ（全ノードから見える場所）に置きます。

```bash
cd /shared/…/work
# 分割した場合は先に結合: cat pggl-offline-bundle-*.tar.part-* > pggl-offline-bundle-<日付>.tar
sha256sum -c pggl-offline-bundle-<日付>.tar.sha256
tar xf pggl-offline-bundle-<日付>.tar                    # -> offline-bundle/
tar xzf offline-bundle/repo/pggl-workflow-*.tar.gz      # -> pggl-workflow/
cd pggl-workflow

export PATH=/path/to/apptainer/bin:$PATH          # 手順 1 と同じ理由
./scripts/setup-offline.sh --bundle ../offline-bundle --verify
```

`setup-offline.sh` は次を行います。

1. `SHA256SUMS` を検証します（転送中の破損がいちばん多い失敗です）。
2. `sif/deepvariant-opencode-cpu-vg.sif` をリポジトリ直下にコピーします。
   `scripts/submit-slurm.sh` は既定でここのイメージを使います。
3. `--verify` を付けると、イメージの中で `cwltool --validate` と toy デモを
   実行し、BAM と 5 つの gVCF ができることを確かめます。

最後に `toy demo OK (BAM + 5 gVCFs in ...)` と表示されれば成功です。

参照データもチェックサムを検証しておきます。

```bash
cd /shared/…/refbundle && sha256sum -c SHA256SUMS
```

## 5. エアギャップ側: 参照データを配置する

以下では、次のように置いたとして説明します。

```
/shared/…/ref/JaSaPaGe/   JaSaPaGe.gbz  JaSaPaGe.snarls  jasapage.dist
                          jasapage.shortread.withzip.min  jasapage.shortread.zipcodes
/shared/…/ref/GRCh38/     GRCh38_full_analysis_set_plus_decoy_hla.fa
```

`.fai`・`.dict` と、GRCh38 へ surject するための PanSN 名の辞書を作ります。
ツールはすべてイメージの中にあるので、`apptainer exec` で呼びます。

```bash
SIF=/shared/…/pggl-workflow/deepvariant-opencode-cpu-vg.sif
REF=/shared/…/ref/GRCh38/GRCh38_full_analysis_set_plus_decoy_hla.fa
X="apptainer exec --bind /shared $SIF"

$X samtools faidx $REF
$X samtools dict  $REF -o ${REF%.fa}.dict

# JaSaPaGe は GRCh38 を断片（chr1[585988] など）として持っているので、
# ref_paths にはパス名の一覧ではなく PanSN 名の辞書を渡す
awk 'BEGIN{OFS="\t"} $1 ~ /^chr([0-9]+|X|Y|M)$/ {print "@SQ","SN:GRCh38#0#"$1,"LN:"$2}' $REF.fai \
  | cat <(printf '@HD\tVN:1.6\tSO:unsorted\n') - > /shared/…/ref/JaSaPaGe/GRCh38.pansn.dict
grep -c '^@SQ' /shared/…/ref/JaSaPaGe/GRCh38.pansn.dict      # 25
```

**すべてのパスを計算ノードからも見える名前で書いてください。** ログインノードにしか
ないマウントはジョブの中から見えません。
計算ノードからの見え方は次で確かめられます。

```bash
srun -p <partition> -c 1 --mem=1G ls -l /shared/…/ref/JaSaPaGe/ /shared/…/ref/GRCh38/
```

---

## 6. toy データで Slurm の動作を確認する

本番の前に、10 分ほどで終わる toy データで Slurm の 3 段階の連携を確かめます
（実測: prepare 12 秒、レーン各 7 秒、call 約 7 分半）。

```bash
cd /shared/…/pggl-workflow
scripts/submit-slurm.sh \
  --job tests/toy/jobs/toy_cram_job.json \
  --workdir /shared/…/runs/toy-slurm \
  --partition <partition> \
  --prepare-sbatch "--cpus-per-task=2 --mem=8G" \
  --lane-threads 4 --lane-mem-per-chunk 8 \
  --call-sbatch "--cpus-per-task=8 --mem=32G"
```

- 段階 1（prepare）が投入され、終わると自分で段階 2（レーンごとのジョブ配列）と
  段階 3（call）を投入します。
- toy の CRAM には read group が 2 つあるので、レーンタスクは 2 つになります。

確認:

```bash
W=/shared/…/runs/toy-slurm
cat $W/jobs.tsv                                   # prepare / lane / call のジョブ ID
sacct -j $(cut -f2 $W/jobs.tsv | paste -sd,) -X -o JobID%16,State,Elapsed,NodeList
ls $W/out/                                        # 13 ファイル
```

3 つとも `COMPLETED` になり、`out/` に BAM・markdup metrics・5 つの gVCF
（+ インデックス）が揃えば成功です。

---

## 7. 実データを投入する

### 7.1 job ファイルを書く

サンプル側の項目だけのテンプレートが `examples/jobs/` にあります。

| テンプレート | 入力 |
| --- | --- |
| `sample.cram.json` | CRAM（read group ごとにレーンに分けます） |
| `sample.fastq.json` | レーンごとの FASTQ の組と `@RG` 文字列 |

コピーしてリードのパスと `prefix` を書き換え、`scripts/apply-graph.py` でグラフの入力を
加えます（下の「グラフを選ぶ」）。区間 BED は `interval_files/...` と書いてあり、
`apply-graph.py` がリポジトリの中の絶対パスに直すので、コピーはどこに置いてもかまいません。
テンプレートは `apply-graph.py` を通してから使います（cwltool に直接は渡せません）。

グラフの入力も含めて全部を手で書く場合の例として、1000 Genomes の CRAM を JaSaPaGe にマップし GRCh38 に surject、
グラフ SV もジェノタイプする設定です（`/shared/…/runs/NA18945/job.json`）。

```json
{
  "cram":      {"class": "File", "path": "/shared/…/data/NA18945.cram"},
  "ref":       {"class": "File", "path": "/shared/…/ref/GRCh38/GRCh38_full_analysis_set_plus_decoy_hla.fa"},

  "gbz":       {"class": "File", "path": "/shared/…/ref/JaSaPaGe/JaSaPaGe.gbz"},
  "dist":      {"class": "File", "path": "/shared/…/ref/JaSaPaGe/jasapage.dist"},
  "min":       {"class": "File", "path": "/shared/…/ref/JaSaPaGe/jasapage.shortread.withzip.min"},
  "zipcodes":  {"class": "File", "path": "/shared/…/ref/JaSaPaGe/jasapage.shortread.zipcodes"},
  "ref_paths": {"class": "File", "path": "/shared/…/ref/JaSaPaGe/GRCh38.pansn.dict"},
  "ref_path_prefix": "GRCh38#0#",

  "autosome_interval": {"class": "File", "path": "/shared/…/pggl-workflow/interval_files/autosome.bed"},
  "PAR_interval":      {"class": "File", "path": "/shared/…/pggl-workflow/interval_files/PAR.bed"},
  "chrX_interval":     {"class": "File", "path": "/shared/…/pggl-workflow/interval_files/chrX.bed"},
  "chrY_interval":     {"class": "File", "path": "/shared/…/pggl-workflow/interval_files/chrY.bed"},
  "autosome_chunks_count": 8,

  "prefix": "NA18945",
  "threads": 128,

  "call_sv": true,
  "snarls": {"class": "File", "path": "/shared/…/ref/JaSaPaGe/JaSaPaGe.snarls"}
}
```

要点:

- `ref` は **CRAM を作ったときの参照と同じ配列** でなければデコードできません。
  CRAM ヘッダの `@SQ` の `M5:` と、手順 5 で作った `.dict` の `M5:` を比べると確実です。
- `ref` の `.fai` と `.dict`（拡張子 `.fa` を `.dict` に置き換えた名前）は、
  本体の隣に置いてあれば自動で使われます。job ファイルには書きません。
- `threads` は段階 3（DeepVariant）のスレッド数です。レーン段階は既定で 32 スレッド
  に置き換えられます（7.3 参照）。
- `autosome_chunks_count` を指定すると autosome の DeepVariant が並列化され、
  段階 3 が短くなります（0 または省略で 1 ジョブ）。
- FASTQ を入力にする場合は `cram` の代わりに `fq1` / `fq2` / `rg` を
  同じ順番・同じ個数で並べます（README の *Writing a job file* を参照）。

T2T-CHM13 座標で出したい場合は、`ref_paths` を CHM13 のパス一覧、`ref_path_prefix`
を `CHM13v2#0#`、interval BED を `interval_files/chm13_t2t/`、`ref` をグラフから
取り出した CHM13 の FASTA にします（README の *Preparing a graph*）。

### グラフを選ぶ

グラフごとの入力（giraffe のインデックス、snarls、参照 FASTA とパス、personalized graph
用の clip グラフと `.hapl`、SV の除外 BED）は `examples/graphs/<名前>.json` にまとめてあり、
`scripts/apply-graph.py` で job ファイルに書き込めます。グラフの切り替えは、使うファイルを
変えるだけです。プリセットのパスは、グラフのリリースを置いた場所（データルート）からの
相対パスで、`--data-root` か環境変数 `PGGL_DATA` で指定します。

```bash
export PGGL_DATA=/shared/…/graphs      # JaSaPaGe_GRCh38/ と combined_GRCh38/ を置いた場所
scripts/apply-graph.py germline examples/graphs/JaSaPaGe_GRCh38.json sample.json job.json
# combined（738 ハプロタイプ）は personalized graph で使う（全体グラフへのマップは 10 倍以上遅い）
scripts/apply-graph.py haplotype-sample examples/graphs/combined.json sample.json hs.json --threads 128
scripts/apply-graph.py personalized examples/graphs/combined.json sample.json graph/NA18945.personalized job.json
```

除外 BED（GIAB の反復配列とホモポリマー）は初回に `scripts/fetch-giab-repeat-bed.sh` で
`interval_files/` に取得します。`sv_exclude_bed` を指定すると、`.nonrep.vcf.gz`
（反復配列の外の単純な DEL/INS、QUAL 30 以上）が追加で出力されます。HG002 では
この範囲で Precision 0.975〜0.986、Recall 0.895〜0.906 でしたが、範囲に入る SV は全体の
約 16% です。

### 7.2 投入せずに確認する（dry run）

```bash
cd /shared/…/pggl-workflow
scripts/submit-slurm.sh --job /shared/…/runs/NA18945/job.json \
  --workdir /shared/…/runs/NA18945/check --partition <partition> --dry-run
cat /shared/…/runs/NA18945/check/env.sh | grep -E 'SBATCH|LANE_SET'
rm -rf /shared/…/runs/NA18945/check
```

job ファイルのパスの誤りや必須項目の抜けは、ここで分かります。

### 7.3 投入する

```bash
scripts/submit-slurm.sh \
  --job /shared/…/runs/NA18945/job.json \
  --workdir /shared/…/runs/NA18945/run1 \
  --partition <partition>
```

既定のリソース:

| 段階 | 内容 | 既定の確保 |
| --- | --- | --- |
| 1. prepare | CRAM をデコードし、`@RG` ごとの FASTQ に分ける | `--cpus-per-task=32 --mem=64G` |
| 2. lane（配列） | 1 レーン = giraffe 32 スレッド × 1 プロセス | `--cpus-per-task=32 --mem=100G` |
| 3. call | 重複マーク、DeepVariant × 5、SV | `--exclusive --mem=0 --cpus-per-task=<threads>` |

レーンを 32 スレッドの小さなタスクにしているのは、giraffe が 32 スレッド程度までしか
効率よく速くならず、インデックスの読み込み（約 85 秒）はスレッド数に関係なく
かかるためです。1 台に複数レーンを詰めた方が、1 レーンでノードを占有するより
ノードあたり約 2.5 倍速くなりました。

調整用のオプション:

| オプション | 用途 |
| --- | --- |
| `--lane-threads N` / `--lane-mem-per-chunk G` | レーンタスクのスレッド数・メモリ |
| `--max-lanes N` | 同時に走るレーン数の上限（共有ストレージの負荷を抑える） |
| `--lane-whole-node` | 1 レーンでノードを占有する（job の `threads` / `align_chunks` を使う） |
| `--call-sbatch "..."` | 段階 3 の sbatch オプション（`--mem` も必ず付ける） |
| `--local-index DIR` | インデックスのローカルコピー先（既定 `/tmp`） |
| `--variant gpu` | GPU 版（`--call-sbatch` に `--gres=gpu:N` などを足す） |
| `--variant parabricks` | NVIDIA Parabricks の DeepVariant（`--sif parabricks-vg.sif`、`--call-sbatch` に `--gres=gpu:N`、job に `"num_gpus": N`）。7.6 を参照 |
| `--no-call-parallel` | 段階 3 の cwltool を `--parallel` なしで動かす（既定は並列。常染色体のチャンクと PAR・chrX・chrY の呼び出しが、`coresMin` に合わせてノードを分け合う） |
| `--from call` | 段階 3 だけを投入し直す（前の実行のレーンの結果を再利用する） |

> **sbatch オプションを自分で書くときは、必ず `--mem` を付けてください。**
> パーティションの既定が「CPU あたり 8 GB」のような場合、`--exclusive` と 128 CPU で
> 1 TB を要求したことになり、どのノードにも入らず `PENDING (Resources)` のまま
> 動きません。

段階 3 だけが失敗したとき（共有ストレージの一時的なエラーなど）や、呼び出しの設定を
変えて呼び直したいときは、同じ `--job` と `--workdir` に `--from call` を付けて投入し直します。
すべてのレーンの `lanes/*/out.json` がそろっている必要があります。前の `out/` と段階 3 の
一時ディレクトリは消され、新しいジョブ ID が `jobs.tsv` に追記されます。

```bash
scripts/submit-slurm.sh --job job.json --workdir /shared/…/runs/NA18945/run1 \
  --partition <partition> --from call
```

### 7.4 進捗を見る

```bash
W=/shared/…/runs/NA18945/run1
sacct -j $(cut -f2 $W/jobs.tsv | paste -sd,) -X -o JobID%16,State,Elapsed,NodeList
grep -h ' done$' $W/logs/lane-*.out | wc -l          # 終わったレーン数
grep -ao '\[step [a-zA-Z_]*\] completed [a-z]*' $W/logs/call.*.err   # 段階 3 のステップ
```

ノードの様子を見るには、実行中のジョブに入ります。

```bash
srun --jobid=<ジョブID（配列なら JobIDRaw）> --overlap -n1 top -bn1 | head -15
```

マッピング中は user CPU が 90% 以上になっていれば正常です。**system CPU が大半を
占めて user がほとんど 0% の場合は、インデックスを共有ストレージから直接読んでいます**
（8. トラブルシューティング参照）。

### 7.5 出力

`$W/out/` に、単一ノードで `cwltool --outdir` した場合と同じファイルができます。

```
NA18945.bam (+.bai)                     重複マーク済み BAM（GRCh38 座標）
NA18945.markdup.metrics
NA18945.{autosome,PAR,chrX_female,chrX_male,chrY}.g.vcf.gz (+.tbi)
NA18945.sv.vcf.gz, .sv.chrX_female/.sv.chrX_male/.sv.chrY.vcf.gz (+.tbi)   call_sv=true のとき
NA18945.sv*.nonrep.vcf.gz (+.tbi)       sv_exclude_bed を渡したとき（反復配列の外の単純な DEL/INS）
```

作業ディレクトリには中間ファイル（`prepare-out/` の FASTQ、`lanes/*/out/` のレーン
BAM・GAM）が残ります。結果を確認したら削除してかまいません。

### 7.6 Parabricks（GPU）で呼び出す

GPU ノードがあれば、段階 3 の DeepVariant を NVIDIA Parabricks の `pbrun deepvariant`
に替えられます。GPU を使うのは段階 3 だけで、マッピング・重複マーク・SV は CPU の
ままです。pangenome-aware DeepVariant には Parabricks 版がありません。

**イメージを用意する（オンライン側）。** Parabricks のイメージは nvcr.io から取るので、
オフラインのバンドル（手順 2）には入りません。オンライン側で作り、1 ファイルを
転送します。CPU のイメージ（`deepvariant-opencode-cpu-vg.sif`）から samtools と
bcftools を取り込むので、先に CPU のイメージをリポジトリ直下に置いておきます。

```bash
cd pggl-workflow
./scripts/stage-sif-assets.sh
apptainer build --fakeroot --ignore-fakeroot-command parabricks-vg.sif sif-build-parabricks.def
# parabricks-vg.sif（約 3.3 GB）をエアギャップ側の共有ストレージへ転送する
sha256sum parabricks-vg.sif > parabricks-vg.sif.sha256
```

ビルドの最後に、イメージの中で CWL の検証（`%test`）が走ります。

**GPU ノードを確かめる（エアギャップ側）。** Parabricks 4.8 は CUDA 12 に対応した
ドライバが要ります。

```bash
srun -p <GPUパーティション> --gres=gpu:1 -c 1 --mem=4G \
  apptainer exec --nv /shared/…/parabricks-vg.sif nvidia-smi
```

**toy で動作を確かめる。** 手順 6 と同じ toy データで、段階 3 だけ GPU で動かします。

```bash
cd /shared/…/pggl-workflow
scripts/submit-slurm.sh \
  --job tests/toy/jobs/toy_cram_job.json \
  --workdir /shared/…/runs/toy-parabricks \
  --partition <CPUパーティション> \
  --variant parabricks --sif /shared/…/parabricks-vg.sif \
  --prepare-sbatch "--cpus-per-task=2 --mem=8G" \
  --lane-threads 4 --lane-mem-per-chunk 8 \
  --markdup-sbatch "--cpus-per-task=8 --mem=16G" --sv-sbatch "--cpus-per-task=8 --mem=16G" \
  --call-sbatch "-p <GPUパーティション> --cpus-per-task=8 --mem=32G --gres=gpu:1"
```

成功の基準は、prepare・lane・markdup・sv・call の 5 つが `COMPLETED` になり、`out/` に
13 ファイルがそろうことです。

`--variant parabricks` では段階 3 が 3 つのジョブに分かれ、GPU ノードを使うのは
DeepVariant の間だけです。DeepVariant は BAM ができた時点で始まり、SV を待ちません。

| ジョブ | 中身 | 場所 | 開始 |
| --- | --- | --- | --- |
| markdup | 重複マーク | `--partition`（CPU）、`--markdup-sbatch` | レーンの後 |
| sv | vg pack → vg call → `.nonrep` | `--partition`（CPU）、`--sv-sbatch` | レーンの後（markdup と並行） |
| call | DeepVariant × 5（markdup の BAM を読む） | `--call-sbatch` に GPU のパーティションと `--gres` | markdup の後 |

call だけが失敗したときは、`--from dv` で GPU のジョブだけを投入し直せます
（markdup の BAM と sv の結果はそのまま使います）。

**実データで投入する。** job ファイルに `"num_gpus": <N>` を加え、次のように投入します。

```bash
scripts/submit-slurm.sh \
  --job /shared/…/runs/NA18945/job.json \
  --workdir /shared/…/runs/NA18945/run-pb \
  --partition <CPUパーティション> \
  --variant parabricks --sif /shared/…/parabricks-vg.sif \
  --call-sbatch "-p <GPUパーティション> --exclusive --mem=0 --gres=gpu:<N>"
```

prepare・レーン・markdup・sv は `--partition` の CPU ノードで、call だけが GPU ノードで動きます。

**CPU 版と比べる。** Parabricks は DeepVariant を再実装したもので、結果はほぼ同じですが
ビット単位では一致しません。本番を切り替える前に、ベンチマーク試料（HG002 など）で
CPU 版と比べてください。マッピングをやり直す必要はなく、CPU 版の作業ディレクトリの
レーンの結果を `--from call` で再利用できます。`--from call` は前の `out/` を消すので、
先に退避します。

```bash
W=/shared/…/runs/HG002/run1                      # CPU 版で実行済み
mv $W/out $W/out-cpu
scripts/submit-slurm.sh --job job.json --workdir $W --partition <CPUパーティション> \
  --from call --variant parabricks --sif /shared/…/parabricks-vg.sif \
  --call-sbatch "-p <GPUパーティション> --exclusive --mem=0 --gres=gpu:<N>"
```

> Parabricks の経路は、CWL の検証と仮の `pbrun` を使った toy の実行までは確かめて
> いますが、実際の GPU ではまだ動かしていません。

### 7.7 BWA の CRAM を personalized グラフで解析する（1 コマンド）

BWA-MEM などで解析済みの CRAM を、その試料用の personalized グラフに再マッピングする
までを、`scripts/run-cram-personalized.sh` が 3 つの Slurm ジョブにまとめて投入します
（投入したらすぐ戻ります）。

1. **prepare**: CRAM を read group ごとの FASTQ に戻す。CRAM を作ったときの参照
   （`--cram-ref`）で戻すので、グラフの参照と違う FASTA で作った CRAM でもかまいません
2. **sample**: その FASTQ から personalized グラフとインデックスを作る（KMC と `vg haplotypes`）
3. **submit**: 同じ FASTQ と personalized グラフで `scripts/submit-slurm.sh` を投入する
   （レーンのマッピング、呼び出し、グラフ SV）

CRAM を戻すのは 1 回だけで、ネットワークは使いません。

```bash
cd /shared/…/pggl-workflow
scripts/run-cram-personalized.sh \
  --cram /shared/…/data/SAMPLE.cram \
  --cram-ref /shared/…/ref/GRCh38/Homo_sapiens_assembly38.fasta \
  --prefix SAMPLE --workdir /shared/…/runs/SAMPLE \
  --data-root /shared/…/graphs --partition <CPUパーティション> \
  --variant parabricks --gpu-partition <GPUパーティション> --gpus 2
```

- `--cram-ref` には `.fai` と `.dict` が要ります（手順 5 と同じ方法で作れます）。
- `--variant cpu` にすると、呼び出しも CPU の DeepVariant で行います。
- グラフは既定で `examples/graphs/combined.json` です。`--preset` で変えられます。
- 繰り返し配列の BED（`interval_files/GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz`）
  を持ち込んでおいてください。プリセットがこれを `sv_exclude_bed` に使います。
- 途中で止まったときは、`--from sample`（サンプリングから）か `--from submit`（本解析の
  投入から）で、作業ディレクトリに残った結果を使ってやり直せます。
- `--dry-run` をつけると、投入せずにジョブとスクリプトだけを書き出します。

実測（HG002 の chr20 だけの CRAM、35x、combined グラフ、`--variant cpu`、128 コアのノード）:
prepare 45 秒、sample 1 時間 18 分（personalized グラフのインデックス作成がほとんど）、
レーン 6 分半、call 32 分。sample はゲノム全体のグラフを索引するので、全ゲノムの試料でも
同じくらいかかり、メモリは 300 GB 程度使います。

ジョブの ID は `<workdir>/jobs.tsv` に、マッピングと呼び出しのジョブは
`<workdir>/run/jobs.tsv` に書かれ、結果は `<workdir>/run/out/` にできます。

### 所要時間の目安（実測）

NA18945 の 10% サブサンプル（約 7,800 万リード、12 read group）、128 コア・503 GB の
ノード、JaSaPaGe → GRCh38、SV あり:

| 段階 | 所要時間 |
| --- | --- |
| 1. prepare（CRAM → 12 レーン） | 約 4 分 |
| 2. lane（12 レーンを 5 ノードで同時に） | 約 10 分（インデックスのコピー込み） |
| 3. call（autosome を分割しない場合） | 約 3 時間 |

30x の全データではレーン段階・段階 3 ともに概ね 10 倍になります。

---

## 8. トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| ビルドで `could not use fakeroot: no valid mapping entry found` | SingularityCE が使われている | apptainer を PATH の先頭に置く（手順 1） |
| ビルドの `%post` で `GLIBC_2.38 not found` | apptainer の fakeroot コマンドがベースイメージと合わない | スクリプトが自動で `--ignore-fakeroot-command` を付けます。手動なら同じオプションを付ける |
| ジョブが `PENDING (Resources)` のまま | `--exclusive` と CPU あたりの既定メモリの組み合わせで、要求メモリがノードを超えている | sbatch オプションに `--mem` を明示する |
| レーンが極端に遅い。`top` で system CPU が大半、giraffe が `ldlm_completion_ast` で待っている | インデックスを Lustre から直接メモリマップしている（複数ノードで同じファイルを使うと、ロック待ちで止まる） | `--local-index` を無効にしていないか確認。単一ノードで cwltool を直接動かす場合も、`scripts/slurm-jobs.py stage-local` でローカルにコピーしてから実行する |
| レーンタスクの開始直後が長い | インデックスのローカルコピー（52 GB）中。複数ノードで同時にコピーすると帯域を分け合う | 正常。1 ノード単独なら約 45 秒〜数分、同時 5 ノードで約 7 分だった |
| `No such file or directory`（パスは正しいはず） | ジョブ内（計算ノード・コンテナ内）からそのパスが見えない | 計算ノードから見えるパスで書く。`srun ... ls` で確認。追加のマウントは `--bind` |
| 段階 3 が `CANCELLED` | レーンタスクが 1 つ失敗した（`--kill-on-invalid-dep`） | `logs/lane-N.*.err` を見て原因を直し、新しい `--workdir` で投入し直す |
| `vg` が SIGSEGV で落ちる | FASTQ に品質値の長さが配列長と違うリードがある | `tools/filter_fastq.py` で取り除いてから入力する |
| 作った CRAM が異常に大きい | ホストの samtools 1.19.2（Ubuntu ビルド）がタグを無圧縮で書く | イメージ内の samtools で書く（`apptainer exec $SIF samtools ...`） |

---

## 9. 付録: 単一ノードで実行する場合

Slurm を使わず、1 台で全段階を実行することもできます（結果は同じ job ファイルで同じになります）。

```bash
LD=/tmp/pggl-index.$$
trap 'rm -rf "$LD"' EXIT
python3 scripts/slurm-jobs.py stage-local job.json "$LD" job.local.json gbz dist min zipcodes
apptainer exec --bind /shared --bind /tmp deepvariant-opencode-cpu-vg.sif \
  cwltool --no-container --outdir out/ --tmpdir-prefix $PWD/tmp/ --tmp-outdir-prefix $PWD/tmp-out/ \
  Workflows/germline-pangenome-cpu.cwl job.local.json
```

レーンは 1 つずつ順に処理されます（cwltool の `--parallel` は、レーン数が多いと
ステージングの競合で失敗することがあるため使いません）。

関連ドキュメント:

- `README.md` — 入力・出力の一覧、設計、各機能の詳細
- `docs/OFFLINE.md` — オフラインバンドルのオプションの詳細
