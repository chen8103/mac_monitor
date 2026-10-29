import Combine
import Foundation

@MainActor
final class MetricsStore: ObservableObject {
    @Published private(set) var profile: SystemProfile?
    @Published private(set) var snapshot: MetricsSnapshot?
    @Published private(set) var errorMessage: String?

    private let providerFactory: @Sendable () throws -> any MetricsSampling
    private let sleep: @Sendable () async throws -> Void
    private var samplingTask: Task<Void, Never>?
    private var samplingGeneration = 0

    init(
        providerFactory: @escaping @Sendable () throws -> any MetricsSampling = {
            MetricsSamplingActor(profile: try SystemMetricsSampler.readProfile())
        },
        sleep: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(3))
        }
    ) {
        self.providerFactory = providerFactory
        self.sleep = sleep
    }

    func start() {
        guard samplingTask == nil else { return }

        samplingGeneration += 1
        let generation = samplingGeneration
        samplingTask = Task { [providerFactory, sleep] in
            defer {
                if samplingGeneration == generation {
                    samplingTask = nil
                }
            }

            do {
                let provider = try providerFactory()
                let latestProfile = await provider.profile()
                guard samplingGeneration == generation, !Task.isCancelled else { return }
                profile = latestProfile

                while !Task.isCancelled {
                    do {
                        let latest = try await provider.sample()
                        guard samplingGeneration == generation, !Task.isCancelled else { return }
                        snapshot = latest
                        errorMessage = nil
                    } catch is CancellationError {
                        break
                    } catch {
                        guard samplingGeneration == generation, !Task.isCancelled else { return }
                        errorMessage = error.localizedDescription
                    }

                    do {
                        try await sleep()
                        guard samplingGeneration == generation, !Task.isCancelled else { return }
                    } catch is CancellationError {
                        break
                    } catch {
                        guard samplingGeneration == generation, !Task.isCancelled else { return }
                        errorMessage = error.localizedDescription
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                guard samplingGeneration == generation, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        samplingGeneration += 1
        samplingTask?.cancel()
        samplingTask = nil
    }
}
