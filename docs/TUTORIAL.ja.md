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
# 例: NIG スパコン
export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH
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
cd /lustre/…/work
# 分割した場合は先に結合: cat pggl-offline-bundle-*.tar.part-* > pggl-offline-bundle-<日付>.tar
sha256sum -c pggl-offline-bundle-<日付>.tar.sha256
tar xf pggl-offline-bundle-<日付>.tar                    # -> offline-bundle/
tar xzf offline-bundle/repo/pggl-workflow-*.tar.gz      # -> pggl-workflow/
cd pggl-workflow

export PATH=/opt/pkg/apptainer/1.4.5/bin:$PATH          # 手順 1 と同じ理由
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
cd /lustre/…/refbundle && sha256sum -c SHA256SUMS
```

## 5. エアギャップ側: 参照データを配置する

以下では、次のように置いたとして説明します。

```
/lustre/…/ref/JaSaPaGe/   JaSaPaGe.gbz  JaSaPaGe.snarls  jasapage.dist
                          jasapage.shortread.withzip.min  jasapage.shortread.zipcodes
/lustre/…/ref/GRCh38/     GRCh38_full_analysis_set_plus_decoy_hla.fa
```

`.fai`・`.dict` と、GRCh38 へ surject するための PanSN 名の辞書を作ります。
ツールはすべてイメージの中にあるので、`apptainer exec` で呼びます。

```bash
SIF=/lustre/…/pggl-workflow/deepvariant-opencode-cpu-vg.sif
REF=/lustre/…/ref/GRCh38/GRCh38_full_analysis_set_plus_decoy_hla.fa
X="apptainer exec --bind /lustre $SIF"

$X samtools faidx $REF
$X samtools dict  $REF -o ${REF%.fa}.dict

# JaSaPaGe は GRCh38 を断片（chr1[585988] など）として持っているので、
# ref_paths にはパス名の一覧ではなく PanSN 名の辞書を渡す
awk 'BEGIN{OFS="\t"} $1 ~ /^chr([0-9]+|X|Y|M)$/ {print "@SQ","SN:GRCh38#0#"$1,"LN:"$2}' $REF.fai \
  | cat <(printf '@HD\tVN:1.6\tSO:unsorted\n') - > /lustre/…/ref/JaSaPaGe/GRCh38.pansn.dict
grep -c '^@SQ' /lustre/…/ref/JaSaPaGe/GRCh38.pansn.dict      # 25
```

**すべてのパスを計算ノードからも見える名前で書いてください。** ログインノードにしか
ないマウント（NIG の `/usr/local/shared_data` など）はジョブの中から見えません。
計算ノードからの見え方は次で確かめられます。

```bash
srun -p <partition> -c 1 --mem=1G ls -l /lustre/…/ref/JaSaPaGe/ /lustre/…/ref/GRCh38/
```

---

## 6. toy データで Slurm の動作を確認する

本番の前に、数分で終わる toy データで Slurm の 3 段階の連携を確かめます。

```bash
cd /lustre/…/pggl-workflow
scripts/submit-slurm.sh \
  --job tests/toy/jobs/toy_cram_job.json \
  --workdir /lustre/…/runs/toy-slurm \
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
W=/lustre/…/runs/toy-slurm
cat $W/jobs.tsv                                   # prepare / lane / call のジョブ ID
sacct -j $(cut -f2 $W/jobs.tsv | paste -sd,) -X -o JobID%16,State,Elapsed,NodeList
ls $W/out/                                        # 13 ファイル
```

3 つとも `COMPLETED` になり、`out/` に BAM・markdup metrics・5 つの gVCF
（+ インデックス）が揃えば成功です。

---

## 7. 実データを投入する

### 7.1 job ファイルを書く

例として、1000 Genomes の CRAM を JaSaPaGe にマップし GRCh38 に surject、
グラフ SV もジェノタイプする設定です（`/lustre/…/runs/NA18945/job.json`）。

```json
{
  "cram":      {"class": "File", "path": "/lustre/…/data/NA18945.cram"},
  "ref":       {"class": "File", "path": "/lustre/…/ref/GRCh38/GRCh38_full_analysis_set_plus_decoy_hla.fa"},

  "gbz":       {"class": "File", "path": "/lustre/…/ref/JaSaPaGe/JaSaPaGe.gbz"},
  "dist":      {"class": "File", "path": "/lustre/…/ref/JaSaPaGe/jasapage.dist"},
  "min":       {"class": "File", "path": "/lustre/…/ref/JaSaPaGe/jasapage.shortread.withzip.min"},
  "zipcodes":  {"class": "File", "path": "/lustre/…/ref/JaSaPaGe/jasapage.shortread.zipcodes"},
  "ref_paths": {"class": "File", "path": "/lustre/…/ref/JaSaPaGe/GRCh38.pansn.dict"},
  "ref_path_prefix": "GRCh38#0#",

  "autosome_interval": {"class": "File", "path": "/lustre/…/pggl-workflow/interval_files/autosome.bed"},
  "PAR_interval":      {"class": "File", "path": "/lustre/…/pggl-workflow/interval_files/PAR.bed"},
  "chrX_interval":     {"class": "File", "path": "/lustre/…/pggl-workflow/interval_files/chrX.bed"},
  "chrY_interval":     {"class": "File", "path": "/lustre/…/pggl-workflow/interval_files/chrY.bed"},
  "autosome_chunks_count": 8,

  "prefix": "NA18945",
  "threads": 128,

  "call_sv": true,
  "snarls": {"class": "File", "path": "/lustre/…/ref/JaSaPaGe/JaSaPaGe.snarls"}
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

### 7.2 投入せずに確認する（dry run）

```bash
cd /lustre/…/pggl-workflow
scripts/submit-slurm.sh --job /lustre/…/runs/NA18945/job.json \
  --workdir /lustre/…/runs/NA18945/check --partition <partition> --dry-run
cat /lustre/…/runs/NA18945/check/env.sh | grep -E 'SBATCH|LANE_SET'
rm -rf /lustre/…/runs/NA18945/check
```

job ファイルのパスの誤りや必須項目の抜けは、ここで分かります。

### 7.3 投入する

```bash
scripts/submit-slurm.sh \
  --job /lustre/…/runs/NA18945/job.json \
  --workdir /lustre/…/runs/NA18945/run1 \
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

> **sbatch オプションを自分で書くときは、必ず `--mem` を付けてください。**
> パーティションの既定が「CPU あたり 8 GB」のような場合、`--exclusive` と 128 CPU で
> 1 TB を要求したことになり、どのノードにも入らず `PENDING (Resources)` のまま
> 動きません。

### 7.4 進捗を見る

```bash
W=/lustre/…/runs/NA18945/run1
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
```

作業ディレクトリには中間ファイル（`prepare-out/` の FASTQ、`lanes/*/out/` のレーン
BAM・GAM）が残ります。結果を確認したら削除してかまいません。

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
apptainer exec --bind /lustre --bind /tmp deepvariant-opencode-cpu-vg.sif \
  cwltool --no-container --outdir out/ --tmpdir-prefix $PWD/tmp/ --tmp-outdir-prefix $PWD/tmp-out/ \
  Workflows/germline-pangenome-cpu.cwl job.local.json
```

レーンは 1 つずつ順に処理されます（cwltool の `--parallel` は、レーン数が多いと
ステージングの競合で失敗することがあるため使いません）。

関連ドキュメント:

- `README.md` — 入力・出力の一覧、設計、各機能の詳細
- `docs/OFFLINE.md` — オフラインバンドルのオプションの詳細
