#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sc4-all-tests.XXXXXX")"
task_cache="${TMPDIR:-/tmp}/sc4-protocol-test-cache"
zsh "$task_root/test-storage.sh"
zsh "$task_root/test-history.sh"
swiftc -module-cache-path "$task_cache" "$task_root/Sources/SharedModels.swift" "$task_root/Sources/Presentation.swift" \
  "$task_root/Sources/SC4Protocol.swift" "$task_root/Tests/ProtocolTests.swift" \
  -o "$task_test_dir/protocol-tests"
"$task_test_dir/protocol-tests"
swiftc -module-cache-path "$task_cache" "$task_root/Sources/SharedModels.swift" "$task_root/Sources/Presentation.swift" \
  "$task_root/Sources/SC4Protocol.swift" "$task_root/Sources/CommandPolicy.swift" \
  "$task_root/Tests/CommandPolicyTests.swift" -o "$task_test_dir/command-policy-tests"
"$task_test_dir/command-policy-tests"
swiftc -module-cache-path "$task_cache" "$task_root/Sources/SharedModels.swift" "$task_root/Sources/Presentation.swift" \
  "$task_root/Sources/SC4Protocol.swift" "$task_root/Sources/ShotStore.swift" \
  "$task_root/Tests/CapturedShotTests.swift" -o "$task_test_dir/captured-shot-tests"
"$task_test_dir/captured-shot-tests"
swiftc -module-cache-path "$task_cache" "$task_root/Sources/SharedModels.swift" "$task_root/Sources/Presentation.swift" \
  "$task_root/Sources/SC4Protocol.swift" "$task_root/Sources/SC4History.swift" \
  "$task_root/Sources/FlightReplay.swift" "$task_root/Tests/FlightReplayTests.swift" \
  -o "$task_test_dir/flight-replay-tests"
"$task_test_dir/flight-replay-tests"
swiftc -module-cache-path "$task_cache" "$task_root/Sources/SharedModels.swift" \
  "$task_root/Sources/Presentation.swift" "$task_root/Sources/ShotStore.swift" \
  "$task_root/Tests/PresentationTests.swift" -o "$task_test_dir/presentation-tests"
"$task_test_dir/presentation-tests" "$@"
swiftc -module-cache-path "$task_cache" "$task_root/Sources/SharedModels.swift" \
  "$task_root/Sources/SC4Protocol.swift" "$task_root/Sources/SC4History.swift" \
  "$task_root/Sources/FlightReplay.swift" "$task_root/Sources/FlightCamera.swift" \
  "$task_root/Tests/FlightCameraTests.swift" -o "$task_test_dir/flight-camera-tests"
"$task_test_dir/flight-camera-tests"
