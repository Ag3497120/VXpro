# Reprojection Test

ゲームと独立した、Apple Vision Pro の表示補正を比較する MIT 実装。
ゲーム・VXMacHost のシェーダー、画像管理、手・銃、GPU 制限設定は変更しない。

## 使い方

アプリの「自動比較（約1分）」を選ぶ。各段階は15秒で、90 → 45 → 30 → 90 FPS相当の順。
前半は格子を見ながらゆっくり左右を向き、後半は頭を止めて動く球を見る。
段階と操作の案内、画像番号は3D空間にも表示する。1分後に比較を終了し、ウインドウへ戻る。
各速度を単独で1分見るボタンもある。途中で閉じるには Digital Crown でウインドウへ戻れる。

端末が90Hzでない場合、速度も変わる。例えば100Hzなら100・50・約33.3FPS。
固定の90Hzを仮定せず、実際に受け取った表示予定番号と時刻から頻度を計算する。

## 何を測るか

- 静止した格子、1.1mの近い目印、左右に動く1.8mの球を両眼別々に直接3D描画する。
- `minimumFrameRepeatCount` を0・1・2にし、描画結果をAppleに反復表示させる。
- 描画に使った `DeviceAnchor` と reverse-Z の深度を毎回渡す。
- アプリ独自の再投影、前の画像のコピー、光学フロー、中間画像生成は入れない。
- 画像ID、表示予定番号・時刻、追跡状態、頭の姿勢、GPU終了・期限、熱状態を記録する。
- 動く球の位置は新しい描画を提出するときだけ更新する。
- 同じシーン・解像度・描画処理を保つ。格子の線は低解像度でも消えにくい太さにする。

`scheduled_display_hz` は **予定された表示周期**。パネルの実表示完了通知ではない。
画像番号が変わらない間にレンズ越しの映像がどう動くかは、装着中の比較、または同期した
光学測定で確かめる。物体の動きが補間されたか、何FPS「相当」の画質かをログだけで断定しない。
画面収録・高品質キャプチャを開始すると比較条件が変わるため、その有無も記録する。
発熱状態が変化した試行や、中断・追跡欠落のある試行は条件の揃った比較ではない。

## 記録と集計

アプリ内の `Documents/reprojection-latest.jsonl`。前の記録はUUID付きの名前へ退避する。
毎フレームの数値を小さくまとめ、1秒ごとにまとめて書く。描画用の小バッファは3つを再利用する。

```sh
python3 VXMac/tools/reprojection_report.py <回収したログ> --output <集計.json>
```

各段階の最初の1秒を除外し、新しい描画の提出頻度、表示予定周期、GPU期限超過などを集計する。
Appleの最終表示FPSを推測で埋めず、`actual_panel_fps: null` として残す。

## ビルドと検査

XcodeGen / Xcode、visionOS 26 SDK。`project.yml` の署名チームはこの作業環境の設定。

```sh
cd VXMac/tests/reprojection_app
xcodegen generate
xcodebuild -project VXReprojectionTest.xcodeproj -scheme VXReprojectionTest \
  -configuration Release -destination 'generic/platform=visionOS' \
  -derivedDataPath ../../build/reprojection-test-v1/device build
```

Mac側の `reprojection_model_mac.swift` は、実際のMetalシェーダーで左右の視差、深度の前後関係、
球の移動を検査し、プレビューを出力する。集計の検査は `reprojection_report_test.py`。
これらはAppleの最終再投影を測る検査ではない。

Apple資料:

- https://developer.apple.com/documentation/compositorservices/layerrenderer/minimumframerepeatcount
- https://developer.apple.com/documentation/compositorservices/drawing-fully-immersive-content-using-metal
- https://developer.apple.com/videos/play/wwdc2023/10089/

## 2026-11-07 実機比較

M2 Vision Pro / visionOS 27、build 2。1分間の自動比較が完了。
各段階の最初の1秒を除くと、新規描画は90.003、45.0015、30.0010、90.003 FPS。
Appleからの表示予定番号・時刻による周期はいずれも約90.003Hz。
同じ元画像を使う予定周期数は1・2・3・1だった。発熱状態はnominalで変化なし。
全3827件のGPU完了記録でエラー・期限超過0、画面収録用ターゲットなし。
球の動きの違いについて利用者の回答は「違いが分からなかった」。

証拠: `runs/20261107T002800Z-reprojection-device-comparison/result.json` o1–o4 / d1–d3。
これは最終パネル表示を光学測定した値ではなく、物体補間の効果量やゲームの改善倍率は未確定。

最初のbuildでは、デバイスの最小near距離0.1mに対して0.05mを指定し、描画レイヤー作成時に
`Layer configuration not supported` で停止した。build 2は対応フォーマットと最小near距離を参照し、
設定内容を `reprojection-configuration.json` に残す。設定修正後に上記の比較を実施した。
30→90切り替え直後の表示予定時刻に167nsの逆行が1件あったため、集計では予定どおり初回1秒を
除外し、その範囲の異常件数も別途記録する。安定区間の不正な時刻は引き続きエラーにする。
