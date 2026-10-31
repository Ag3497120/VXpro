# VXpro

Apple Vision Pro で Mac App Store のゲーム（Cyberpunk 2077）を VR で動かします。頭の向きで視点操作、深度による再投影、
Neural Engine による中心窩アップスケーリング。無料、MIT ライセンス。

[English](README.md) · [日本語](README_ja.md) · [简体中文](README_zh-Hans.md) · [繁體中文](README_zh-Hant.md) · [한국어](README_ko.md)

VXpro は **Mac App Store 版 Cyberpunk 2077** を **Vision Pro 単体で** 動かします。Mac 版のゲームは visionOS と同じ
arm64 の Metal コードなので、ネイティブに動きます（エミュレーション、変換、ストリーミング、PC はいずれも不要）。ホスト
アプリ（VX Mac Host）がゲームのコードを読み込み、ゲームが使う macOS 専用ライブラリを小さなシムで置き換え、映像を
イマーシブ空間に表示します。3D のゲームプレイ中は頭の向きでゲームのカメラが回り、各目の映像はゲームの深度から 90 Hz で
再投影されます。メニュー、ムービー、ロード画面は部屋に固定されたパネルに出ます。

**状態：Preview 0.2**（実験的、2026-11-01）。M2 の Vision Pro で、設定を下げた状態で、メインメニュー、キャラクター作成、
ゲーム冒頭が動いています。ゲームは約 20〜30 fps、表示は 90 Hz の再投影です。

VXpro は [VeRantyx](https://github.com/Ag3497120/VeRantyx) の Mac App Store ルートです（Windows / Steam ルートの
VXRuntime は VeRantyx 側にあります）。

## 必要なもの

> **ゲームの版について：** Cyberpunk 2077 **2.5.0**（Mac App Store の最新の更新）と **2.3.2** に対応しています（どちらもヘッドセットで確認済み）。英語音声は含まれます。ほかの言語の音声にはその音声アーカイブが必要で、2.5.0 ではまだ対応していません（2.5.0 のほかの言語の音声は Apple がホストするダウンロードです）。字幕とメニューは全言語で動きます。

- **Apple Vision Pro**（デベロッパモード、Mac とペアリング済み、空き容量 **約 160 GB**）
- **Apple シリコンの Mac**、**Xcode 26**（visionOS SDK）、`xcodegen`、Python 3
- **自分の有料 Apple Developer Program アカウント**（アプリには Increased Memory Limit と Extended Virtual
  Addressing のエンタイトルメントが必要で、自分のチームで署名します）
- **自分で購入した Mac App Store 版 Cyberpunk 2077 バージョン 2.5.0 または 2.3.2**（Mac にインストール済み）

## はじめかた

```sh
tools/vxmac_cyberpunk.py doctor  --game "/Applications/Cyberpunk2077.app"
tools/vxmac_cyberpunk.py prepare --game "/Applications/Cyberpunk2077.app" --team <自分のTEAM_ID>
tools/vxmac_cyberpunk.py build && tools/vxmac_cyberpunk.py install
tools/vxmac_cyberpunk.py copy && tools/vxmac_cyberpunk.py launch
```

各ステップの内容、操作、オプション、トラブルシューティングは完全版のガイドへ：
[docs/VISION_PRO_CYBERPUNK_MAC_ja.md](docs/VISION_PRO_CYBERPUNK_MAC_ja.md)。仕組みと経緯（英語）：
[docs/DESIGN.md](docs/DESIGN.md)。

ヘッドセットでは、自動の切り替えが間違っているときに **両手で同時に 1 秒ピンチして離す** と VR と世界に固定した
スクリーンが切り替わります。**終了するには両手のピンチを 3 秒続け、「終了しますか？もう一度両手でピンチ」と出たら
もう一度両手でピンチ** します。ゲーム自身の終了処理（Mac の Cmd+Q と同じ）で終わり、アプリも閉じます。VR 中に **片手で 1 秒ピンチ** すると warp モードが切り替わります。詳しくはガイドの
「ヘッドセットでの操作」を参照してください。

> **VX Mac Host をヘッドセットから削除しないでください**：約 158 GB のゲームデータの複製とセーブが消えます。
> **こまめにセーブしてください**：ゲームは visionOS のメモリ上限近くで動いています。

## VXpro がしないこと

- **ゲームのファイルも、ゲームから作ったものも配布しません。** 自分のコピーを自分の Mac で準備し、自分のチームで署名し、
  自分のヘッドセットにだけ複製します。ビルドしたアプリにはゲームのコードが入っているので共有しないでください。
- **DRM、StoreKit、所有確認を回避しません。** App Store のバンドルに書き込まず、レシート、StoreKit、Game Center、
  iCloud、GOG のアカウントにも触れません。自分で購入したコピーを、自分のためにだけ使ってください。
- **CD PROJEKT RED とも Apple とも無関係です。** Cyberpunk 2077 は CD PROJEKT S.A. の商標です。Apple Vision Pro、
  visionOS、Mac App Store は Apple Inc. の商標です。

## 既知の問題（Preview 0.2）

- 終了は両手ピンチ（3 秒＋もう一度）か、アプリのウインドウの **Quit game** ボタンで。アプリを直接閉じるとゲームは
  一時停止し、10 秒後に終了を求めますが、バックグラウンドでは終了しきれないことがあります。セーブ中に強制終了はしないでください。
- ヘッドセットが熱くなったり、ワープがフレームに間に合わないと、表示が約 45 Hz に固定されることがあります：ヘッドセットを
  冷ましてください。
- 2.5.0 のほかの言語の音声はまだ対応していません（英語音声は動きます。字幕とメニューは全言語）。
- 推奨：16:9、1600x900 ネイティブまたは 1280x720、FOV 110（`fov --max 110` と `settings`。ガイド参照）。
- ゲームデータの最初の複製は大きく時間がかかる（158 GB）。
- 有料の Apple Developer Program が必要（無料のアカウントではアプリに必要な権限を付与できない）。

## 既知の制限

- **フレームレート**：ゲームは約 20〜30 fps。頭の動きは 90 Hz の再投影で滑らかですが、速い振り向きや動く物体では低い
  フレームレートが見えます。
- **HUD**：四隅（ミニマップ、クエスト、体力）がフレームの端にあり VR では見えにくいです。`VXMAC_HUD=1` またはゲームの
  HUD セーフゾーンで改善します。
- **下の縁**：ゲームのフレームは目の視野より狭く、残り（主に下側）はシーンの少し古いパノラマを暗くしたもの
  （`VXMAC_VR_CACHE`）で埋めています。ライブの映像ではありません。
- **メモリ**：アプリが使える約 8.2 GB のうち約 6.5 GB。設定を上げるとアプリが終了することがあります。
- **確認済みのビルド** 2.5.0 と 2.3.2（ハッシュで確認）。オフラインのみ（Game Center、iCloud セーブ、GOG なし）。Mod、
  レイトレーシング、HDR は不可。プロファイルの期限が切れたら開発用署名をやり直します。
- Neural Engine の機能は組み込み済みですが **既定ではオフ** です：`VXMAC_FSR=1`（中心窩の超解像）、
  `VXMAC_FOVEATE=1`（コンポジタのフォビエーション）。ほか：`VXMAC_VEL`、`VXMAC_NPU`、`VXMAC_VR_CACHE`、
  `VXMAC_VR_VIGNETTE`、`VXMAC_VR_ZOOM`、`VXMAC_STICK_PITCH`（ガイドの「オプション」参照）。

## 安全について

VX Mac Host はサンドボックスではありません。ゲームのコードはアプリの権限でネイティブに動きます。自分が所有し信頼する
ソフトウェアだけを動かしてください。VR は体調に影響することがあるので、休憩を取ってください。

## ライセンス

MIT（[LICENSE](LICENSE)）。第三者の表記：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
一人の開発者が AI コーディングエージェントと作っています。コミュニティ：[VeRantyx](https://github.com/Ag3497120/VeRantyx)。
