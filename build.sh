#!/bin/zsh
set -euo pipefail

task_root="${0:A:h}"
task_output="$task_root/dist/SC4 Shot Collector.app"
task_cache="${TMPDIR:-/tmp}/sc4-shot-collector-swift-cache"
mkdir -p "$task_output/Contents/MacOS" "$task_output/Contents/Resources" "$task_cache"
swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$task_cache" \
  -framework SwiftUI -framework AppKit -framework CoreBluetooth -framework Security \
  "$task_root"/Sources/*.swift \
  -o "$task_output/Contents/MacOS/SC4ShotCollector"
cp "$task_root/Info.plist" "$task_output/Contents/Info.plist"
cp -R "$task_root/Resources/ko.lproj" "$task_root/Resources/en.lproj" "$task_output/Contents/Resources/"
cp "$task_root/Resources/VirtualRange.jpg" "$task_output/Contents/Resources/"
codesign --force --sign - "$task_output"
codesign --verify --verbose "$task_output"
printf '%s\n' "$task_output"
