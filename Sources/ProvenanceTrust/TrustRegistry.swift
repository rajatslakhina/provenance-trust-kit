import Foundation

public enum RegistryError: Error, Sendable, Equatable {
    case illegalTransition(TransitionRejection)
    case unknownAsset
    case notRevoked
}

/// The client-side cache of provenance verdicts.
///
/// Two properties do the work here, and they pull in opposite directions:
///
/// * **The hot path never awaits the network.** `display(assetID:)` is called from a
///   collection-view cell. It returns whatever is cached, immediately, plus a flag
///   saying whether a revocation re-check is due. Blocking a scroll on a round trip to
///   attest a badge is how this feature gets turned off in the next release.
/// * **A withdrawn attestation must not come back on its own.** Everything cached here
///   can be contradicted later by the service, so revocation is applied eagerly across
///   every asset from the offending sensor and is sticky until an explicit
///   `reauthorize`.
///
/// Bounded by an LRU with a fixed capacity: a photo feed can scroll past tens of
/// thousands of assets in a session, and an unbounded verdict cache is a memory leak
/// that only shows up on the devices least able to absorb it.
public actor TrustRegistry {

    public struct Entry: Sendable, Equatable {
        public let verdict: ProvenanceVerdict
        public let hardwareIdentifier: String?
        public let recordedAt: Date
        public let lastRevocationCheck: Date?
    }

    public struct DisplayResult: Sendable, Equatable {
        public let verdict: ProvenanceVerdict
        /// True when this verdict is an attested one whose revocation TTL has elapsed.
        /// The caller renders anyway and schedules the check off the hot path.
        public let needsRevocationRecheck: Bool
        public let age: TimeInterval
    }

    private var entries: [String: Entry] = [:]
    /// Most-recently-used last. Linear maintenance is fine at these capacities and is
    /// far easier to prove correct than an intrusive list.
    private var recency: [String] = []

    // `nonisolated` because both are immutable, `Sendable`, and read by callers that
    // are only configuring UI — making them actor-isolated would force a hop for a
    // constant.
    public nonisolated let capacity: Int
    public nonisolated let revocationTTL: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        capacity: Int = 512,
        revocationTTL: TimeInterval = 900,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        // Clamped rather than precondition-checked: a zero capacity from a remote
        // config value should degrade to "cache one entry", not crash the app.
        self.capacity = max(1, capacity)
        self.revocationTTL = max(0, revocationTTL)
        self.clock = clock
    }

    public var count: Int { entries.count }

    /// Records a verdict, rejecting an illegal transition rather than overwriting.
    public func record(
        _ verdict: ProvenanceVerdict,
        for assetID: String,
        hardwareIdentifier: String? = nil
    ) throws {
        if let existing = entries[assetID],
           let rejection = ProvenanceVerdict.rejection(movingFrom: existing.verdict, to: verdict) {
            throw RegistryError.illegalTransition(rejection)
        }

        let now = clock()
        entries[assetID] = Entry(
            verdict: verdict,
            hardwareIdentifier: hardwareIdentifier ?? entries[assetID]?.hardwareIdentifier,
            recordedAt: now,
            // A freshly recorded attested verdict counts as just-checked; anything else
            // has no revocation state worth timing.
            lastRevocationCheck: verdict.requiresRevocationRecheck ? now : nil
        )
        touch(assetID)
        evictIfNeeded()
    }

    /// Hot path. Pure local read — no `await` on anything that can block.
    public func display(assetID: String) -> DisplayResult? {
        guard let entry = entries[assetID] else { return nil }
        touch(assetID)

        let now = clock()
        let age = now.timeIntervalSince(entry.recordedAt)
        let needsRecheck: Bool
        if entry.verdict.requiresRevocationRecheck {
            let lastChecked = entry.lastRevocationCheck ?? entry.recordedAt
            needsRecheck = now.timeIntervalSince(lastChecked) >= revocationTTL
        } else {
            needsRecheck = false
        }
        return DisplayResult(verdict: entry.verdict, needsRevocationRecheck: needsRecheck, age: age)
    }

    /// Assets whose attestation is due a re-check, newest-used first.
    public func assetsNeedingRevocationCheck() -> [String] {
        let now = clock()
        return recency.reversed().filter { assetID in
            guard let entry = entries[assetID], entry.verdict.requiresRevocationRecheck else { return false }
            let lastChecked = entry.lastRevocationCheck ?? entry.recordedAt
            return now.timeIntervalSince(lastChecked) >= revocationTTL
        }
    }

    public func noteRevocationChecked(assetID: String) {
        guard let entry = entries[assetID] else { return }
        entries[assetID] = Entry(
            verdict: entry.verdict,
            hardwareIdentifier: entry.hardwareIdentifier,
            recordedAt: entry.recordedAt,
            lastRevocationCheck: clock()
        )
    }

    /// Applies a retroactive sensor revocation.
    ///
    /// Sweeps every cached asset signed by that sensor, not just the one the user is
    /// looking at. Assets still in `pendingDevelopment` are left alone: they carry no
    /// attestation yet, so there is nothing to withdraw, and moving them to `revoked`
    /// would strand them in a sticky state they never earned.
    ///
    /// - Returns: the asset IDs whose verdict changed.
    @discardableResult
    public func applyRevocation(hardwareIdentifier: String, reason: RevocationReason) -> [String] {
        var changed: [String] = []
        let now = clock()
        for (assetID, entry) in entries {
            guard entry.hardwareIdentifier == hardwareIdentifier,
                  let reference = entry.verdict.referenceID else { continue }
            let revokedVerdict = ProvenanceVerdict.revoked(reference: reference, reason: reason)
            guard entry.verdict != revokedVerdict else { continue }
            entries[assetID] = Entry(
                verdict: revokedVerdict,
                hardwareIdentifier: entry.hardwareIdentifier,
                recordedAt: now,
                lastRevocationCheck: now
            )
            changed.append(assetID)
        }
        return changed.sorted()
    }

    /// The only way out of `revoked`: an explicit, auditable call that drops the asset
    /// back to `pendingDevelopment` so it must be developed again from scratch.
    public func reauthorize(assetID: String) throws {
        guard let entry = entries[assetID] else { throw RegistryError.unknownAsset }
        guard case .revoked = entry.verdict else { throw RegistryError.notRevoked }
        entries[assetID] = Entry(
            verdict: .pendingDevelopment,
            hardwareIdentifier: entry.hardwareIdentifier,
            recordedAt: clock(),
            lastRevocationCheck: nil
        )
        touch(assetID)
    }

    public func entry(for assetID: String) -> Entry? { entries[assetID] }

    // MARK: - LRU maintenance

    private func touch(_ assetID: String) {
        if let index = recency.firstIndex(of: assetID) {
            recency.remove(at: index)
        }
        recency.append(assetID)
    }

    private func evictIfNeeded() {
        while entries.count > capacity, !recency.isEmpty {
            let oldest = recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        // Defensive: keep the recency list from outgrowing the entry map if a key was
        // removed by another path.
        if recency.count > entries.count {
            recency = recency.filter { entries[$0] != nil }
        }
    }
}
