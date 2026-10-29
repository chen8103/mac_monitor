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

        samplingTask = Task { [providerFactory, sleep] in
            do {
                let provider = try providerFactory()
                profile = await provider.profile()

                while !Task.isCancelled {
                    do {
                        let latest = try await provider.sample()
                        snapshot = latest
                        errorMessage = nil
                    } catch is CancellationError {
                        break
                    } catch {
                        errorMessage = error.localizedDescription
                    }

                    do {
                        try await sleep()
                    } catch is CancellationError {
                        break
                    } catch {
                        errorMessage = error.localizedDescription
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }
}
