# 設定と共有プロジェクト

WaitIO.jlでは計算コードと実行環境の設定を分けます。MiyabiのC/Gで同じディレクトリを
使う場合も、各ジョブが自分の設定ファイルを読むため、同じJuliaプロジェクトから実行できます。

## 初期設定

実行する環境で、対応するMPIとWaitIOのモジュールを読み込んでください。
Juliaを `--project=/path/to/project` で起動し、次のように設定します。

```julia
using WaitIO
WaitIO.use_system_library(
    libwaitio = "/site/waitio/lib/libwaitio_intel.so",
    libwaitio_mpi = "/site/waitio/lib/libwaitio_mpi_intel.so",
    include_dir = "/site/waitio/include",
)
```

ライブラリ、CPU、ヘッダー、ABI、必要なシンボルを確認し、成功したらPreferences.jlを
使ってプロジェクトのローカル設定に保存します。通常の保存先は `LocalPreferences.toml` です。
既に `JuliaLocalPreferences.toml` があれば、そちらを使います。
保存後は新しいJuliaプロセスでアプリケーションを起動してください。
既存の設定を異なる値で上書きするときは、`force=true` を指定します。

モジュールが `WAITIO_LIB` と `WAITIO_INC` を設定する環境では、それらを使ってライブラリを
検出できます。候補が一組なら `WaitIO.use_system_library()` だけで設定できます。
複数ある場合は `variant="intel"` などを指定するか、二つのライブラリのパスを明示します。
CPUの種類からコンパイラやMPIを推測することはありません。

`libwaitio_mpi` はWaitIOの集合通信ライブラリで、MPI本体の `libmpi.so` とは異なります。
`include_dir` には `waitio.h`、`waitio_mpi.h`、`waitio-lib.h` が必要です。
設定には実行環境の `Sys.MACHINE` も保存します。別のCPU向けの設定を選んだ場合は、
ライブラリを読み込む前にエラーになります。WaitIOやMPIを更新したときは設定を作り直してください。

## 同じ共有ディレクトリをC/Gで使う

アプリケーション、`Project.toml`、`Manifest.toml` は共通にし、設定ファイルを分けます。
次の例は共有プロジェクトのディレクトリで `julia --project=.` を使う場合です。
Miyabiでは両側とも `WAITIO_COMM_TYPE=socket` を設定してください。

G側では次を一度実行します。

```julia
using WaitIO
WaitIO.use_system_library(
    library_dir = ENV["WAITIO_LIB"],
    include_dir = ENV["WAITIO_INC"],
    variant = "nvidia",
    config_file = "config/miyabi-g.toml",
)
```

C側では `variant="intel"`、`config_file="config/miyabi-c.toml"` として実行します。
既存ファイルの置換には `force=true` が必要です。二つのジョブから同じ設定ファイルを
上書きする運用は避けてください。

各ジョブで対応するモジュールを読み込み、共有プロジェクトのディレクトリへ移動します。
G側の設定選択と起動は次の形です。

```bash
export WAITIO_JL_CONFIG="$PWD/config/miyabi-g.toml"
export JULIA_DEPOT_PATH="$PWD/depot-g:"
export WAITIO_COMM_TYPE=socket
# WAITIO_PBID、参加グループ数、接続先ホストとポートも設定する。
mpirun -np 1 julia --project=. simulation.jl
```

C側では設定ファイルを `miyabi-c.toml`、depotを `depot-c` に変え、
`mpiexec.hydra -n 1 julia --project=. simulation.jl` で起動します。
計算コードには `using WaitIO` と `WaitIO.Init()` を書き、ライブラリのパスは書きません。

両depotへの依存パッケージの導入は、ジョブ投入前に済ませてください。
`JULIA_DEPOT_PATH` の末尾の `:` はJuliaのシステムdepotを残しますが、通常のユーザーdepotは
含めません。ネットワークに接続できない環境では、必要なパッケージを用意した共通depotを
追加できます。[試験用スクリプト](../test/native/miyabi/README.md)では
`depot-g` または `depot-c` を書き込み先とし、`depot-shared` から依存パッケージを読みます。

通常の実行では設定を読み込むだけで、設定ファイルやManifestを書き換えません。
並列実行中に `Pkg.add` や `Pkg.update` を呼ばないでください。
パスは各プロセスの実行時に読み、プリコンパイル結果には固定しません。
ライブラリを読み込んだ後に設定を変更するときは、新しいJuliaプロセスを起動します。

## 設定の優先順位

新しいプロセスでは次の順で設定を優先します。

1. `configure!` に渡したキーワード引数。
2. `WAITIO_JL_LIBWAITIO`、`WAITIO_JL_LIBWAITIO_MPI`、`WAITIO_JL_INCLUDE_DIR`、`WAITIO_JL_ABI_PROFILE`。
3. `WAITIO_JL_CONFIG` が指定するファイル。指定がなければPreferences.jlの設定。

明示したファイルには `libwaitio`、`libwaitio_mpi`、`include_dir` が必要です。
不足する項目をプロジェクトや管理者の設定から補うことはありません。
環境変数でパスを上書きした場合も、ライブラリとヘッダーの組み合わせ全体を検査します。
`configure!(config)` に設定オブジェクトを渡した場合は、その設定を丸ごと採用します。

初期設定用の `use_system_library` は渡した引数と `WAITIO_LIB`・`WAITIO_INC` から
新しい設定を作ります。保存済み設定や `WAITIO_JL_*` の上書き指定は引き継ぎません。
別ジョブの設定が初期設定へ混ざることを防ぐためです。
従来の `configure!`、`load_config`、`save_config` も引き続き使えます。

## 設定を確認する

```julia
WaitIO.configuration_info()        # ライブラリを読み込まずに、有効な設定と取得元を返す
WaitIO.check_library(verbose=true) # ライブラリを確認し、パス・ABI・取得元を表示する
WaitIO.library_info()              # 読み込んだ設定とABIの情報を返す
```

`using WaitIO` は、WaitIO本体が設置されていない環境でも実行できます。
設定不足はライブラリの確認時や通信開始時に知らせます。
Preferences.jlを使えば、管理者が `JULIA_LOAD_PATH` 上に共通設定を配布し、
利用者がプロジェクトの設定で上書きできます。管理者向けの設定例は[英語README](../README.md)にあります。

ライブラリの設定と、通信相手を指定する環境変数は別に扱います。
`WAITIO_PBID`、参加グループ数、接続先ホスト・ポートはジョブごとに設定してください。
全参加者で通信手順をそろえる必要があります。ライブラリを読み込めることだけでは、
異なるWaitIOの版同士で通信できることまでは保証できません。
独自型の転送には両側で同じJuliaバージョンと型定義を使ってください。
MPI.jlも同じプロセスで使う場合は、WaitIOが使うものと同じMPI実装を選んでください。
