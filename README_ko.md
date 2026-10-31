# VXpro

[English](README.md) · [日本語](README_ja.md) · [简体中文](README_zh-Hans.md) · [繁體中文](README_zh-Hant.md) · [한국어](README_ko.md)

Apple Vision Pro에서 Mac App Store 게임(Cyberpunk 2077)을 VR로 실행합니다: 머리 방향 시점, 깊이 재투영, 뉴럴 엔진 포비티드 업스케일링. 무료, MIT 라이선스.

## 소개

VXpro는 **Mac App Store 버전 Cyberpunk 2077**을 **Vision Pro 단독**으로 실행합니다. 게임의 Mac 빌드는 visionOS와 같은 arm64 Metal 코드이므로 네이티브로 실행됩니다: 에뮬레이션, 변환, 스트리밍, PC가 필요 없습니다. 호스트 앱(VX Mac Host)이 게임 코드를 불러오고, 게임이 사용하는 macOS 전용 라이브러리를 작은 호환 계층으로 바꾸고, 몰입형 공간에 화면을 표시합니다.

**상태: Preview 0.2** (실험적, 2026-11-01).

## 필요한 것

> **게임 버전:** Cyberpunk 2077 **2.5.0**(Mac App Store 최신 업데이트. App Store에는 버전 **1.0.4**로 표시되지만 이는 App Store 자체 번호이며, 안의 게임은 2.5.0입니다)과 **2.3.2**를 지원하며, 둘 다 헤드셋에서 테스트했습니다. 영어 음성이 포함됩니다. 다른 언어의 음성에는 해당 음성 아카이브가 필요하며, 2.5.0에서는 아직 지원하지 않습니다(2.5.0의 다른 언어 음성은 Apple이 호스팅하는 다운로드입니다). 자막과 메뉴는 모든 언어에서 작동합니다.

- 개발자 모드가 켜져 있고 Mac과 페어링된 **Apple Vision Pro**, 약 **160 GB의 여유 공간**;
- **Apple 실리콘 Mac**, visionOS SDK가 포함된 **Xcode 26**, `xcodegen`, Python 3;
- **본인의 유료 Apple Developer Program 계정** (본인 팀으로 서명);
- **Mac App Store에서 직접 구매한 Cyberpunk 2077 (버전 2.5.0 또는 2.3.2)**, Mac에 설치되어 있어야 합니다.

## 설치 요약

```sh
tools/vxmac_cyberpunk.py doctor  --game "/Applications/Cyberpunk2077.app"
tools/vxmac_cyberpunk.py prepare --game "/Applications/Cyberpunk2077.app" --team <YOUR_TEAM_ID>
tools/vxmac_cyberpunk.py build && tools/vxmac_cyberpunk.py install
tools/vxmac_cyberpunk.py copy && tools/vxmac_cyberpunk.py launch
```

전체 가이드(영어/일본어): [docs/VISION_PRO_CYBERPUNK_MAC.md](docs/VISION_PRO_CYBERPUNK_MAC.md). **헤드셋에서 VX Mac Host를 삭제하지 마세요** (약 158 GB의 게임 데이터와 저장 파일이 삭제됩니다). 자주 저장하세요.

## 헤드셋에서의 조작

| 제스처 | 동작 |
| --- | --- |
| **양손을 동시에 1초 집었다가 놓기** | **VR**(머리 방향 시점)과 **화면**(방에 고정된 패널) 사이를 전환합니다. 자동 전환이 잘못되었을 때 사용하세요. |
| **양손으로 3초 집기 → 양손으로 다시 집기** | 게임을 안전하게 종료합니다 (게임 자체의 종료 처리, Mac의 Cmd+Q와 같음). 앱도 닫힙니다. |
| **한 손으로 1초 집기** (VR 중) | 보정 모드를 차례로 전환합니다 (번호와 이름이 표시됨). |

| 모드 | 이름 | 동작 | 왜곡 | 입체감 | 사용 시점 |
| --- | --- | --- | --- | --- | --- |
| **6** (기본) | 회전 + 고정 입체 | 화면 전체를 머리에 맞춰 회전; 각 눈의 차이를 고정된 반 IPD로 깊이에서 생성 | 없음 | 있음 | 일반 플레이 |
| 2 | 회전만 | 화면 전체를 회전, 깊이 사용 안 함 | 없음 | 없음 (무한원 평면) | 입체감보다 안정성 |
| 5 | 보정 없음 | 게임이 렌더링한 그대로의 화면 (컨트롤러로 방향을 바꿀 때와 같음) | 없음 | 없음 | 비교용; 고개를 돌리면 약 0.1초 지연 |
| 0 | 깊이 + 머리 위치 | 깊이로 픽셀 단위 재투영, 머리 이동 포함 | 눈에 띔 (고무처럼) | 있음 | 이론상 가장 정확 |
| 1 | 깊이, 회전만 | 모드 0에서 머리 이동 제외 | 약간 | 있음 | |
| 3 | 깊이 + 머리 위치 (3 cm) | 모드 0, 머리 이동을 3 cm로 제한 | 약간 | 있음 | |
| 4 | 화면에서 측정한 카메라 | 화면의 움직임으로 카메라 방향 측정 | 경우에 따라 | 있음 | 실험적 |

탈것을 운전할 때는 게임의 **1인칭 운전 시점**을 사용하세요.

## 알려진 문제 (Preview 0.2)

- 종료는 양손 집기(3초 + 다시) 또는 앱 창의 **Quit game** 버튼으로 하세요. 앱을 직접 닫으면 게임이 일시 정지되고 10초 후 종료를 요청하지만, 백그라운드에서는 종료가 끝나지 않을 수 있습니다.
- 헤드셋이 뜨거워지거나 워프가 프레임을 놓치면 화면이 약 45 Hz로 고정될 수 있습니다: 헤드셋을 식힌 뒤 계속하세요.
- 권장: 16:9, 1600x900 네이티브 또는 1280x720, FOV 110 (`fov --max 110`과 `settings`, 가이드 참조).
- 게임 데이터의 첫 복사는 용량이 크고 오래 걸립니다 (158 GB).
- 유료 Apple Developer Program 멤버십이 필요합니다 (무료 계정으로는 앱에 필요한 권한을 부여할 수 없습니다).

## 고지

VXpro는 **CD PROJEKT RED 및 Apple과 관계가 없습니다**. Cyberpunk 2077은 CD PROJEKT S.A.의 상표이며, Apple Vision Pro, visionOS, Mac App Store는 Apple Inc.의 상표입니다. VXpro는 게임 파일을 배포하지 않으며 어떤 보호도 우회하지 않습니다.
