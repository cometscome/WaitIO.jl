# WaitIOのチュートリアル・講演・論文

[英語README](../README.md) | [日本語README](README.md) | [英語の文献案内](../docs/WAITIO_RESOURCES.md)

2026年10月30日に確認した、h3-Open-SYS/WaitIO本体の公開資料です。
WaitIO.jlの使い方と既知の制約は[英語README](../README.md)にあります。

## 最初に読む資料

**実装を始めるなら、2024年のWaitIO/MP講習会資料が参考になります。**
ファイルを介した連成からWaitIOによる通信へ進み、サンプルコードとジョブスクリプトを使って学べます。
英語で全体像をつかむ場合は、2023年のASE講演資料から読むと、複数のMPIプログラムを結ぶ仕組みを確認できます。
Miyabiで使う場合は、2026年の講習会資料も参照してください。

## 講習会とチュートリアル

| 資料 | 内容と使いどころ |
| --- | --- |
| [東京大学・第236回WaitIO/MP講習会](https://www.cc.u-tokyo.ac.jp/events/lectures/236/)（2024年10月30日、日本語） | 住元真司氏・荒川隆氏による講習会です。[129ページの資料](https://www.cc.u-tokyo.ac.jp/events/lectures/236/20241030-2.pdf)では、WaitIOの通信、MPIに近いインタフェース、Wisteriaでのジョブ起動、UTIL/MPによる連成を扱います。プログラムに組み込む際の参考になります。 |
| [東京大学・第191回WaitIO/MP講習会](https://www.cc.u-tokyo.ac.jp/events/lectures/191/index.php)（2022年10月14日、日本語） | OdysseyとAquariusの連成を学ぶ入門講習です。ファイル交換からWaitIOへの書き換えと、Fortran/C・Pythonの連携を扱います。開催ページには講義・演習の録画リンクもあります。今回は開催案内を確認し、録画の内容までは確認していません。 |
| [東京大学・第277回CUDA-Q＋Miyabi講習会](https://www.cc.u-tokyo.ac.jp/events/lectures/277/)（2026年7月21日、日本語） | 住元真司氏のWaitIO紹介を含む講習会です。[82ページの資料](https://www.cc.u-tokyo.ac.jp/events/lectures/277/20260721-5.pdf)で、並列ブロック、送受信、WaitIO-MPI変換ライブラリを確認できます。開催ページには量子・HPC連携の資料と録画リンクもあります。録画は未確認です。 |
| [NCTS冬季学校・異種スパコン上のシミュレーション・データ・機械学習融合](https://ncts.ntu.edu.tw/events_3_detail.php?nid=358)（2025年2月17〜18日、英語） | 中島研吾氏・荒川隆氏・住元真司氏・八代尚氏による講習の概要と時間割です。WaitIOとUtilMPを使ったWisteriaでの演習が組まれています。今回は公開された講習概要を確認しました。 |

過去の講習会資料にあるキュー名、プロジェクト番号、パス、モジュール名は当時の設定です。
そのまま転記せず、利用するシステムの設定に合わせてください。

## 講演・論文と研究紹介

**2023年11月29日、第45回ASE研究会のWaitIO講演**では、住元真司氏が複数のMPIプログラムを結ぶ通信機構を説明しています。
[英語スライド20ページ](https://www.cc.u-tokyo.ac.jp/en/events/ase/45/Sumimoto.pdf)は通信モデルとSocket・File・Hybridの違いを知るための資料です。
[開催ページ](https://www.cc.u-tokyo.ac.jp/en/events/ase/45/45.php)には研究会の録画リンクもあります。今回はスライドを読みました。

**2025年のRDMAに関する論文**は、住元真司氏らによる
[Accelerating Heterogeneous Coupling Computing with WaitIO Using RDMA](https://doi.org/10.1145/3703001.3724382)です。
公開要旨では、WaitIO-VerbsとWaitIO-TofuによるユーザーレベルのRDMA通信、その実装と評価が説明されています。
今回は要旨を確認しました。この論文の成果を、WaitIO.jlでRDMAやGPU直接通信を検証した結果としては扱っていません。

**拠点間通信については、東京大学情報基盤センターの研究紹介**にWaitIOとWaitIO-Routerの説明があります。
WaitIOは異なるMPI実装・プロセッサ・ネットワークを使うプログラム間の通信を担います。
WaitIO-Routerの項目では、計算センター間の量子・HPC連携に向けたルーティング、複数ストリーム、暗号化通信の研究を紹介しています。
詳しくは[英語の研究紹介](https://www.cc.u-tokyo.ac.jp/en/outline/researches.php)を参照してください。

## WaitIO.jlとの関係

WaitIOは異なるシステムで起動したMPIプログラムを並列ブロックとして結びます。
UTIL/MPはその上でアプリケーションの連成を扱う別のライブラリです。
WaitIO.jlはWaitIOをJuliaから使うためのパッケージで、MPI.jlに近い配列・要求APIと、Julia独自型の転送を提供します。

WaitIO.jlのMiyabi試験では、GとCの間で通信を確認しています。
この結果から、別の計算センター間でも検証済みとはいえません。
Julia側の設定と既知の制約は[README](../README.md)を参照してください。
