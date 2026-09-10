import Foundation

/// Everything a badge needs to render, resolved in one value.
public struct ProvenancePresentation: Sendable, Equatable {
    public let assetID: String
    public let verdict: ProvenanceVerdict
    public let statement: TrustStatement
    public let report: DiffReport?
    public let needsRevocationRecheck: Bool

    public init(
        assetID: String,
        verdict: ProvenanceVerdict,
        statement: TrustStatement,
        report: DiffReport?,
        needsRevocationRecheck: Bool
    ) {
        self.assetID = assetID
        self.verdict = verdict
        self.statement = statement
        self.report = report
        self.needsRevocationRecheck = needsRevocationRecheck
    }
}

/// The facade the UI talks to.
///
/// Deliberately thin. Everything interesting — coalescing, retry, the cache, the copy
/// policy — lives in a type that can be tested without it, and this exists only so a
/// view model has one dependency instead of five.
public actor ProvenanceInspector {

    private let coordinator: AuthenticationCoordinator
    private let registry: TrustRegistry
    private let storefront: Storefront
    private let device: DeviceProfile
    private var reports: [String: DiffReport] = [:]
    private let reportCapacity: Int
    private var reportRecency: [String] = []

    public init(
        coordinator: AuthenticationCoordinator,
        registry: TrustRegistry,
        storefront: Storefront,
        device: DeviceProfile,
        reportCapacity: Int = 128
    ) {
        self.coordinator = coordinator
        self.registry = registry
        self.storefront = storefront
        self.device = device
        self.reportCapacity = max(1, reportCapacity)
    }

    public var capability: ProvenanceCapability {
        AvailabilityMatrix.capability(storefront: storefront, device: device)
    }

    /// Hot path. Returns immediately from cache; never contacts the service.
    public func presentation(for assetID: String) async -> ProvenancePresentation {
        if let gated = AvailabilityMatrix.gatedVerdict(storefront: storefront, device: device) {
            return presentation(assetID: assetID, verdict: gated, needsRecheck: false)
        }
        guard let display = await registry.display(assetID: assetID) else {
            return presentation(assetID: assetID, verdict: .pendingDevelopment, needsRecheck: false)
        }
        return presentation(
            assetID: assetID,
            verdict: display.verdict,
            needsRecheck: display.needsRevocationRecheck
        )
    }

    /// User-initiated. This is the only call that may contact the service.
    ///
    /// The heatmap stored here comes from the coordinator's own outcome, which computed
    /// it against the reference plane the verdict was derived from. Recomputing it here
    /// against a plane the caller happened to be holding is how a badge and the picture
    /// beside it end up describing different comparisons.
    @discardableResult
    public func authenticate(
        assetID: String,
        capture: CaptureDescriptor,
        derivative: GrayscaleBuffer
    ) async -> ProvenancePresentation {
        if let gated = AvailabilityMatrix.gatedVerdict(storefront: storefront, device: device) {
            return presentation(assetID: assetID, verdict: gated, needsRecheck: false)
        }

        let outcome = await coordinator.authenticate(
            AuthenticationRequest(capture: capture, derivative: derivative)
        )
        if let report = outcome.report {
            storeReport(report, for: assetID)
        }
        return presentation(assetID: assetID, verdict: outcome.verdict, needsRecheck: false)
    }

    @discardableResult
    public func sweepRevocations() async -> [String] {
        await coordinator.sweepRevocations()
    }

    public func report(for assetID: String) -> DiffReport? { reports[assetID] }

    public func storeReport(_ report: DiffReport, for assetID: String) {
        reports[assetID] = report
        reportRecency.removeAll { $0 == assetID }
        reportRecency.append(assetID)
        while reports.count > reportCapacity, !reportRecency.isEmpty {
            let oldest = reportRecency.removeFirst()
            reports.removeValue(forKey: oldest)
        }
    }

    private func presentation(
        assetID: String,
        verdict: ProvenanceVerdict,
        needsRecheck: Bool
    ) -> ProvenancePresentation {
        ProvenancePresentation(
            assetID: assetID,
            verdict: verdict,
            statement: TrustLanguage.statement(for: verdict),
            report: reports[assetID],
            needsRevocationRecheck: needsRecheck
        )
    }
}
