# Miyabiでの利用

Miyabi-CとMiyabi-Gで同じJuliaプロジェクトを使い、それぞれのWaitIO・MPIに合わせた設定ファイルを選びます。
通常のAPIは導入済みのWaitIO本体の関数を呼び出します。利用できる関数と型は、その導入版に依存します。

## 設定

各システムで、WaitIOをビルドしたMPIのモジュールを読み込みます。
開発版ではGがnvidia/24.9・nv-hpcx/24.9、Cがintel/2023.2.0・impi/2021.10.0です。
[READMEの手順](README.md#システム名を選んで設定する)でライブラリのパスを設定し、両側で `WAITIO_COMM_TYPE=socket` を設定します。

共有プロジェクトのディレクトリから `julia --project=.` を起動し、G側で次を実行します。

```julia
using WaitIO
WaitIO.use_system_library("miyabi-dev-g"; config_file="config/miyabi-g.toml")
```

C側では次を実行します。

```julia
using WaitIO
WaitIO.use_system_library("miyabi-dev-c"; config_file="config/miyabi-c.toml")
```

エイリアスは試験時のライブラリのパスを保持しています。導入先が変わった場合は、`library_dir` と `include_dir` を明示してください。
WaitIO本体を更新した場合は、ヘッダーも対応するものを使って設定を作り直します。要求構造体の配置が変わった場合はABIプロファイルも確認が必要です。

ジョブでは `WAITIO_JL_CONFIG` に各側の設定ファイルの絶対パスを指定します。
書き込み先のdepotもG・Cで分け、実行中は設定やManifestを書き換えません。
詳しい例は[設定と共有プロジェクト](CONFIGURATION.md)にあります。

## 通信相手とそろえる条件

C・Fortranとの配列通信では送受信する値の型、バイト数、相手のランク、タグをそろえてください。
集合通信では対応するネイティブ関数、型、要素数、ルート、演算、呼出し順を両側でそろえます。

Julia独自型を小文字の `send`・`recv` などで転送する場合は、両側でJuliaのバージョン、型定義、依存パッケージをそろえてください。
この形式の相手はJuliaです。C・Fortranとの通信には双方で配置を決めた配列を使います。

## 対応するライブラリと制約

開発版の設定には `miyabi-dev-g`／`miyabi-dev-c` を使います。
必要なモジュールと環境変数は[日本語README](README.md#システム名を選んで設定する)にあります。
この開発版ではInt64の集計・送受信とGather・Scatterを確認していますが、CHAR型のMAX集計と大文字の `WAITIO_MPI_Allgatherv` には対応していません。
従来の `miyabi-g`／`miyabi-c` は従来のライブラリを選びます。そこにはLONG型のサイズ不一致と関数の欠落が残っています。

導入先のライブラリを確認するには[C/Julia比較試験](../test/native/reference/README.md)を利用してください。
