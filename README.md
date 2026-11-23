# SC4 Shot Collector

Native macOS app that receives live Bluetooth shots from **SC4 2188**, saves records locally, and replays ball flight. The repository name is `mysc_sc300`; the implemented and tested device is **SC4**, not SC300.

**Version 1.2.0 · Apple Silicon · macOS 13 or later**

[Download the Mac app ZIP](https://github.com/slee1005/mysc_sc300/releases/download/v1.2.0/SC4ShotCollector-1.2.0-macOS-arm64.zip) · [한국어 사용법](README.ko.txt) · [English instructions](README.en.txt)

## Features

- Live BLE reception with an append-only shot journal and original packet storage.
- Carry, total distance, ball speed, club speed, launch angle, **launch direction, apex and smash factor**, plus spin.
- Smash factor is calculated as ball speed / club speed; exports identify the calculation source.
- Korean and English language selection, with editable `.strings` language files.
- Meter/yard switching for distance, apex, replay height/grid marks and CSV/JSON exports.
- Animated replay with 3D, side and top views, timeline scrubbing and playback speed controls.
- Drag the ground in 3D to rotate and tilt the camera; Reset View restores the starting angle.
- Optional automatic replay of newly received shots.

## Run and build

Unzip the download and open `SC4 Shot Collector.app`. This build is ad-hoc signed and is not notarized. Select Korean/English and m/yd at the top right.

To build from source, install Apple's Xcode command-line tools, then run:

```sh
zsh build.sh
```

The app is created at `dist/SC4 Shot Collector.app`. No third-party dependencies or API keys are required.

```sh
zsh test-all.sh
```

Tests cover storage preservation, framing/reassembly, command restrictions, calculated metrics, localization, unit conversion, exports and replay. All committed shot fixtures are **synthetic**, with fabricated IDs, timestamps and measurements. Private shot journals, original user captures, vendor APKs and reverse-engineering dumps are excluded.

## Device and record handling

The connection currently targets the original user's SC4 device name and Bluetooth identity. To use a different SC4, update the device identifiers in `Sources/CollectorModel.swift` and rebuild. Other launch-monitor models have not been validated.

Records are stored at:

```text
~/Library/Application Support/SC4 Shot Collector/
  shots.jsonl
  shot-transport.jsonl
```

Language and unit choices change display/export copies; they do not rewrite original shot records. Exports refuse to overwrite existing files.

Only device-information requests (`0x64`) and live-fragment acknowledgements (`0x73`) can be sent. History queries (`0x72`), delete (`0x44`), synchronization/settings and firmware commands are blocked.

An earlier history retrieval reduced the reported device queue count. History downloading was removed because a query may consume that queue. Physical flash erasure and the effect of live acknowledgements on device-side retention have not been established. The app preserves received records on the Mac.

## Simulation limits

Flight is reconstructed from recorded carry, apex and valid launch angle. Timing is estimated; wind, drag and spin curvature are not modeled. Roll timing is illustrative. Missing values are identified as estimates and are never written into the original shot.

## Language files

- [Korean](Resources/ko.lproj/Localizable.strings)
- [English](Resources/en.lproj/Localizable.strings)

Bluetooth permission descriptions are localized in the matching `InfoPlist.strings` files. Keep numbered placeholders such as `{0}` intact when editing translations.

## 한국어

SC4의 실시간 샷을 Mac에 누적 저장하고 공의 비행을 재생하는 앱입니다. 출발 방향·최고 높이·스매시 팩터, 한국어·영어 전환, m·yd 전환을 지원합니다. 스매시 팩터는 볼 속도 ÷ 클럽 속도로 계산합니다.

개인 샷 기록은 저장소에 포함하지 않았습니다. 저장된 원본 기록은 유지하며, 기기의 과거 기록을 소모할 수 있는 조회 명령은 차단했습니다. 자세한 사용법은 [한국어 안내](README.ko.txt)를 참고하세요.
