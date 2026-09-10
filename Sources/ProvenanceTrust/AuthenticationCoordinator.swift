import Foundation

/// Abstracts the wait between retries so tests do not spend real seconds asleep.
public protocol Sleeper: Sendable {
    func sleep(for duration: TimeInterval) async
}

public struct SystemSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: TimeInterval) async {
        guard duration > 0 else { return }
        let nanoseconds = SafeArithmetic.clampedInt((duration * 1_000_000_000).rounded())
        guard nanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
    }
}

/// Records requested delays instead of waiting. Lets a test assert the exact backoff
/// schedule, which a `Task.sleep`-based one can only approximate.
public actor RecordingSleeper: Sleeper {
    public private(set) var recorded: [TimeInterval] = []
    public init() {}
    public func sleep(for duration: TimeInterval) async {
        recorded.append(duration)
    }
}

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, multiplier: Double = 2, maxDelay: TimeInterval = 8) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.multiplier = multiplier.isFinite ? max(1, multiplier) : 1
        self.maxDelay = max(0, maxDelay)
    }

    /// Deterministic exponential backoff, no jitter.
    ///
    /// Jitter exists to break up synchronised retries from many clients. That pressure
    /// does not apply here: authentication is user-initiated and per-asset, in-flight
    /// requests for one asset are coalesced, and the batch revocation sweep is already
    /// spread by its own TTL. A deterministic schedule buys an exactly-assertable test
    /// in return, which is the better trade at this scale. A background sweep across
    /// every cached asset would need the jitter back.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0, baseDelay > 0 else { return 0 }
        let exponent = Double(min(attempt - 1, 30))
        let scaled = baseDelay * pow(multiplier, exponent)
        guard scaled.isFinite else { return maxDelay }
        return min(scaled, maxDelay)
    }
}

public struct MatchPolicy: Sendable {
    /// Combined score at or above which a derivative still counts as matching.
    public let verifiedThreshold: Double
    /// Floor on the single worst heatmap block.
    ///
    /// Without it, a small deliberate edit in one corner of an otherwise untouched
    /// frame passes: the mean barely moves and the perceptual hash is a 64-bit summary
    /// that a local change need not disturb. The floor is the whole reason the heatmap
    /// is computed rather than just a global score.
    public let worstBlockFloor: Double

    public init(verifiedThreshold: Double = 0.92, worstBlockFloor: Double = 0.6) {
        self.verifiedThreshold = SafeArithmetic.unitClamped(verifiedThreshold)
        self.worstBlockFloor = SafeArithmetic.unitClamped(worstBlockFloor)
    }
}

/// A verdict together with the comparison it was derived from.
///
/// They travel as one value on purpose. Returning only the verdict and letting the UI
/// recompute a heatmap against whatever plane it happens to hold would let the badge and
/// the picture beside it disagree — the heatmap has to be the evidence for *this*
/// verdict, not a second opinion.
public struct AuthenticationOutcome: Sendable, Equatable {
    public let verdict: ProvenanceVerdict
    /// `nil` when no comparison was performed (an error path, or a gated region).
    public let report: DiffReport?

    public init(verdict: ProvenanceVerdict, report: DiffReport?) {
        self.verdict = verdict
        self.report = report
    }
}

public struct AuthenticationRequest: Sendable, Equatable {
    public let capture: CaptureDescriptor
    /// The bytes actually held by the client, which may already have been resized or
    /// re-encoded by the time provenance is asked about.
    public let derivative: GrayscaleBuffer

    public init(capture: CaptureDescriptor, derivative: GrayscaleBuffer) {
        self.capture = capture
        self.derivative = derivative
    }

    public var assetID: String { capture.assetID }
}

/// Serialises, coalesces and retries lazy authentication.
public actor AuthenticationCoordinator {

    private struct InFlight {
        let generation: UInt64
        let task: Task<AuthenticationOutcome, Never>
    }

    private let provider: any ReferenceImageProvider
    private let registry: TrustRegistry
    private let retryPolicy: RetryPolicy
    private let matchPolicy: MatchPolicy
    private let sleeper: any Sleeper
    private let queueCapacity: Int

    private var inFlight: [String: InFlight] = [:]
    private var generationCounter: UInt64 = 0
    private var offlineQueue: [AuthenticationRequest] = []

    public private(set) var coalescedRequestCount = 0
    public private(set) var droppedQueueEntryCount = 0
    public private(set) var isOffline = false

    public init(
        provider: any ReferenceImageProvider,
        registry: TrustRegistry,
        retryPolicy: RetryPolicy = RetryPolicy(),
        matchPolicy: MatchPolicy = MatchPolicy(),
        sleeper: any Sleeper = SystemSleeper(),
        queueCapacity: Int = 64
    ) {
        self.provider = provider
        self.registry = registry
        self.retryPolicy = retryPolicy
        self.matchPolicy = matchPolicy
        self.sleeper = sleeper
        self.queueCapacity = max(1, queueCapacity)
    }

    public var queuedRequestCount: Int { offlineQueue.count }

    public var inFlightRequestCount: Int { inFlight.count }

    public func setOffline(_ offline: Bool) { isOffline = offline }

    /// Authenticates one asset, coalescing concurrent callers onto one network call.
    @discardableResult
    public func authenticate(_ request: AuthenticationRequest) async -> AuthenticationOutcome {
        if let existing = inFlight[request.assetID] {
            coalescedRequestCount += 1
            return await existing.task.value
        }

        if isOffline {
            enqueue(request)
            return AuthenticationOutcome(
                verdict: .unavailable(reason: .developingServiceUnreachable),
                report: nil
            )
        }

        generationCounter &+= 1
        let generation = generationCounter
        let task = Task<AuthenticationOutcome, Never> { [self] in
            await self.perform(request)
        }
        // Installed *before* the first suspension so a concurrent caller that arrives
        // while `task` is running finds it and joins.
        inFlight[request.assetID] = InFlight(generation: generation, task: task)

        let outcome = await task.value

        // Actor reentrancy across the `await` above. `abandon(assetID:)` can clear this
        // slot while the task is still running — a user navigating away, or a
        // pull-to-refresh — after which a new caller installs its own task under a newer
        // generation. Clearing unconditionally here would then evict *that* caller's
        // in-flight task and let a duplicate network call through. The generation stamp
        // makes the removal idempotent.
        // `AuthenticationCoordinatorTests.testAbandonThenRestartIsNotEvictedByTheOriginalCaller`
        // fails if this guard is removed.
        clearInFlight(assetID: request.assetID, generation: generation)
        return outcome
    }

    /// Forgets the in-flight request for an asset so a later call starts a fresh one.
    ///
    /// The running task is deliberately not cancelled: it may already have minted a
    /// reference server-side, and letting it finish writing that to the registry is
    /// cheaper than discovering it again later. This only detaches future callers.
    public func abandon(assetID: String) {
        inFlight.removeValue(forKey: assetID)
    }

    /// Replays queued requests after connectivity returns. Oldest first, so the user's
    /// earliest tap resolves first.
    /// Replays queued requests in the order they were queued, oldest first, so the
    /// user's earliest tap resolves first. Returns an ordered array rather than a
    /// dictionary precisely so that ordering is observable — a `[String: Verdict]`
    /// return makes the guarantee untestable.
    @discardableResult
    public func drainQueue() async -> [(assetID: String, verdict: ProvenanceVerdict)] {
        guard !isOffline else { return [] }
        let pending = offlineQueue
        offlineQueue.removeAll()

        var results: [(assetID: String, verdict: ProvenanceVerdict)] = []
        results.reserveCapacity(pending.count)
        for request in pending {
            results.append((request.assetID, await authenticate(request).verdict))
        }
        return results
    }

    /// Off-hot-path revocation sweep for everything the registry says is due.
    @discardableResult
    public func sweepRevocations() async -> [String] {
        let due = await registry.assetsNeedingRevocationCheck()
        guard !due.isEmpty else { return [] }

        var references: [ReferenceID] = []
        var referenceOwners: [ReferenceID: [String]] = [:]
        for assetID in due {
            guard let entry = await registry.entry(for: assetID),
                  let reference = entry.verdict.referenceID else { continue }
            if referenceOwners[reference] == nil { references.append(reference) }
            referenceOwners[reference, default: []].append(assetID)
        }
        guard !references.isEmpty else { return [] }

        guard let states = try? await provider.revocationStates(for: references) else { return [] }

        var revokedAssets: [String] = []
        for (reference, state) in states {
            let owners = referenceOwners[reference] ?? []
            switch state {
            case .valid:
                for assetID in owners { await registry.noteRevocationChecked(assetID: assetID) }
            case .revoked(let reason):
                for assetID in owners {
                    // Only report assets whose verdict actually changed. Appending
                    // regardless would let a swallowed rejection be reported to the
                    // caller as an applied revocation.
                    do {
                        try await registry.record(
                            .revoked(reference: reference, reason: reason),
                            for: assetID
                        )
                        revokedAssets.append(assetID)
                    } catch {
                        continue
                    }
                }
            }
        }
        return revokedAssets.sorted()
    }

    // MARK: - Internals

    private func clearInFlight(assetID: String, generation: UInt64) {
        guard inFlight[assetID]?.generation == generation else { return }
        inFlight.removeValue(forKey: assetID)
    }

    private func enqueue(_ request: AuthenticationRequest) {
        // Drop-oldest. A bounded queue is the point; the alternative is a queue that
        // grows for the whole time a device is in a tunnel and then stampedes on exit.
        if offlineQueue.count >= queueCapacity {
            offlineQueue.removeFirst()
            droppedQueueEntryCount += 1
        }
        offlineQueue.removeAll { $0.assetID == request.assetID }
        offlineQueue.append(request)
    }

    private func perform(_ request: AuthenticationRequest) async -> AuthenticationOutcome {
        var attempt = 0
        var lastError: ProviderError = .timedOut

        while attempt < retryPolicy.maxAttempts {
            attempt += 1
            do {
                let record = try await provider.developReference(for: request.capture)
                let outcome = evaluate(record: record, derivative: request.derivative)
                try? await registry.record(
                    outcome.verdict,
                    for: request.assetID,
                    hardwareIdentifier: record.hardwareIdentifier
                )
                return outcome
            } catch let error as ProviderError {
                lastError = error
                guard error.isRetryable, attempt < retryPolicy.maxAttempts else { break }
                await sleeper.sleep(for: retryPolicy.delay(forAttempt: attempt))
            } catch {
                lastError = .transient(code: -1)
                break
            }
        }

        let verdict = ProvenanceVerdict.unavailable(reason: Self.reason(for: lastError))
        try? await registry.record(
            verdict,
            for: request.assetID,
            hardwareIdentifier: request.capture.hardwareIdentifier
        )
        return AuthenticationOutcome(verdict: verdict, report: nil)
    }

    private func evaluate(record: ReferenceRecord, derivative: GrayscaleBuffer) -> AuthenticationOutcome {
        // The heatmap is computed against `record.referencePlane` — the same plane the
        // verdict is derived from — so the picture and the badge cannot disagree.
        let report = PerceptualDiff.compare(reference: record.referencePlane, derivative: derivative)
        let matches = report.matchScore >= matchPolicy.verifiedThreshold
            && report.worstBlockSimilarity >= matchPolicy.worstBlockFloor
        let verdict: ProvenanceVerdict = matches
            ? .verified(reference: record.referenceID, matchScore: report.matchScore)
            : .mismatch(reference: record.referenceID, matchScore: report.matchScore)
        return AuthenticationOutcome(verdict: verdict, report: report)
    }

    private static func reason(for error: ProviderError) -> UnavailabilityReason {
        switch error {
        case .timedOut: return .developingServiceTimedOut
        case .offline, .transient: return .developingServiceUnreachable
        case .regionUnavailable: return .regionUnavailable
        case .sensorRejected: return .captureDeviceUnsupported
        }
    }
}
