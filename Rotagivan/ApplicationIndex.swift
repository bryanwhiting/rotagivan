import Foundation
import Combine

@MainActor final class VoiceApplicationIndex: ObservableObject {
    static let shared = VoiceApplicationIndex()
    @Published private(set) var applications: [ExplorerApplication] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var refreshError: String?
    @Published private(set) var observationError: String?
    private var loading: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var generation = UUID()
    private var observing = false
    private var pendingChange = false
    private var debounce: Task<Void, Never>?
    private let observation: ApplicationIndexChangeObserving
    private let debounceInterval: TimeInterval
    private let refreshInterval: TimeInterval
    private let scan: @Sendable () -> ExplorerApplicationCatalog.ScanResult

    init(refreshInterval: TimeInterval = 60,
         debounceInterval: TimeInterval = 0.5,
         observation: ApplicationIndexChangeObserving? = nil,
         scan: @escaping @Sendable () -> ExplorerApplicationCatalog.ScanResult = { ExplorerApplicationCatalog.scanWithStatus() }) {
        self.refreshInterval = refreshInterval
        self.debounceInterval = debounceInterval
        self.observation = observation ?? ApplicationIndexObservation()
        self.scan = scan
    }

    /// Begin this computer's observation and warm the cache without blocking startup.
    func start() {
        guard !observing else { return }
        observing = true; generation = UUID(); observationError = nil
        let token = generation
        observation.start(onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing, self.generation == token else { return }
                self.scheduleChange()
            }
        }, onError: { [weak self] error in
            Task { @MainActor in
                guard let self, self.observing, self.generation == token else { return }
                self.observationError = error
            }
        })
        pendingChange = true
        Task {
            guard observing, generation == token else { return }
            await refresh(force: true)
        }
    }
    func stop() {
        observing = false; generation = UUID()
        observation.stop(); debounce?.cancel(); debounce = nil; pendingChange = false
        // Do not cancel/release the actual disk scan: restart must await its drain.
        isRefreshing = false
    }
    private func scheduleChange() {
        debounce?.cancel()
        let token = generation
        debounce = Task { @MainActor in
            if debounceInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(debounceInterval, 60) * 1_000_000_000))
            }
            guard !Task.isCancelled, observing, generation == token else { return }
            debounce = nil; pendingChange = true
            await refresh(force: true)
        }
    }

    func load() async {
        // Listening can use the last complete snapshot while expired data refreshes.
        // First use still awaits a catalog, and explicit reindex always awaits completion.
        if lastRefreshedAt != nil {
            if loading == nil, lastAttemptAt.map({ Date().timeIntervalSince($0) >= refreshInterval }) ?? true {
                let token = generation
                Task {
                    guard generation == token else { return }
                    await refresh()
                }
            }
            return
        }
        await refresh()
    }

    /// Only this machine's application roots are scanned; nothing is persisted or synced.
    /// Concurrent callers (including manual reindex) await the same background scan.
    func refresh(force: Bool = false) async {
        if let loading {
            await loading.value
            return
        }
        if !force, let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < refreshInterval { return }
        isRefreshing = true
        refreshError = nil
        let scan = scan
        let requestedGeneration = generation
        let work = Task { @MainActor in
            guard requestedGeneration == generation || pendingChange else {
                isRefreshing = false; loading = nil; return
            }
            repeat {
                pendingChange = false
                let token = generation
                isRefreshing = true
                let result = await Task.detached(priority: .utility) { scan() }.value
                guard token == generation else { continue }
                lastAttemptAt = Date()
                if result.errors.isEmpty {
                    applications = result.applications
                    lastRefreshedAt = lastAttemptAt
                    refreshError = nil
                } else {
                    // Preserve the last complete catalog on transient read failures.
                    refreshError = result.errors.joined(separator: "\n")
                }
            } while pendingChange
            isRefreshing = false
            loading = nil
        }
        loading = work
        await work.value
    }
}
