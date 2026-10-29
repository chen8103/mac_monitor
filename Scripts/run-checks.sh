#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build/checks

swiftc \
    Sources/MacMonitor/Models.swift \
    Sources/MacMonitor/MetricCalculations.swift \
    Sources/MacMonitor/SystemMetricsSampler.swift \
    Sources/MacMonitor/ActivityMetricsSampler.swift \
    Sources/MacMonitor/MetricsSamplingActor.swift \
    Sources/MacMonitor/MetricsStore.swift \
    Tests/Checks/main.swift \
    -framework IOKit \
    -o .build/checks/MacMonitorChecks

.build/checks/MacMonitorChecks
