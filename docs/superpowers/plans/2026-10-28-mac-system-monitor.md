# Mac System Monitor Implementation Plan

> **Current product:** The shipped app is a menu bar popover. [README](../../../README.md) is the contract. This plan describes the original window design and is kept as implementation history.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dependency-free native macOS app that shows real CPU, per-core, memory, load, uptime, and system information in a bright, light-colored desktop panel.

**Architecture:** A Darwin-based sampling actor produces immutable metrics snapshots. A main-actor `MetricsStore` owns the three-second refresh lifecycle, while SwiftUI renders the current snapshot and AppKit configures window pinning and close behavior.

**Tech Stack:** Swift 6.2, Swift Package Manager, SwiftUI, AppKit, Darwin, XCTest, shell.

**Spec:** `docs/superpowers/specs/2026-10-28-mac-system-monitor-design.md`

## Global Constraints

- Refresh every 3 seconds; all displayed metrics must describe this Mac.
- First CPU sample is unavailable (`nil`), not a fake 0%; later percentages are clamped to 0–100%.
- Used memory is active + wired + compressor pages; memory is displayed in GiB (1024³ bytes).
- CPU warning/critical thresholds are 70%/90%; memory warning/critical thresholds are 80%/90%.
- Warm-white background, dark-gray text, blue CPU, teal memory, orange/coral high-load states.
- No third-party dependencies, history, process list, alerts, settings page, menu-bar mode, or login item.
- Minimum UI size is 420 × 360; initial window size is 580 × 420.
- The current directory is not a Git repository; do not initialize Git or create commits as part of this work.

## Review Focus

- CPU counters that regress, change core count, or have zero elapsed ticks must return unavailable rather than negative, stale, or infinite percentages; pinned by Task 1 tests.
- Repeated `start()` calls must not create duplicate refresh loops; pinned by Task 3 tests.
- A transient sampling failure must preserve the last good snapshot and recover on a later pass; pinned by Task 3 tests.
- Values exactly on color thresholds must enter the intended warning/critical state; pinned by Task 1 tests.
- Closing the last window must terminate the app and cancel its refresh task; pinned by Task 3 cancellation coverage and Task 5 real-app verification.

---

### Task 1: Package, Models, and Pure Calculations

**Files:**
- Create: `Package.swift`
- Create: `Sources/MacMonitor/Models.swift`
- Create: `Sources/MacMonitor/MetricCalculations.swift`
- Test: `Tests/MacMonitorTests/MetricCalculationsTests.swift`

**Interfaces:**
- Produces: `CPUTicks`, `SystemProfile`, `MetricsSnapshot`, `LoadLevel`, `CPUCalculator.usage(previous:current:)`, `MetricFormatting`, and `LoadLevel.cpu(_:)` / `LoadLevel.memory(_:)`.
- Later tasks consume these exact model and calculation names.

- [ ] **Step 1: Create the package and failing calculation tests**

Create `Package.swift` with a macOS 14 executable product named `MacMonitor`, target path `Sources/MacMonitor`, and test target path `Tests/MacMonitorTests`. The model source files are sufficient for `swift test`; the executable entry point is added in Task 4.

Write tests covering first sample, normal delta, zero delta, counter regression, core-count mismatch, clamping, thresholds, memory conversion, and uptime formatting:

```swift
import XCTest
@testable import MacMonitor

final class MetricCalculationsTests: XCTestCase {
    func testFirstCPUSampleIsUnavailable() {
        XCTAssertNil(CPUCalculator.usage(previous: nil, current: [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]))
    }

    func testCPUDeltaCalculatesTotalAndCores() {
        let previous = [CPUTicks(user: 10, system: 10, idle: 80, nice: 0)]
        let current = [CPUTicks(user: 20, system: 20, idle: 140, nice: 0)]
        let result = CPUCalculator.usage(previous: previous, current: current)
        XCTAssertEqual(result?.total ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(result?.cores.first ?? 0, 20, accuracy: 0.001)
    }

    func testInvalidCPUDeltasAreUnavailable() {
        let tick = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: [tick]))
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: []))
        XCTAssertNil(CPUCalculator.usage(previous: [tick], current: [CPUTicks(user: 9, system: 10, idle: 10, nice: 0)]))
    }

    func testThresholdBoundaries() {
        XCTAssertEqual(LoadLevel.cpu(69.9), .normal)
        XCTAssertEqual(LoadLevel.cpu(70), .warning)
        XCTAssertEqual(LoadLevel.cpu(90), .critical)
        XCTAssertEqual(LoadLevel.memory(79.9), .normal)
        XCTAssertEqual(LoadLevel.memory(80), .warning)
        XCTAssertEqual(LoadLevel.memory(90), .critical)
    }

    func testFormatting() {
        XCTAssertEqual(MetricFormatting.gibibytes(34_359_738_368), "32.0")
        XCTAssertEqual(MetricFormatting.uptime(90_061), "1d 1h 1m")
        XCTAssertEqual(MetricFormatting.uptime(125), "2m")
        XCTAssertEqual(MetricFormatting.percent(23.44), "23.4%")
    }
}
```

- [ ] **Step 2: Run tests and confirm the expected failure**

Run: `swift test --filter MetricCalculationsTests`

Expected: compilation fails because the models and calculations do not exist yet.

- [ ] **Step 3: Add immutable models and minimal pure implementations**

Define these sendable value types in `Models.swift`:

```swift
struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

struct SystemProfile: Equatable, Sendable {
    let hostName: String
    let coreCount: Int
    let darwinVersion: String
    let architecture: String
    let totalMemory: UInt64
}

struct MetricsSnapshot: Equatable, Sendable {
    let uptime: TimeInterval
    let cpuUsage: Double?
    let coreUsage: [Double]
    let loadAverages: [Double]
    let usedMemory: UInt64
    let totalMemory: UInt64
}

enum LoadLevel: Equatable, Sendable { case normal, warning, critical }
```

Implement `CPUCalculator.usage` by subtracting each matching counter, rejecting regressed counters, mismatched/empty arrays, and zero total elapsed ticks. Total busy delta is user + system + nice; total elapsed also includes idle. Clamp each result with `min(max(value, 0), 100)`.

Implement `MetricFormatting.percent`, `gibibytes`, and `uptime`, plus `LoadLevel.cpu` and `.memory` using the exact global thresholds. Uptime uses days/hours/minutes when days exist, hours/minutes below one day, and minutes below one hour.

- [ ] **Step 4: Run the pure calculation tests**

Run: `swift test --filter MetricCalculationsTests`

Expected: all calculation tests pass.

### Task 2: Real Darwin Metrics Sampling

**Files:**
- Create: `Sources/MacMonitor/SystemMetricsSampler.swift`
- Create: `Sources/MacMonitor/MetricsSamplingActor.swift`
- Test: `Tests/MacMonitorTests/SystemMetricsSamplerTests.swift`

**Interfaces:**
- Consumes: `CPUTicks`, `SystemProfile`, `MetricsSnapshot`, and `CPUCalculator` from Task 1.
- Produces: `SystemMetricsSampler.readProfile()`, `readCPUTicks()`, `readUsedMemory()`, `readLoadAverages()`, and `MetricsSamplingActor.sample()`.

- [ ] **Step 1: Write failing memory arithmetic and live sampler tests**

```swift
import XCTest
@testable import MacMonitor

final class SystemMetricsSamplerTests: XCTestCase {
    func testUsedMemoryAddsOnlyActiveWiredAndCompressorPages() {
        XCTAssertEqual(
            SystemMetricsSampler.usedBytes(active: 10, wired: 20, compressor: 30, pageSize: 4096),
            245_760
        )
    }

    func testLiveSamplerReturnsPlausibleMetrics() async throws {
        let profile = try SystemMetricsSampler.readProfile()
        XCTAssertGreaterThan(profile.coreCount, 0)
        XCTAssertGreaterThan(profile.totalMemory, 0)
        XCTAssertFalse(profile.hostName.isEmpty)
        XCTAssertFalse(profile.darwinVersion.isEmpty)

        let actor = MetricsSamplingActor(profile: profile)
        let snapshot = try await actor.sample()
        XCTAssertNil(snapshot.cpuUsage)
        XCTAssertEqual(snapshot.loadAverages.count, 3)
        XCTAssertLessThanOrEqual(snapshot.usedMemory, snapshot.totalMemory)
    }
}
```

- [ ] **Step 2: Run tests and confirm the expected failure**

Run: `swift test --filter SystemMetricsSamplerTests`

Expected: compilation fails because the sampler and actor do not exist.

- [ ] **Step 3: Implement Darwin reads and stateful sampling**

In `SystemMetricsSampler.swift`, define a `SamplingError: Error, LocalizedError` with readable messages. Implement:

```swift
enum SystemMetricsSampler {
    static func readProfile() throws -> SystemProfile
    static func readCPUTicks() throws -> [CPUTicks]
    static func readUsedMemory() throws -> UInt64
    static func readLoadAverages() throws -> [Double]
    static func usedBytes(active: UInt64, wired: UInt64, compressor: UInt64, pageSize: UInt64) -> UInt64
}
```

Use `sysctlbyname` for `hw.logicalcpu`, `hw.memsize`, `kern.osrelease`, `hw.machine`, and `hw.pagesize`; check both size-query and value-read return codes. Use `ProcessInfo.processInfo.hostName` for the host name. Use `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)` for `processor_cpu_load_info`, copy every core's `cpu_ticks` into `CPUTicks`, and release the returned array with `vm_deallocate` using its byte count. Use `getloadavg` for exactly three values. Use `host_statistics64(HOST_VM_INFO64)` and add only `active_count`, `wire_count`, and `compressor_page_count` multiplied by page size; cap the final used byte count at `hw.memsize`.

In `MetricsSamplingActor.swift`, define:

```swift
protocol MetricsSampling: Sendable {
    func profile() async -> SystemProfile
    func sample() async throws -> MetricsSnapshot
}

actor MetricsSamplingActor: MetricsSampling {
    let systemProfile: SystemProfile
    func profile() async -> SystemProfile { systemProfile }
    func sample() async throws -> MetricsSnapshot
}
```

Store previous ticks privately in the actor. Each `sample()` reads current ticks, calculates against the previous value, then saves current ticks even if the delta calculation is unavailable. Read uptime from `ProcessInfo.processInfo.systemUptime`; use the profile's total memory in the snapshot.

- [ ] **Step 4: Run sampler and existing tests**

Run: `swift test`

Expected: all tests pass; the live test reports the first CPU value as unavailable and returns real nonempty system information.

### Task 3: Refresh Lifecycle and Failure Recovery

**Files:**
- Create: `Sources/MacMonitor/MetricsStore.swift`
- Test: `Tests/MacMonitorTests/MetricsStoreTests.swift`

**Interfaces:**
- Consumes: `MetricsSampling`, `SystemProfile`, and `MetricsSnapshot`.
- Produces: `@MainActor MetricsStore` with `profile`, `snapshot`, `errorMessage`, `start()`, and `stop()` for the UI.

- [ ] **Step 1: Write failing store lifecycle tests**

Create an actor fake implementing `MetricsSampling`, with configurable snapshot results and counters for `profile()` and `sample()` calls. Use this fixture:

```swift
let profile = SystemProfile(hostName: "test-mac", coreCount: 2, darwinVersion: "test", architecture: "arm64", totalMemory: 1024)
let snapshot = MetricsSnapshot(uptime: 60, cpuUsage: 25, coreUsage: [20, 30], loadAverages: [1, 2, 3], usedMemory: 256, totalMemory: 1024)
```

Test these exact behaviors:

```swift
@MainActor
func testStartIsIdempotent() async {
    let fake = MetricsFake(profile: profile, results: [.success(snapshot)])
    let store = MetricsStore(providerFactory: { fake }, sleep: { try await Task.sleep(for: .seconds(60)) })
    store.start()
    store.start()
    await Task.yield()
    store.stop()
    let count = await fake.profileCallCount
    XCTAssertEqual(count, 1)
}

@MainActor
func testFailureKeepsLastSnapshotAndNextSuccessClearsError() async {
    let fake = MetricsFake(profile: profile, results: [.success(snapshot), .failure(TestError.sample), .success(snapshot)])
    let store = MetricsStore(providerFactory: { fake }, sleep: { try await Task.sleep(for: .milliseconds(1)) })
    store.start()
    try await Task.sleep(for: .milliseconds(30))
    store.stop()
    XCTAssertEqual(store.snapshot, snapshot)
    XCTAssertNil(store.errorMessage)
    let count = await fake.sampleCallCount
    XCTAssertGreaterThanOrEqual(count, 3)
}
```

Also test that `stop()` prevents additional samples after the in-flight iteration completes.

- [ ] **Step 2: Run tests and confirm the expected failure**

Run: `swift test --filter MetricsStoreTests`

Expected: compilation fails because `MetricsStore` and its injectable sleep operation do not exist.

- [ ] **Step 3: Implement the main-actor store**

Use this public interface:

```swift
@MainActor
final class MetricsStore: ObservableObject {
    @Published private(set) var profile: SystemProfile?
    @Published private(set) var snapshot: MetricsSnapshot?
    @Published private(set) var errorMessage: String?

    init(
        providerFactory: @escaping @Sendable () throws -> any MetricsSampling = { try MetricsSamplingActor(profile: SystemMetricsSampler.readProfile()) },
        sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
    )

    func start()
    func stop()
}
```

Let the task catch and publish provider-initialization errors. Guard `start()` with `samplingTask == nil`; cancel and clear the task in `stop()`. Inside the loop, publish each successful snapshot and clear the error; on a sample error keep the existing snapshot, publish `error.localizedDescription`, and continue after the injected sleep. Cancellation must exit quietly without replacing valid data with an error.

- [ ] **Step 4: Run all tests**

Run: `swift test`

Expected: calculation, sampler, and store tests all pass without duplicate refresh loops.

### Task 4: Bright SwiftUI Panel and Window Behavior

**Files:**
- Create: `Sources/MacMonitor/MacMonitorApp.swift`
- Create: `Sources/MacMonitor/MonitorView.swift`
- Create: `Sources/MacMonitor/WindowConfigurator.swift`
- Create: `Sources/MacMonitor/MetricViews.swift`

**Interfaces:**
- Consumes: `MetricsStore`, `SystemProfile`, `MetricsSnapshot`, `MetricFormatting`, and `LoadLevel`.
- Produces: the runnable `@main MacMonitorApp`, light `MonitorView`, reusable metric bars, and `WindowConfigurator(isPinned:)`.

- [ ] **Step 1: Implement reusable visual components**

Define the palette as `Color` extensions: warm-white `F7F8FA`, primary text `20242B`, secondary text `6D7480`, track `E5E9EF`, CPU blue `4385F5`, memory teal `20B8A6`, warning orange `F5A623`, and critical coral `EF6262`.

Create `MetricBar(value:color:)` with a 10-point rounded track and proportional fill clamped to 0...1. Create `CoreUsageGrid(values:)` using `LazyVGrid` with `GridItem(.adaptive(minimum: 68), spacing: 8)`; each cell includes a small core label and a 6-point bar. Map `LoadLevel.normal` to CPU blue for CPU cells, warning to orange, and critical to coral.

- [ ] **Step 2: Implement the complete panel**

Build `MonitorView(store:)` with `@ObservedObject` and `@State private var isPinned = false`. Use a warm-white background, 20-point horizontal padding, 16-point vertical spacing, monospaced digits for changing numeric values, and a subtle light border/shadow. Layout in this order:

1. Host name in a semibold title; right side `up <formatted uptime>` and a pin toggle using `pin` / `pin.fill`.
2. `CPU` label and `MetricFormatting.percent` or `—`; total bar; `<coreCount> cores · load <1> <5> <15>`; per-core grid.
3. `MEMORY` label and `<used> / <total> GiB`; teal/warning/critical total bar.
4. Divider and `Darwin <version> · <architecture> · 3s 刷新`.

When no snapshot exists, show placeholder dashes rather than zeros. If `errorMessage` is nonnil, replace the footer refresh text with a short `刷新失败，保留上次数据` message while retaining the previous values. Call `store.start()` once in `.task` and `store.stop()` in `.onDisappear`. Put content in a `ScrollView` so narrow/small windows do not clip core cells.

- [ ] **Step 3: Configure the application window**

Implement `@main struct MacMonitorApp: App` with `@NSApplicationDelegateAdaptor`, a `StateObject` store, and one `WindowGroup`. Use `.windowStyle(.hiddenTitleBar)`, `.defaultSize(width: 580, height: 420)`, and a content minimum frame of 420 × 360. Set `applicationShouldTerminateAfterLastWindowClosed` to `true` in the delegate.

Implement `WindowConfigurator` as an `NSViewRepresentable` that finds the enclosing `NSWindow`, applies `.floating` when pinned and `.normal` otherwise, sets a transparent titlebar/full-size content view, and keeps standard dragging, resizing, and close behavior. Do not create a borderless window that cannot be moved.

- [ ] **Step 4: Build and check the UI compilation**

Run: `swift build && swift test`

Expected: the app and tests compile; all tests remain green. Visual behavior is verified in Task 5, not inferred from compilation.

### Task 5: App Bundle and End-to-End Verification

**Files:**
- Create: `Scripts/build-app.sh`
- Create: `Resources/Info.plist`
- Create: `.gitignore`

**Interfaces:**
- Consumes: the completed executable from Task 4.
- Produces: `dist/MacMonitor.app` via `./Scripts/build-app.sh`.

- [ ] **Step 1: Add the application metadata and build script**

Create `Resources/Info.plist` with bundle identifier `local.macmonitor.app`, executable `MacMonitor`, bundle name `Mac Monitor`, minimum system version `14.0`, high-resolution support enabled, and no sandbox entitlement claims.

Create `Scripts/build-app.sh` with `set -euo pipefail`, run `swift build -c release`, create `dist/MacMonitor.app/Contents/{MacOS,Resources}`, copy `.build/release/MacMonitor` into `Contents/MacOS/MacMonitor`, copy the plist to `Contents/Info.plist`, and mark the executable and script executable. Add `.build/`, `.swiftpm/`, and `dist/` to `.gitignore`.

- [ ] **Step 2: Build the real deliverable**

Run: `./Scripts/build-app.sh && plutil -lint dist/MacMonitor.app/Contents/Info.plist`

Expected: release build succeeds and the plist reports `OK`. Confirm the app binary exists and is executable with `test -x dist/MacMonitor.app/Contents/MacOS/MacMonitor`.

- [ ] **Step 3: Run automated verification on the packaged source**

Run: `swift test`

Expected: all tests pass on the final source. Then compare live values with `sysctl -n hw.logicalcpu hw.memsize kern.osrelease hw.machine`, `sysctl -n vm.loadavg`, and Activity Monitor. Accept timing and memory-accounting differences, but core count, total memory, Darwin version, and architecture must match.

- [ ] **Step 4: Exercise the actual app window**

Launch `open dist/MacMonitor.app` and inspect the real window through the macOS computer-use tooling. Verify:

- The warm-white light theme, blue/teal bars, readable text, host name, real memory, and system fields are visible.
- The first CPU value resolves from `—` to a percentage after a subsequent sample.
- At least three refresh cycles occur without the UI freezing; uptime and load values update.
- The pin button changes the window level; dragging and resizing work; at 420 × 360 the content remains reachable by scrolling.
- Closing the only window exits the process and no sampler continues running.

If any check fails, fix the owning component, rerun `swift test`, rebuild the `.app`, and repeat the real-window check before reporting completion.
