[English README](../README.md) | [WaitIOの文献案内](WAITIO_RESOURCES.md)

[使い方](GUIDE.md) | [Miyabi](MIYABI.md) | [参考文献](WAITIO_RESOURCES.md)

[設定と共有プロジェクト](CONFIGURATION.md)

# WaitIO.jl

WaitIO.jlは独立して動く並列プログラムとJuliaの間でデータを交換するためのパッケージです。
各プログラムは自身のMPI環境を使い、プログラム間の通信にWaitIOを使います。
現在はWisteria/BDEC-01のOdyssey・Aquariusと、Miyabi-G・Miyabi-Cでの利用を想定しています。

## どのような計算に使うか

CPU側のシミュレーションが計算途中のデータを送り、GPU側の別プログラムで解析や学習を行う場面を考えます。
このように、複数のプログラムがデータを交換しながら計算を進めることを連成と呼びます。
両側で使うMPI実装や計算機の構成が異なっていても、それぞれの実行環境を保って通信できれば、
各プログラムに合う計算資源を使えます。

WaitIOは独立して起動されたMPIプログラムを接続する通信ライブラリです。
異なるプロセッサ、MPI実装、ネットワークを使うプログラム間の通信について、
[WaitIO-Socketの論文（Sumimotoほか、2023）](https://doi.org/10.1007/978-3-031-29927-8_25)で説明されています。
MPI自体にもプロセス群を接続する機能はありますが、異なるMPI実装同士の接続がそのまま保証されるわけではありません。
利用条件は[MPIの接続機能の説明](https://docs.open-mpi.org/en/main/man-openmpi/man3/MPI_Comm_accept.3.html)も参照してください。

```text
システムA                                 システムB
シミュレーション                          Juliaによる解析・学習
ローカルのMPI A                           ローカルのMPI B
       |                                         |
       +--------------- WaitIO ------------------+
```

WaitIO.jlはこの通信をJuliaから扱うためのパッケージです。MPI.jlを参考にした配列の送受信、
非同期要求、集団通信のAPIと、Julia同士で独自型を転送する機能を提供します。
80個のC関数名に対応する低水準APIもあります。利用できる関数は導入済みのWaitIOに依存します。MPI.jlの完全な互換実装ではありません。
Julia 1.10以降に対応しています。

WaitIO本体は2026年11月時点ではオープンソースではなく、ソースコードは公開されていません。
今後オープンソース化される予定です。
WaitIO.jlは別のソフトウェアとして[MITライセンス](../LICENSE)で配布しています。
利用には、施設に設置されたWaitIO・MPIのライブラリとヘッダーが必要です。

詳しい使い方は[日本語ガイド](GUIDE.md)を参照してください。
MPI.jlとの対応、独自型の転送、ライブラリ設定を説明しています。

## インストール

GitHubのリポジトリからインストールします。

```julia
using Pkg
Pkg.add(url="https://github.com/cometscome/WaitIO.jl.git")
```

`using WaitIO` でパッケージを読み込みます。

## システム名を選んで設定する

対象システムで対応するMPIモジュールを読み込み、
`WAITIO_COMM_TYPE=socket` を設定してから、使用するJuliaプロジェクトで次を実行します。

```julia
using WaitIO
WaitIO.use_system_library("miyabi-dev-g")
```

エイリアスを選ぶと、対象システムのライブラリとヘッダーのパス、必要な設定が選ばれます。

| エイリアス | 対象 | MPIモジュール |
| --- | --- | --- |
| `miyabi-dev-g` | Miyabi-G、開発版WaitIO | `nvidia/24.9 nv-hpcx/24.9` |
| `miyabi-dev-c` | Miyabi-C、開発版WaitIO | `intel/2023.2.0 impi/2021.10.0` |
| `miyabi-g` | Miyabi-G、aarch64 | `nvidia/25.9 nv-hpcx/25.9` |
| `miyabi-c` | Miyabi-C、x86_64 | `intel/2023.2.0 impi/2021.10.0` |
| `wisteria-odyssey` | Odyssey、A64FX | `fj/1.2.43 fjmpi/1.2.43` |
| `wisteria-aquarius` | Aquarius、x86_64 | `intel/2023.0.0 impi/2021.8.0` |

Miyabiの開発版を使う場合は、上のMPIモジュールを読み込んでから次を設定します。

```sh
export WAITIO_DIR=/work/share/waitio-rt/opt/waitio
export LD_LIBRARY_PATH="$WAITIO_DIR/lib:/usr/ofed/lib:${LD_LIBRARY_PATH:-}"
export PATH="$WAITIO_DIR/bin:$PATH"
```

それ以外のエイリアスでは、施設の `waitio/1.0` モジュールも読み込みます。

設定内容はライブラリを読み込まずに確認できます。

```julia
WaitIO.site_defaults("wisteria-odyssey")
```

WisteriaとMiyabiの開発版エイリアスは `/work/share/waitio-rt/opt/waitio` を選びます。
`miyabi-dev-c`／`miyabi-dev-g` は、開発者が案内したMiyabiの開発版を使う設定です。
従来の `miyabi-c`／`miyabi-g` は `/work/opt/local` 以下の導入版を選びます。
開発版のリクエスト構造体は360バイトで、従来版の88バイトとは異なります。
エイリアスのパスは、モジュールの既定値と異なる場合があります。
エイリアスを指定すると、`WAITIO_LIB` と `WAITIO_INC` による自動検出は使いません。
移設されたライブラリを使う場合は `library_dir` と `include_dir` を明示して上書きできます。
ABIとCPUの検査を行います。既知のヘッダー配置に一致すれば、新しいバイナリのハッシュも受け付けます。異なるCPU向けのエイリアスは選べません。

設定は検証後にPreferences.jlで保存します。保存後は新しいJuliaプロセスでアプリケーションを起動してください。
既存の異なる設定を置き換える場合は `force=true` が必要です。

### 共有プロジェクトでは設定ファイルを分ける

同じディレクトリを両側から使う場合は、共通の設定を上書きせず、各側で別ファイルを作ります。
次の2つの呼び出しはそれぞれ対象システムで実行してください。

```julia
# Miyabi-Gで実行
WaitIO.use_system_library("miyabi-dev-g"; config_file="config/miyabi-g.toml")

# Miyabi-Cで実行
WaitIO.use_system_library("miyabi-dev-c"; config_file="config/miyabi-c.toml")
```

Wisteriaでも同じ方法で設定できます。

```julia
# Odysseyで実行
WaitIO.use_system_library("wisteria-odyssey"; config_file="config/odyssey.toml")

# Aquariusで実行
WaitIO.use_system_library("wisteria-aquarius"; config_file="config/aquarius.toml")
```

各ジョブで `WAITIO_JL_CONFIG` に対応するファイルを指定します。たとえばG側では
`export WAITIO_JL_CONFIG="$PWD/config/miyabi-g.toml"` を設定します。
書き込み用のJulia depotも各側で分け、依存パッケージはジョブ投入前に用意します。
詳細は[共有プロジェクトの設定例](../README.md#one-shared-project-separate-gc-configurations)を参照してください。

エイリアスが行うのはライブラリの選択と検証・保存です。モジュールの読み込み、ジョブ投入、
通信相手の発見、ネットワークの設定は施設の手順に従って準備してください。
登録パスは2026年11月の試験で使ったもので、施設側の更新後は再確認が必要です。

### パスを直接指定する

別のインストール先を使う場合は、ライブラリとヘッダーのパスを指定できます。

```julia
using WaitIO
WaitIO.use_system_library(
    libwaitio = "/site/waitio/lib/libwaitio_intel.so",
    libwaitio_mpi = "/site/waitio/lib/libwaitio_mpi_intel.so",
    include_dir = "/site/waitio/include",
)
```

`libwaitio_mpi` はWaitIOの集合通信ライブラリです。MPI本体の `libmpi.so` とは異なります。
計算ノードから参照できる絶対パスを指定してください。
エイリアスはライブラリの場所とABIを選び、通信関数はそのまま使います。

### 設定の確認

```julia
WaitIO.configuration_info()
WaitIO.check_library(verbose=true)
```

`configuration_info()` は有効な設定とその出所を返します。
`check_library(verbose=true)` はライブラリを読み込み、互換性とパスを確認します。
ライブラリの読み込み後に設定を変える場合は、新しいJuliaプロセスで実行してください。

設定は `configure!` の明示指定、環境変数、`WAITIO_JL_CONFIG` で選んだファイルの順に優先されます。
ファイルを指定しない場合はPreferences.jlの設定を読みます。
詳細は[設定と共有プロジェクト](CONFIGURATION.md)、
対応するライブラリの条件は[互換性の説明](../docs/COMPILER_FREE.md)を参照してください。

## 非同期通信

通常の WaitIO ジョブ設定とランチャーを使い、全参加ジョブを起動します。
以下は 2 ランクの例です。ランク・PB ID は C と同じ **0 始まり**です。

```julia
using WaitIO
WaitIO.Init()
comm = WaitIO.Comm_world()
rank = WaitIO.Comm_rank(comm)
@assert WaitIO.Comm_size(comm) == 2
peer = 1 - rank

sendbuf = fill(Float64(rank), 1024)
recvbuf = zeros(1024)
recvreq = WaitIO.Irecv!(recvbuf, comm; source=peer, tag=10)
sendreq = WaitIO.Isend(sendbuf, comm; dest=peer, tag=10)

# ここで通信対象以外の配列を使う計算が可能です。
WaitIO.Waitall([recvreq, sendreq])
@assert all(==(Float64(peer)), recvbuf)
WaitIO.Finalize()
```

`Request` と実行時管理表が配列・要求領域を完了まで保持します。利用側で要求の参照を
失っても GC で解放されません。`Drain()` で保持中の要求をすべて待てます。
**通信中の配列の書換え・resize・受信結果の読出しは禁止**です。
複数の受信に重なる領域を渡すことも避けてください。

- `Send`, `Recv!`: 完了まで待つ送受信。
- `Wait`, `Test`, `Waitall`, `Testall`, `Waitany`, `Testany`, `Waitsome`, `Testsome`: 要求の完了操作。
- `Wait(req)`、`wait(req)`、`Waitall` 等はTestを繰り返し、待っている間もJuliaに制御を返します。
- any/some が返す配列内の添字は Julia と同じ **1 始まり**です。全完了なら添字は `nothing`。
- `Testall` は全要求の完了までバッファを保持し、既に確認した native 完了を再消費しません。
- 非連続viewは自動で詰め直します。デバイス配列は `Array` と一括転送の `copyto!` が使えればホスト経由で転送します。GPU直接通信ではありません。
- 送受信の長さはバイト単位で導出します。相手との型・長さ・エンディアンの一致は利用側の責任です。

非同期APIを使って待機を後回しにできても、通信と計算が効率よく重なるかどうかは実測が必要です。
ここで示す動作試験は低遅延や性能向上を検証したものではありません。

## C・Fortranとの連成

既存プログラムのMPI環境を保ち、データを交換する箇所にWaitIOの送受信を組み込みます。
すでに対応するWaitIO通信を持つプログラムでは、その処理を利用できます。
任意のシミュレーションコードを無変更で接続する機能ではありません。

最初は連続したホスト配列を使い、両側で要素の表現、個数、相手のランク、タグ、
送受信の順序と同期方法をそろえます。構造体の配置やエンディアンを自動変換する機能はありません。
格子の補間などはアプリケーションや、別の連成ライブラリで扱います。
Juliaのシリアライズによる独自型の転送は、Julia同士で使います。

## Julia の独自型を転送する

小文字の `send` / `recv` / `isend` は Julia の Serialization を使います。
文字列・辞書・配列を含む独自の `struct` も転送できます。
両側でJuliaのバージョン、型定義、依存パッケージをそろえてください。

```julia
# 送信側
request = WaitIO.isend((name="training", coordinates=rand(3, 100)), comm; dest=1, tag=20)
WaitIO.Wait(request)

# 受信側
batch = WaitIO.recv(comm; source=0, tag=20)
```

`isend` は呼出し中にシリアライズし、その時点のバイト列を非同期送信します。
`bcast` と `gather` もオブジェクトに対応します。独自型の非同期受信は未対応です。
この形式は Julia 同士で使い、C・Fortran との配列通信には大文字 API を使います。
上限、タグの使い分け、型の互換性は [日本語ガイドの第6節](GUIDE.md#6-julia-の独自型を転送する)、
利用できる機能は[動作確認と制約](#動作確認と制約)を参照してください。

## 集合通信・グループ・メモリ

`Barrier`, `Bcast!`, `Reduce!`, `Allreduce!`, `Gather!`, `Allgather!`, `Scatter!`,
`Gatherv!`, `Allgatherv!`, `Scatterv!`, `Scan!`, `Exscan!`, `Alltoall!` を実装しています。

通常の集合通信は対応するWaitIO本体のC関数を呼びます。
`Barrier` は `waitio_mpi_barrier` を呼び、Allreduceには置き換えません。
C・Fortran側も対応するネイティブ関数を使い、型・要素数・ルート・演算・呼出し順をそろえてください。
ライブラリ側に不具合がある場合、それを別の通信手順に置き換えて隠すことはしません。

```julia
WaitIO.Allreduce!([1.0], result, WaitIO.SUM, comm)
WaitIO.Allgatherv!(local_values, WaitIO.VBuffer(all_values, counts), comm)
WaitIO.Alltoall!(WaitIO.UBuffer(send_values, count_per_rank),
                WaitIO.UBuffer(recv_values, count_per_rank), comm)
```

`VBuffer` の count/displacement は要素数で、displacement は 0 始まりです。
`Gather!` / `Gatherv!` / `Reduce!` の非ルート受信バッファと、
`Scatter!` / `Scatterv!` の非ルート送信バッファには `nothing` を指定できます。
WaitIO が必要とする内部作業領域・ローカル count はラッパーが補います。
C int の count/byte 制限、要素型、配列の範囲を検査します。

配列の転送には `isbits` の要素型を使えます。非連続配列は自動で詰め直します。
GPU配列なども、`Array` と一括転送の `copyto!` が使えれば、ホストメモリ経由で転送します。GPU実機では未検証です。

集合通信は入力を退避してin-place操作に対応します。例えば `Allreduce!(values, SUM, comm)` と書けます。
通常の集計には、WaitIO本体に対応する型と演算が必要です。
`Int8`・`UInt8` は `WAITIO_MPI_CHAR` を使います。符号の扱いはCライブラリのビルドに従うため、
Juliaの型や相手の計算機と一致するとは限りません。Julia側で暗黙に整数型を変更することはありません。
必要なら、両側で明示的に同じ型へ変換してください。例えば `WAITIO_MPI_LONG` を使う場合は、両側で8バイトであることを確認します。
ネイティブ型とJuliaの要素型の大きさが異なれば、通信前にエラーになります。
`ValueLoc{Float64,Int32}` の集計にはネイティブの `DOUBLE_INT` と `MAXLOC`・`MINLOC`、および一致するメモリ配置が必要です。

### Julia同士で使う拡張

ネイティブにない型の集計、複素数のSUM、位置付きの値、`Op(f)` による独自演算は、
`WaitIO.Extensions` を明示して使えます。

```julia
WaitIO.Extensions.Allreduce!(values, WaitIO.SUM, comm)
WaitIO.Extensions.Allreduce!(best, WaitIO.MAXLOC, comm)
```

全参加者が同じ拡張の通信手順を使う必要があります。通常のCの集合通信関数とは混在できません。
拡張ではバイト通信で集めた値をJuliaで計算し、ネイティブ集計を使う一部の整数型は64ビットへ変換します。
位置付きの値には `ValueLoc(値, 位置)` または `(値, 整数の位置)` を使い、同値なら小さい位置を選びます。
独自演算は結合法則を満たし、結果を元の要素型で表せるものを指定します。整数のSUMは元のビット幅に収めます。
`Extensions.Barrier` はInt32のSUM Allreduceを使います。通常の `Barrier` から自動で選ばれることはありません。
小文字の `send`・`recv`・`bcast`・`gather` もJulia専用の形式です。C・Fortranとの通信には型と配置を決めた配列を使ってください。

### グループとメモリ登録

`Create_group(gid; selection=[:all, :head, :none, ...])` と `Comm_pbheads(gid=...)` で
グループを作成できます。除外するプロセスも含め、全プロセスで ID と選択を統一してください。
必要なグループをすべて作成し、`Barrier(Comm_world())` で同期してから使います。
ランク・サイズの取得と通信は `Ismember` が真のプロセスだけで行います。
`Comm_rank`, `Comm_size`, `Ismember`, `PB_rank`, `PB_size`, `PB_nprocs`, `Hostinfo`,
`PB_hostinfo` で情報を取得します。
`order` はそのままネイティブのグループ作成関数へ渡します。Julia側だけでランクを変換しないため、
`Comm_rank` と `comm.handle` を使うC側は同じランク番号を扱います。
`Extensions.Create_group` は、元のPB順で作ったグループにJulia側のランク対応を追加する別の機能です。
そのグループでは `Extensions` の集合通信を使い、全参加者が同じランク対応と通信手順を守ってください。

`Register!` / `Unregister!` はホストメモリ登録を管理し、通信中の解除を拒否します。
実機でのRDMAメモリ登録は未検証です。
C の登録 API は void を返すため、整数の戻り値によるエラー検査はできません。

## 初期化・エラー・終了

`Init(mpi=:auto)` は MPI 未初期化なら MPI_Init_thread(SERIALIZED) を呼び、
自分が開始した MPI だけを `Finalize()` で終了します。
`Init(mpi=:external)` は既に初期化された MPI を使用し、MPI を終了しません。
MPI.jl と併用する場合も同じ MPI 共有ライブラリが必要です。

MPIがSERIALIZED以上に対応すれば、複数のJuliaスレッドから呼べます。WaitIO.jlがネイティブ関数への呼出しを順番に処理します。
MPIがFUNNELEDのみを提供する場合は、MPIの要件に従って初期化したOSスレッドから呼んでください。
同じMPIを使う他のパッケージとの同時呼出しは、利用側でも調整する必要があります。
集合通信の順序は全ランクでそろえ、初期化と終了は同じOSスレッドで行ってください。

非ゼロの失敗戻り値は `WaitIOError` に変換します。`Test` の未完了値はサイト設定
`test_pending` で区別します。通信開始・完了確認のエラーでは
ネイティブ側の所有権を断定できないため、要求とバッファを保持し、強制解放しません。
その場合は新しいプロセスで再起動する必要があります。

`Finalize()` は未完了要求があると `PendingRequestsError` を返します。
先に `Waitall` または `Drain` で完了させてください。
`Finalize()` は明示的に呼び出してください。終了後の再初期化には対応していません。

## 低水準API

`WaitIO.API` は同名のネイティブ関数を呼びます。`layered` と `Nnary`、大文字と小文字の関数名を区別します。
関数がライブラリになければ、その旨を報告し、別の関数には置き換えません。
80関数のラッパーがあることは、全サイトで80関数を使えるという意味ではありません。
利用可能な関数は `capabilities()` で調べられます。
旧設定の `miyabi_compat`・`native_fixes` は読み込めますが、警告を出して無視します。

高水準の `Wait`・`Waitall` は、バッファを保持しながら各要求の完了を確認します。
Cの状態配列が必要な場合は、連続したネイティブ要求配列と `API.waitio_mpi_waitall` を使ってください。
ポインタ・バッファ寿命・エラー検査・MPI/WaitIO の状態管理は呼出し側の責任です。
`API.request_alloc/request_free/request_size` は raw 要求用、`API.global_pointer`
は公開 extern 変数の上級者向けアクセスです。高水準 `Request.native` を自分で free しないでください。
native `waitall` は構造体の連続配列を要求するため、Julia の Request 配列を直接渡せません。

## 動作確認と制約

Miyabi-C/GとWisteria Odyssey/Aquariusで、C同士・Julia同士・両方向のC/Julia混在通信を確認しています。
ソケット通信とCPU上の配列を使い、各システムにMPIプロセスを1つずつ置く構成です。
利用できる関数と型の扱いは、導入済みのWaitIOによって異なります。

- `miyabi-dev-c`／`miyabi-dev-g` が選ぶ開発版では、Int64のAllreduce、MPI形式のInt64送受信、Gather・Scatterを確認しています。
  従来の `miyabi-c`／`miyabi-g` が選ぶ版には、LONG型のサイズ不一致と関数の欠落があります。
- 試験したMiyabi開発版とWisteriaの導入版では、CHAR型のMAX集計に対応していません。
  これらのライブラリではInt8・UInt8のMAX集計を使わないでください。
- 大文字の `WAITIO_MPI_Allgatherv` はどちらのライブラリにもありません。
  利用可能な関数は `capabilities()` で確認できます。80個のラッパーがあることは、全関数の利用や動作を保証しません。
- GPU配列、RDMA、PB内の複数ランク、Fortranとの通信、性能は、この通信試験では確認していません。

ジョブの例は[Miyabi](../test/native/miyabi/README.md)と[Wisteria](../test/native/wisteria/README.md)にあります。
導入先のライブラリを確かめるには、[C/Julia比較試験](../test/native/reference/README.md)を利用できます。

## ライセンス

WaitIO.jlは[MITライセンス](../LICENSE)で配布しています。著作権者はYuki Nagaiです。
環境にあるWaitIO本体とMPIのライブラリには、それぞれの利用条件が適用されます。

## 参考文献

WaitIO本体の通信方式については次の論文を参照してください。
論文中の性能結果はWaitIO.jlを測定したものではありません。

1. Shinji Sumimoto et al., [A System-Wide Communication to Couple Multiple MPI Programs for Heterogeneous Computing](https://doi.org/10.1007/978-3-031-29927-8_25).
   PDCAT 2022, LNCS 13798, pp. 314–327, 2023年刊行。WaitIO-Socketの構成と異種MPIプログラムの接続を説明しています。
2. Shinji Sumimoto et al., [WaitIO-Hybrid: Communication for Coupling MPI Programs Among Heterogeneous Systems](https://doi.org/10.1007/978-981-96-4207-6_13).
   PDCAT 2024, LNCS 15502, pp. 140–153, 2025年刊行。ソケットと共有ファイルを使った通信を扱っています。
3. Shinji Sumimoto et al., [Accelerating Heterogeneous Coupling Computing with WaitIO Using RDMA](https://doi.org/10.1145/3703001.3724382).
   HPC Asia 2025 Workshops, pp. 1–10, 2025。WaitIO-VerbsとWaitIO-Tofuを扱っています。

講習会と講演資料は[文献案内](WAITIO_RESOURCES.md)にまとめています。
