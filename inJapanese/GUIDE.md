# WaitIO.jl 日本語ガイド

WaitIO.jl は WaitIO を使った通信を Julia から扱うパッケージです。
数値配列の送受信に加え、Julia の独自型、辞書、文字列も転送できます。
非同期通信では要求オブジェクトを返し、通信が終わるまで必要な配列を保持します。

このガイドは Julia のプログラムに WaitIO を組み込む人向けです。
MPI.jl との対応、配列と独自型の転送、ライブラリの設定を説明します。
実行できるサンプルと起動手順は[実行例](../examples/README.md)にあります。

## 1. WaitIO.jl の役割

WaitIO は別々のジョブで動くプログラムを接続する通信ライブラリです。
WaitIO.jl は実行環境にある WaitIO の共有ライブラリを Julia から呼び出します。
通信先が C や Fortran の場合も、相手と配列の型、長さ、タグをそろえて送受信できます。

API は二つの層に分かれています。
通常は `WaitIO.Isend` や `WaitIO.recv` などの利用者向け API を使います。
この層が引数、要求領域、配列の寿命、戻り値を管理します。
C の引数をそのまま指定したい場合は、`WaitIO.API` の低水準 API を使います。
低水準 API ではポインタやエラー処理を呼出し側で管理します。

MPI.jl は API 設計の参考にしています。
WaitIO.jl は MPI.jl に依存しておらず、両者の通信形式や型にも互換性はありません。
WaitIO が内部で使う MPI は、実行環境が提供する MPI です。

## 2. MPI.jl との対応

WaitIO.jl は要求を通信ごとのオブジェクトとして扱います。複数の通信を同時に開始できます。
利用側で共有の要求領域を使い回す必要はありません。

通信中の Julia 配列はパッケージが保持します。
要求の参照を利用側で失っても、配列が GC に回収されないようにしています。
GC は使われなくなった Julia オブジェクトのメモリを回収する仕組みです。

また、MPI.jl の大文字・小文字の API の使い分けを採用しました。
`Send` や `Isend` は配列を直接転送します。
`send` や `isend` はオブジェクトをバイト列に変換して転送します。
この変換をシリアライズと呼びます。
独自の `struct` に文字列や辞書が含まれていても、小文字の API で送れます。

| 目的 | MPI.jl | WaitIO.jl | 主な違い |
|---|---|---|---|
| 初期化・終了 | `Init`, `Finalize` | `Init`, `Finalize` | WaitIO の初期化と MPI の所有権を管理します |
| 初期化・終了状態の取得 | `Initialized`, `Finalized` | 同名の関数 | WaitIO の状態を返します |
| 全参加者の通信グループ | `COMM_WORLD` | `Comm_world()` | MPI の定数ではなく、初期化後に取得する WaitIO グループです |
| ランク番号・参加者数 | `Comm_rank`, `Comm_size` | 同名の関数 | ランク番号はどちらも 0 始まりです |
| 配列の同期送受信 | `Send`, `Recv!` | 同名の関数 | WaitIO.jl は非連続配列もホスト経由で扱います |
| 配列の非同期送受信 | `Isend`, `Irecv!` | 同名の関数 | WaitIO.jl が通信ごとに要求領域を確保します |
| 完了待ち・完了確認 | `Wait`, `Test` と all/any/some 系 | 同名の関数 | any/some 系は WaitIO の Test から構成しています |
| Julia オブジェクトの送受信 | `send`, `recv` | 同名の関数 | WaitIO.jl 独自の長さ通知を付けます |
| Julia オブジェクトの非同期送信 | `isend` | `isend` | `ObjectRequest` を返します |
| Julia オブジェクトの一斉配信 | `bcast` | `bcast` | Julia の Serialization を使います |
| Julia オブジェクトの収集 | `gather` | `gather` | ルートに `Vector{Any}` を返します |
| 同期・集合通信 | `Barrier`, `Bcast!`, `Allreduce!` など | 同名の関数群 | 型、演算、in-place 操作の対応範囲が異なります |
| 配列と要素数の指定 | `Buffer`, `UBuffer`, `VBuffer` | 同名の型 | MPI.jl のバッファ型をそのまま渡すことはできません |

対応する名前でも、引数や戻り値がすべて一致するわけではありません。
たとえば MPI.jl は `isbits` の値を `Send` / `Recv` で扱えますが、
WaitIO.jl の大文字 API は対応する配列を対象にしています。
WaitIO.jl で独自型の値を転送するときは、小文字の `send` / `recv` を使ってください。

MPI.jl の送受信とオブジェクト転送の仕様は、
[Point-to-point communication](https://juliaparallel.org/MPI.jl/stable/reference/pointtopoint/) を参照してください。
オブジェクトの一斉配信と収集は、
[Collective communication](https://juliaparallel.org/MPI.jl/stable/reference/collective/) を参考にしています。

## 3. 配列の一部を送る

`Isend` / `Irecv!` は要求オブジェクトを返します。
配列の一部を転送する場合は、要素数とオフセットを `Buffer` で指定します。

```julia
buffer = WaitIO.Buffer(values; count=100, offset=20)
request = WaitIO.Isend(buffer, comm; dest=1, tag=10)
WaitIO.Wait(request)
```

この例では先頭から 20 要素を飛ばした位置から 100 要素を送ります。
`count` と `offset` はバイト数ではなく要素数です。

低水準 API には、対応するWaitIOのCヘッダーに基づく80関数のラッパーがあります。
この件数には大文字・小文字の別名や補助関数も含まれます。
80 種類の通信方式があるという意味ではありません。
利用できる関数は導入済みのWaitIOに依存します。

## 4. インストールとライブラリの指定

### 4.1 パッケージを読み込む

GitHubのリポジトリからインストールします。

```julia
using Pkg
Pkg.add(url="https://github.com/cometscome/WaitIO.jl.git")
```

開発用のチェックアウトを使う場合は、代わりに `Pkg.develop` を指定します。

```julia
using Pkg
Pkg.develop(path="/path/to/WaitIO.jl")
```

`using WaitIO` だけでは共有ライブラリを読み込まず、通信も初期化しません。
WaitIOと対応するMPIの実行環境を先に選んでください。

### 4.2 ライブラリとヘッダーを設定する

対象システムでMPIモジュールと環境変数を用意してから設定します。
[日本語README](README.md#システム名を選んで設定する)に各システムの手順があります。
次はMiyabi-Gで開発版を選び、共有プロジェクト用の設定を保存する例です。

```julia
using WaitIO
WaitIO.use_system_library("miyabi-dev-g"; config_file="config/miyabi-g.toml")
```

C側では `miyabi-dev-c` と `config/miyabi-c.toml` を使います。
Wisteriaでは `wisteria-odyssey` と `wisteria-aquarius` を選び、設定ファイルも分けます。
保存後は新しいJuliaプロセスでアプリケーションを起動してください。

任意の導入先には `library_dir`・`include_dir`・`variant`、または二つのライブラリの絶対パスを指定できます。
`libwaitio_mpi` はWaitIOの集合通信ライブラリで、MPI本体の `libmpi.so` とは異なります。
ヘッダーには `waitio.h`、`waitio_mpi.h`、`waitio-lib.h` が必要です。

ヘッダーとライブラリの組み合わせでABIを識別します。要求構造体のサイズは、
Wisteria版が352バイト、Miyabiの従来版が88バイト、開発版が360バイトです。
既知のヘッダー配置に一致する再ビルド版は受け付けます。未知の配置には確認済みのカスタムプロファイルが必要です。
`allow_unverified_abi` は旧設定の読み込み用に残っていますが、検査結果を変えません。
詳しくは[ライブラリの互換性](../docs/COMPILER_FREE.md)を参照してください。

### 4.3 保存した設定と環境変数を使う

`save_config` は TOML ファイルの `[WaitIO]` セクションに設定を保存します。
設定ファイルを明示する場合は、次の環境変数を使います。

```sh
export WAITIO_JL_CONFIG=/shared/myproject/site.toml
```

指定がなければ、Preferences.jlでプロジェクトと管理者の設定を読みます。
`use_system_library` の標準の保存先は実行中のプロジェクトのローカル設定です。
明示した設定ファイルは単独で扱い、不足するパスを他の設定から補いません。
C/Gで同じプロジェクトを共有する手順は[設定と共有プロジェクト](CONFIGURATION.md)を参照してください。

個別の値は次の環境変数で上書きできます。

```sh
export WAITIO_JL_LIBWAITIO=/site/waitio/lib/libwaitio_intel.so
export WAITIO_JL_LIBWAITIO_MPI=/site/waitio/lib/libwaitio_mpi_intel.so
export WAITIO_JL_INCLUDE_DIR=/site/waitio/include
```

新しいプロセスで設定を選ぶときの優先順位は、次のとおりです。

1. `configure!` に渡した明示指定
2. 上記の環境変数
3. 明示した設定ファイル。指定がなければPreferences.jlの設定
4. 既定値

`configure!(config)` に設定オブジェクトを渡した場合は、その設定を採用します。
ロード後に別のライブラリへ切り替えることはできません。
設定を変えるときは、新しい Julia プロセスを起動してください。

```julia
WaitIO.configuration_info()         # ライブラリを読み込まずに設定と取得元を確認
WaitIO.check_library(verbose=true) # 通信を開始せず、ABIと基本関数を検査
WaitIO.library_info()               # 選択したファイル、要求サイズ、別名の解決結果
WaitIO.capabilities()               # 関数シンボルの有無
```

`require=[:all]` を指定すると80関数すべてを要求するため、一部の関数がない導入版ではエラーになります。
シンボルが存在することと、その機能の動作確認が済んでいることは別です。
動作確認の範囲は [READMEの動作確認と制約](README.md#動作確認と制約) に記載しています。

## 5. 数値配列を送受信する

次は、2 ランクが互いに配列を送る例です。
各プロセスを通常の WaitIO ジョブ設定とランチャーで起動してください。

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
WaitIO.Waitall([recvreq, sendreq])

@assert all(==(Float64(peer)), recvbuf)
WaitIO.Finalize()
```

`Isend` と `Irecv!` は通信を開始して戻ります。
`Waitall` が返ると、送信配列を再利用し、受信配列の内容を読めます。
同期通信の `Send` / `Recv!` は呼出しの中で通信完了まで待ちます。

直接転送には整数・浮動小数点数・複素数・参照を含まない構造体など、`isbits` の要素型を使えます。
非連続のviewは自動で詰め直します。詰め直す分のコピーと一時メモリが必要です。

C や Fortran との通信では相手とバイト数、要素型、配列の並びをそろえます。
直接転送では型情報を送らないため、受信側が配列を用意する必要があります。

## 6. Julia の独自型を転送する

### 6.1 型の定義を両側で読み込む

文字列や辞書を含む独自型を用意します。
次の定義を `Messages.jl` に保存し、送信側と受信側の両方で読み込んでください。

```julia
module Messages
export TrainingBatch

struct TrainingBatch{T}
    label::String
    coordinates::Matrix{T}
    metadata::Dict{Symbol,Any}
end

end
```

型が所属するモジュールもそろえます。
同じ名前の `struct` を別のモジュールに定義しても、同じ型にはなりません。
Julia と依存パッケージのバージョンもそろえて実行するのが基本です。
型の定義変更やパッケージ更新によって、保存済みのバイト列を復元できなくなる場合があります。
互換性の条件は [Julia の Serialization](https://docs.julialang.org/en/v1/stdlib/Serialization/) に従います。

### 6.2 `send` と `recv` で送る

次のコードは、ランク 0 が独自型の値を送り、ランク 1 が受け取る例です。
ライブラリの設定と WaitIO のジョブ起動は済んでいるものとします。

```julia
using WaitIO
include("Messages.jl")
using .Messages

WaitIO.Init()
comm = WaitIO.Comm_world()
rank = WaitIO.Comm_rank(comm)
@assert WaitIO.Comm_size(comm) == 2

if rank == 0
    batch = TrainingBatch(
        "sample-001",
        reshape(collect(1.0:6.0), 3, 2),
        Dict{Symbol,Any}(:step => 12, :species => ["H", "O"]),
    )
    WaitIO.send(batch, comm; dest=1, tag=20)
else
    batch = WaitIO.recv(comm; source=0, tag=20)
    @assert batch isa TrainingBatch{Float64}
    @assert batch.metadata[:step] == 12
end

WaitIO.Finalize()
```

`recv` は復元した Julia オブジェクトを返します。
受信する行列の大きさや文字列の長さを、あらかじめ受信側で指定する必要はありません。
辞書、タプル、`NamedTuple`、`nothing`、循環参照を含む値も、
Julia の Serialization が扱える範囲で転送できます。

この形式は Julia 同士で使います。
C や Fortran が Julia の独自型をそのまま復元できる形式ではありません。
言語間で座標や力を渡す場合は、大文字の配列 API と共通のデータ仕様を使ってください。

### 6.3 独自型を非同期で送る

```julia
request = WaitIO.isend(batch, comm; dest=1, tag=21)
# 通信と独立した計算
WaitIO.Wait(request)
```

`isend` は呼出し中にオブジェクトをシリアライズします。
その後にバイト列の非同期送信を開始し、`ObjectRequest` を返します。
戻った時点で元のオブジェクトを変更しても、送信中のバイト列には反映されません。
ただし、シリアライズ処理そのものを別スレッドで実行する機能ではありません。

`ObjectRequest` は `Wait`、`Test`、`Waitall`、`Waitany` などに渡せます。
シリアライズ済みデータと要求領域は完了まで保持されます。
同じグループ・送信先・タグへの送信は、呼び出した順番に処理します。
`Wait` や `Test` などの完了確認で、ヘッダーと本体の転送を進めます。

独自型の非同期受信 `irecv` は現在の API にはありません。
受信には `recv` を使います。
配列の非同期受信は `Irecv!` で利用できます。

### 6.4 `bcast` と `gather` を使う

`bcast` は指定したルートランクから全参加者へ同じオブジェクトを配信します。
全ランクが同じルートを指定して呼び出してください。

```julia
settings = WaitIO.bcast(
    rank == 0 ? (layers=[3, 8, 1], options=Dict(:lr => 0.01)) : nothing,
    comm; root=0,
)
```

`gather` は各ランクのオブジェクトをルートへ集めます。
ルートにはランク順の `Vector{Any}` を返し、ほかのランクには `nothing` を返します。

```julia
results = WaitIO.gather((rank=rank, loss=local_loss), comm; root=0)
```

### 6.5 転送形式と上限

対応するWaitIOのC API には、未受信メッセージの長さを調べる Probe がありません。
そのため WaitIO.jl は 16 byte のヘッダーで形式と長さを知らせてから本体を送ります。
ヘッダーの形式識別子は `WJLOBJ02`、長さはlittle-endianのUInt64です。
ヘッダーと本体を同じタグで順に送り、同じ宛先・タグへの連続送信も受け付けます。
以前の `WJLOBJ01` とは互換性がないため、両側で同じバージョンのWaitIO.jlを使ってください。

配列・オブジェクトとも、タグにはCの `unsigned long` の全範囲を指定できます。
同じ相手・コミュニケータで配列通信とオブジェクト通信を行う場合は、タグを分けてください。
Juliaの集合通信が使う `0x574a4c00:0x574a4c17` も、その通信と重ならないようにします。

`maxbytes` には用途に応じた上限を指定できます。既定値は `typemax(Int)` で、実際に扱える量は利用可能なメモリとネイティブ通信層によります。
送受信側で同じ上限を使ってください。
受信した長さは受信配列を確保する前に検査します。
送信側のシリアライズ中のメモリ使用量を、この上限で制限する機能はありません。

Serialization は信頼できる通信相手との間で使ってください。
プロセス固有のポインタ、ファイルのハンドル、GPU の資源を、そのまま相手で再利用する機能ではありません。
CUDA 配列を含む学習用データは、必要な配列をホストへ移してから転送します。

## 7. 非同期通信の完了を確認する

| 操作 | 戻り値・動作 |
|---|---|
| `Wait(req)` | 要求が完了するまで待ちます |
| `Test(req)` | 完了していれば `true` を返します |
| `Waitall(reqs)` | すべての要求が完了するまで待ちます |
| `Testall(reqs)` | すべて完了していれば `true` を返します |
| `Waitany(reqs)` | 完了した要求の添字を返します。全完了なら `nothing` |
| `Testany(reqs)` | `(完了したか, 添字)` を返します。全完了なら `(true, nothing)` |
| `Waitsome(reqs)` | 完了した要求の添字の配列を返します。全完了なら `nothing` |
| `Testsome(reqs)` | 今回完了した要求の添字を返します。未完了だけなら空配列 |
| `Drain()` | パッケージが保持している要求をすべて待ちます |

any/some 系が返す添字は 1 始まりです。
相手のランク番号が 0 始まりであることと区別してください。
`Testsome` も、すべて完了していれば `nothing` を返します。

大文字の配列 API では通信中の配列を書き換えたり、`resize!` したりしないでください。
受信配列の内容を読むのも完了後です。
パッケージによる保持は GC から守るためのもので、利用側の書換えを防ぐ仕組みではありません。

`Wait(req)`、`wait(req)`、all/any/some 系の待機はTestを繰り返し、Juliaに制御を返します。
通信処理を別スレッドで進める専用の処理はありません。

## 8. 数値配列の集合通信

集合通信は、同じグループの参加者がそろって呼ぶ操作です。
同じ順序で、同じルートや対応する要素数を指定してください。

| API | 用途 |
|---|---|
| `Barrier` | 全参加者の同期 |
| `Bcast!` | ルートから配列を配信 |
| `Reduce!`, `Allreduce!` | SUM・MIN・MAX の結果をルートまたは全参加者へ返す |
| `Gather!`, `Allgather!` | 各ランクから同じ要素数の配列を収集 |
| `Gatherv!`, `Allgatherv!` | ランクごとに異なる要素数の配列を収集 |
| `Scatter!`, `Scatterv!` | ルートの配列を各ランクへ分配 |
| `Scan!`, `Exscan!` | ランク順の累積演算。Exscan は自ランクの値を除く |
| `Alltoall!` | 各ランクが全ランクへ同じ要素数ずつ送る |

`Barrier` は、ネイティブの `waitio_mpi_barrier` を呼びます。C側も同じ関数を呼んでください。
以前調べたCライブラリでは、この関数が全員の到着を待たずに戻る問題がありました。
通常の呼出しでは別の演算へ置き換えないため、使用するライブラリで同期の動作を確認する必要があります。

Julia同士でInt32のSUM Allreduceによる同期を選ぶ場合は、全員が `WaitIO.Extensions.Barrier` を使います。
C・Fortran側を含めてこの方式を採用する場合も、全参加者が同じAllreduceの型・要素数・演算にそろえる必要があります。
通常の `Barrier` と拡張の `Barrier` は異なる通信手順です。

配列の転送には `isbits` の要素型を使えます。非連続配列は自動で詰め直します。
`Array` と一括転送の `copyto!` が使えるデバイス配列は、ホストメモリ経由で転送します。GPU実機では未検証です。

送受信領域が重なる場合は、入力を退避して処理します。`Allreduce!(values, SUM, comm)` は同じ配列に結果を戻します。
`IN_PLACE` を使う場合、scatter/scattervでは受信引数を、それ以外では送信引数を置き換えます。
reduce/gather/gatherv/scatter/scattervではルートだけが `IN_PLACE` を使い、他のランクは通常の引数を渡します。

通常の集計はネイティブの型と演算を使います。`Int8`・`UInt8` の集計はCの `char` の符号に従い、
異なる計算機やJuliaの型と一致するとは限りません。Julia側で自動的に型を変更することはありません。
型・演算がない場合は、両側で対応する型へ明示的に変換するか、Julia同士なら `Extensions` を選んでください。

`WaitIO.Extensions.Allreduce!` などの拡張では複素数、位置付きの値、`Op(f)` による独自演算にも対応します。
全参加者が同じ拡張の通信手順を使う必要があり、変更していないCの集合通信関数とは混在できません。
対応範囲と整数型の扱いは[日本語README](README.md)を参照してください。

```julia
result = zeros(1)
WaitIO.Allreduce!([Float64(rank)], result, WaitIO.SUM, comm)

counts = [1, 2]
local_values = rank == 0 ? [10.0] : [20.0, 30.0]
all_values = zeros(3)
WaitIO.Allgatherv!(local_values, WaitIO.VBuffer(all_values, counts), comm)
```

`UBuffer(data, count)` は各ランクに同じ要素数を割り当てます。
`VBuffer(data, counts; displacements=...)` はランク別の要素数と開始位置を指定します。
displacement は 0 始まりの要素位置です。省略すると、ランク順に詰めて配置します。

`Reduce!`、`Gather!`、`Gatherv!` の非ルート受信バッファには `nothing` を指定できます。
`Scatter!`、`Scatterv!` の非ルート送信バッファも同様です。
WaitIO が非ルートで使う作業領域や count 配列は、WaitIO.jl が内部で補います。

## 9. グループと PB の情報を扱う

PB は、WaitIO が接続するプロセス群の単位です。
`PB_rank()` は自分の PB ID、`PB_size()` は PB 数を返します。
`PB_nprocs()` は PB ごとのプロセス数を返します。
グループ内のランク番号とは区別してください。

```julia
world = WaitIO.Comm_world()
heads = WaitIO.Comm_pbheads(; gid=1)
selected = WaitIO.Create_group(2; selection=[:none, :all])
WaitIO.Barrier(world)
```

`Comm_pbheads` は各 PB の先頭プロセスを選びます。
`Create_group` の `selection` には PB ごとに `:all`、`:head`、`:none` を指定します。
上の `selected` の例は 2 PB の環境で、PB 0 を除き PB 1 の全プロセスを選びます。
グループから除外するプロセスも含め、全プロセスで同じ ID と選択内容を指定して作成します。
必要なグループをすべて作成した後、`Barrier(world)` で全体を同期してから使ってください。
WaitIO の進行処理は別グループ宛ての通信も受け取るため、相手が未作成のグループで先に通信を始めると停止する場合があります。

`Ismember(comm)` で所属を調べます。
所属するプロセスだけがランク・サイズを取得し、そのグループで通信します。
`Hostinfo` と `PB_hostinfo` は通信先のアドレスとポートを C API の整数形式で返します。

`order=[1, 0]` のようにPBの順序を指定できます。通常の `Create_group` はこの順序をそのままネイティブ関数へ渡します。
`Comm_rank` と低水準APIは同じランク番号を使います。ライブラリ側のランク番号の問題をJuliaだけの変換で隠すことはありません。

`Extensions.Create_group` は、元のPB順のネイティブグループに論理ランクを割り当てる別の機能です。
この場合だけ、全参加者で論理ランクと通信手順をそろえ、`Extensions` の集合通信を使ってください。

## 10. 初期化、スレッド、エラー、終了

`Init(mpi=:auto)` は、MPI が未初期化なら `MPI_Init_thread` を呼びます。
終了時に `MPI_Finalize` を呼ぶのは、WaitIO.jl 自身が MPI を開始した場合だけです。
`Init(mpi=:external)` は、すでに初期化された MPI を使用し、MPI を終了しません。
MPI.jl と併用する場合も、両方で同じ MPI 共有ライブラリを使う必要があります。

初期化時はMPIにSERIALIZED対応を要求します。SERIALIZED以上が提供されれば、複数のJuliaスレッドから呼べます。
WaitIO.jlがネイティブ呼出しを順番に処理し、完了待ちの間も別スレッドが送受信を開始できるようにします。
FUNNELEDのみが提供された場合は、初期化したOSスレッドから呼ぶ必要があります。
他のパッケージが同じMPIを使う場合は、その呼出しとも重ならないよう調整してください。
集合通信の順序は全ランクでそろえ、初期化と終了は同じOSスレッドで行います。

C 関数の失敗戻り値は `WaitIOError` に変換します。
Test の未完了値は失敗と区別し、今回の実ライブラリでは 1 として扱います。
この値は設定の `test_pending` で指定します。

通信開始や完了確認でエラーになった場合、C 側がまだ領域を参照しているか判断できません。
そのため要求とバッファを保持し、強制解放しません。
この状態では新しいプロセスで再起動する必要があります。

通常は要求をすべて完了させてから `Finalize()` を呼びます。
未完了要求が残っていると `PendingRequestsError` になります。
GC の finalizer や atexit から通信する処理、再初期化、`_exit(0)` は組み込んでいません。

`Register!` / `Unregister!` ではホストメモリの登録を管理できます。
通信中の登録解除は拒否します。
ただし、今回の実機試験で RDMA 登録の動作までは確認していません。

## 11. 対応していない機能と検証範囲

MPI.jl にある機能を、すべて実装しているわけではありません。
現在はワイルドカード受信、Probe、Cancel、永続要求、非同期集合通信、RMA、MPI-IO を提供していません。
MPI の Status に相当する受信状態オブジェクトもありません。
source、tag、配列の長さは利用側で取り決めます。

非連続配列は自動変換し、GPU配列にはホスト経由の転送経路を用意しています。GPU間の直接通信は実装していません。
学習済みモデルを転送する場合は、必要な重み配列をホストへ移すか、
共有ファイルに保存して、そのパスやバージョン番号を通知する構成が考えられます。
モデル全体を転送すれば、そのまま GPU 上で使えるという保証はありません。

対応するシステムと既知の制約は[README](README.md#動作確認と制約)に記載しています。
80関数の低水準APIがあることと、全関数を実機で確認したことは異なります。
