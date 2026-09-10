import Foundation

/// A scriptable stand-in for the platform service.
///
/// Present in the shipping module rather than only in tests, because the demo app and
/// anyone evaluating this package need to drive the failure modes — revocation
/// mid-session, timeout, region gating — without an unreleased device.
public actor SimulatedReferenceImageProvider: ReferenceImageProvider {

    public struct Script: Sendable {
        /// Errors returned, in order, before the first success. Empty means succeed
        /// immediately.
        public var failuresBeforeSuccess: [ProviderError]
        /// Region gate applied before anything else.
        public var regionBlocked: Bool

        public init(failuresBeforeSuccess: [ProviderError] = [], regionBlocked: Bool = false) {
            self.failuresBeforeSuccess = failuresBeforeSuccess
            self.regionBlocked = regionBlocked
        }
    }

    private var script: Script
    private var remainingFailures: [ProviderError]
    private var revoked: [ReferenceID: RevocationReason] = [:]
    private var issued: [String: ReferenceRecord] = [:]
    private var issuedOrder: [String] = []

    /// This type ships in the module rather than only in tests, so it obeys the same
    /// bounded-cache rule as the rest of the package: a long-lived fake driving a demo
    /// must not grow without limit either.
    public static let maximumIssuedReferences = 256

    /// Every develop call, including ones served from the idempotency cache.
    public private(set) var developCallCount = 0
    /// Develop calls that actually minted a new reference.
    public private(set) var mintCount = 0
    public private(set) var revocationCheckCount = 0

    private let referencePlane: GrayscaleBuffer
    private let clock: @Sendable () -> Date

    public init(
        script: Script = Script(),
        referencePlane: GrayscaleBuffer? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.script = script
        self.remainingFailures = script.failuresBeforeSuccess
        self.referencePlane = referencePlane ?? DemoFixtures.referenceScene()
        self.clock = clock
    }

    public func developReference(for capture: CaptureDescriptor) async throws -> ReferenceRecord {
        developCallCount += 1

        if script.regionBlocked { throw ProviderError.regionUnavailable }
        if !remainingFailures.isEmpty {
            let error = remainingFailures.removeFirst()
            throw error
        }

        // Idempotency: a retry after a timeout must not mint a second reference for one
        // capture. Keyed on the capture's own key, not on a client-generated UUID.
        let key = capture.idempotencyKey
        if let existing = issued[key] { return existing }

        guard let referenceID = ReferenceID("ref-" + key.prefix(16)) else {
            throw ProviderError.sensorRejected
        }
        let record = ReferenceRecord(
            referenceID: referenceID,
            hardwareIdentifier: capture.hardwareIdentifier,
            developedAt: clock(),
            referencePlane: referencePlane
        )
        issued[key] = record
        issuedOrder.append(key)
        while issued.count > Self.maximumIssuedReferences, !issuedOrder.isEmpty {
            let oldest = issuedOrder.removeFirst()
            if let evicted = issued.removeValue(forKey: oldest) {
                revoked.removeValue(forKey: evicted.referenceID)
            }
        }
        mintCount += 1
        return record
    }

    public func revocationStates(for references: [ReferenceID]) async throws -> [ReferenceID: RevocationState] {
        revocationCheckCount += 1
        var output: [ReferenceID: RevocationState] = [:]
        for reference in references {
            if let reason = revoked[reference] {
                output[reference] = .revoked(reason)
            } else {
                output[reference] = .valid
            }
        }
        return output
    }

    // MARK: - Test and demo controls

    /// Withdraws every reference this provider has issued for a given sensor, which is
    /// what a real retroactive sensor revocation looks like from the client's side.
    @discardableResult
    public func revokeSensor(_ hardwareIdentifier: String, reason: RevocationReason) -> [ReferenceID] {
        var affected: [ReferenceID] = []
        for record in issued.values where record.hardwareIdentifier == hardwareIdentifier {
            revoked[record.referenceID] = reason
            affected.append(record.referenceID)
        }
        return affected
    }

    public func setScript(_ script: Script) {
        self.script = script
        self.remainingFailures = script.failuresBeforeSuccess
    }

    public func issuedReferenceCount() -> Int { issued.count }
}
