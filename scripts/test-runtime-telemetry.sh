#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
telemetry_test_dir=$(mktemp -d)
trap 'rm -rf "$telemetry_test_dir"' EXIT
swiftc -parse-as-library \
  RailRouter/Models/{AppSettings,ModelName,LLMModel,ModelInstance}.swift \
  RailRouter/Utilities/Shell.swift \
  RailRouter/Services/{LMStudioService,OllamaService,RuntimeTelemetry}.swift \
  RailRouter/Tests/{XCTCompat,RuntimeTelemetryTests}.swift \
  scripts/runtime-telemetry-tests.swift -o "$telemetry_test_dir/checks"
"$telemetry_test_dir/checks" "$@"
