# VXpro

[English](README.md) · [日本語](README_ja.md) · [简体中文](README_zh-Hans.md) · [繁體中文](README_zh-Hant.md) · [한국어](README_ko.md)

在 Apple Vision Pro 上以 VR 运行 Mac App Store 版游戏（Cyberpunk 2077）：头部转向、深度重投影、神经网络引擎注视点超分辨率。免费，MIT 许可。

## 这是什么

VXpro 让 **Mac App Store 版 Cyberpunk 2077** 在 **Vision Pro 单机** 上运行。游戏的 Mac 版是 arm64 Metal 代码，与 visionOS 相同，因此可以原生运行：没有模拟、没有转译、没有串流、不需要 PC。宿主应用（VX Mac Host）加载游戏代码，把它用到的 macOS 专用库替换为小型兼容层，并在沉浸空间中显示画面。

**状态：Preview 0.1**（实验性，2026-10-31）。

## 需要

> **游戏版本：** 目前只支持 Cyberpunk 2077 **2.3.2**（2025 年的 Mac App Store 版本）。最新的 Mac App Store 更新（App Store 版本 1.0.4，2026 年 10 月 22 日发布）**暂不支持，近期将会支持。** 如果你的游戏已经更新，工具会在 `doctor` / `prepare` 阶段停止，不做任何更改。

- 已开启开发者模式并与 Mac 配对的 **Apple Vision Pro**，约 **160 GB 可用空间**；
- **Apple 芯片的 Mac**、带 visionOS SDK 的 **Xcode 26**、`xcodegen`、Python 3；
- 你**自己的付费 Apple Developer Program 账号**（用你自己的团队签名）；
- 你**自己从 Mac App Store 购买的 Cyberpunk 2077（版本 2.3.2）**，已安装在 Mac 上。

## 安装概要

```sh
tools/vxmac_cyberpunk.py doctor  --game "/Applications/Cyberpunk2077.app"
tools/vxmac_cyberpunk.py prepare --game "/Applications/Cyberpunk2077.app" --team <YOUR_TEAM_ID>
tools/vxmac_cyberpunk.py build && tools/vxmac_cyberpunk.py install
tools/vxmac_cyberpunk.py copy && tools/vxmac_cyberpunk.py launch
```

完整指南（英文/日文）：[docs/VISION_PRO_CYBERPUNK_MAC.md](docs/VISION_PRO_CYBERPUNK_MAC.md)。**请勿从头显中删除 VX Mac Host**（会删除约 158 GB 的游戏数据和存档）。请经常存档。

## 头显中的操作

| 手势 | 作用 |
| --- | --- |
| **双手同时捏合 1 秒后松开** | 在 **VR**（头部转向）和 **屏幕**（固定在房间中的面板）之间切换。自动切换不正确时使用。 |
| **双手捏合 3 秒 → 再次双手捏合** | 安全退出游戏（游戏自身的退出流程，与 Mac 上的 Cmd+Q 相同），应用随之关闭。 |
| **单手捏合 1 秒**（VR 中） | 依次切换补偿模式（显示编号和名称）。 |

| 模式 | 名称 | 作用 | 变形 | 立体感 | 适用 |
| --- | --- | --- | --- | --- | --- |
| **6**（默认） | 旋转＋固定立体 | 整个画面随头部旋转；每只眼的偏移按固定的半瞳距由深度生成 | 无 | 有 | 正常游玩 |
| 2 | 仅旋转 | 整个画面旋转，不使用深度 | 无 | 无（无限远平面） | 更重视稳定 |
| 5 | 无补偿 | 游戏渲染的原始画面（与用手柄转向相同） | 无 | 无 | 对比用；转头时约 0.1 秒延迟 |
| 0 | 深度＋头部位置 | 用深度逐像素重投影，包括头部移动 | 明显（像橡胶） | 有 | 理论上最精确 |
| 1 | 深度，仅旋转 | 模式 0 去掉头部移动 | 少许 | 有 | |
| 3 | 深度＋头部位置（3 厘米） | 模式 0，头部移动限制在 3 厘米 | 少许 | 有 | |
| 4 | 由画面测得的相机 | 由画面运动测量相机朝向 | 视情况 | 有 | 实验性 |

驾驶载具时请使用游戏的**第一人称驾驶视角**。

## 已知问题（Preview 0.1）

- 请用双手捏合（3 秒＋再次）或应用窗口的 **Quit game** 按钮退出。若直接关闭应用，游戏会暂停，并在 10 秒后被要求退出，但在后台可能无法完成退出。
- 1600x900 在 M2 上约 40 Hz：请使用 1280x720、MetalFX 性能、FOV 110（见指南“Recommended settings”）。
- 首次复制游戏数据量大且耗时（158 GB）。
- 免费 Apple 账号的签名 7 天后过期（且无法获得所需权限：需要付费开发者团队）。

## 声明

VXpro **与 CD PROJEKT RED 及 Apple 无关**。Cyberpunk 2077 是 CD PROJEKT S.A. 的商标；Apple Vision Pro、visionOS 和 Mac App Store 是 Apple Inc. 的商标。VXpro 不分发游戏的任何文件，也不绕过任何保护。
