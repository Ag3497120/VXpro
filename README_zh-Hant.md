# VXpro

[English](README.md) · [日本語](README_ja.md) · [简体中文](README_zh-Hans.md) · [繁體中文](README_zh-Hant.md) · [한국어](README_ko.md)

在 Apple Vision Pro 上以 VR 執行 Mac App Store 版遊戲（Cyberpunk 2077）：頭部轉向、深度重投影、神經網路引擎注視點超解析度。免費，MIT 授權。

## 這是什麼

VXpro 讓 **Mac App Store 版 Cyberpunk 2077** 在 **Vision Pro 單機** 上執行。遊戲的 Mac 版是 arm64 Metal 程式碼，與 visionOS 相同，因此可以原生執行：沒有模擬、沒有轉譯、沒有串流、不需要 PC。主機應用程式（VX Mac Host）載入遊戲程式碼，把它用到的 macOS 專用函式庫替換為小型相容層，並在沉浸空間中顯示畫面。

**狀態：Preview 0.2**（實驗性，2026-11-01）。

## 需要

> **遊戲版本：** 支援 Cyberpunk 2077 **2.5.0**（Mac App Store 最新更新；App Store 顯示的版本號為 **1.0.4**，這是 App Store 自己的編號，其中的遊戲為 2.5.0）和 **2.3.2**，均已在頭戴裝置上測試。包含英語語音；其他語言的語音需要對應的語音封存檔，2.5.0 尚未支援（其其他語言語音為 Apple 託管的下載內容）。字幕和選單支援所有語言。

- 已開啟開發者模式並與 Mac 配對的 **Apple Vision Pro**，約 **160 GB 可用空間**；
- **Apple 晶片的 Mac**、含 visionOS SDK 的 **Xcode 26**、`xcodegen`、Python 3；
- 你**自己的付費 Apple Developer Program 帳號**（用你自己的團隊簽署）；
- 你**自己從 Mac App Store 購買的 Cyberpunk 2077（版本 2.5.0 或 2.3.2）**，已安裝在 Mac 上。

## 安裝概要

```sh
tools/vxmac_cyberpunk.py doctor  --game "/Applications/Cyberpunk2077.app"
tools/vxmac_cyberpunk.py prepare --game "/Applications/Cyberpunk2077.app" --team <YOUR_TEAM_ID>
tools/vxmac_cyberpunk.py build && tools/vxmac_cyberpunk.py install
tools/vxmac_cyberpunk.py copy && tools/vxmac_cyberpunk.py launch
```

完整指南（英文／日文）：[docs/VISION_PRO_CYBERPUNK_MAC.md](docs/VISION_PRO_CYBERPUNK_MAC.md)。**請勿從頭戴裝置刪除 VX Mac Host**（會刪除約 158 GB 的遊戲資料與存檔）。請經常存檔。

## 頭戴裝置中的操作

| 手勢 | 作用 |
| --- | --- |
| **雙手同時捏合 1 秒後放開** | 在 **VR**（頭部轉向）與 **螢幕**（固定在房間中的面板）之間切換。自動切換不正確時使用。 |
| **雙手捏合 3 秒 → 再次雙手捏合** | 安全結束遊戲（遊戲自身的結束流程，與 Mac 上的 Cmd+Q 相同），應用程式隨之關閉。 |
| **單手捏合 1 秒**（VR 中） | 依序切換補償模式（顯示編號與名稱）。 |

| 模式 | 名稱 | 作用 | 變形 | 立體感 | 適用 |
| --- | --- | --- | --- | --- | --- |
| **6**（預設） | 旋轉＋固定立體 | 整個畫面隨頭部旋轉；每隻眼的偏移以固定的半瞳距由深度產生 | 無 | 有 | 一般遊玩 |
| 2 | 僅旋轉 | 整個畫面旋轉，不使用深度 | 無 | 無（無限遠平面） | 更重視穩定 |
| 5 | 無補償 | 遊戲算繪的原始畫面（與用手把轉向相同） | 無 | 無 | 比較用；轉頭時約 0.1 秒延遲 |
| 0 | 深度＋頭部位置 | 用深度逐像素重投影，包含頭部移動 | 明顯（像橡膠） | 有 | 理論上最精確 |
| 1 | 深度，僅旋轉 | 模式 0 去掉頭部移動 | 少許 | 有 | |
| 3 | 深度＋頭部位置（3 公分） | 模式 0，頭部移動限制在 3 公分 | 少許 | 有 | |
| 4 | 由畫面測得的相機 | 由畫面運動測量相機朝向 | 視情況 | 有 | 實驗性 |

駕駛載具時請使用遊戲的**第一人稱駕駛視角**。

## 已知問題（Preview 0.2）

- 請用雙手捏合（3 秒＋再次）或應用程式視窗的 **Quit game** 按鈕結束。若直接關閉應用程式，遊戲會暫停，並在 10 秒後被要求結束，但在背景可能無法完成結束。
- 頭戴裝置變熱或畫面變形（warp）趕不上影格時，顯示可能鎖定在約 45 Hz：請讓頭戴裝置冷卻後再繼續。
- 建議：16:9，1600x900 原生或 1280x720，FOV 110（`fov --max 110` 和 `settings`，見指南）。
- 首次複製遊戲資料量大且耗時（158 GB）。
- 雖然不提交到 App Store，但仍需要付費的 Apple Developer Program 會員資格。原因是兩項權限（entitlement）：沒有 **Increased Memory Limit**，visionOS 會把應用程式限制在約 5 GB，需要 6–8 GB 的遊戲會在載入時被終止；**Extended Virtual Addressing** 是因為遊戲一開始就會預留非常大的虛擬位址範圍。據我們所知，免費（Personal Team）帳號無法簽署這兩項權限（我們自己未驗證，歡迎回報）。免費簽署每 7 天也會過期。

## 聲明

VXpro **與 CD PROJEKT RED 及 Apple 無關**。Cyberpunk 2077 是 CD PROJEKT S.A. 的商標；Apple Vision Pro、visionOS 與 Mac App Store 是 Apple Inc. 的商標。VXpro 不散布遊戲的任何檔案，也不繞過任何保護。
