#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_test_binary="${TMPDIR:-/tmp}/sc4-shot-store-tests"
task_cache="${TMPDIR:-/tmp}/sc4-shot-collector-swift-cache"
mkdir -p "$task_cache"
swiftc -swift-version 5 -module-cache-path "$task_cache" \
  "$task_root/Sources/SharedModels.swift" "$task_root/Sources/Presentation.swift" "$task_root/Sources/ShotStore.swift" \
  "$task_root/Tests/ShotStoreTests.swift" -o "$task_test_binary"
"$task_test_binary"
