import Foundation

/// What the client holds at capture time, before anything has been developed.
public struct CaptureDescriptor: Sendable, Hashable {
    public let assetID: String
    /// Opaque signature bytes produced by the sensor.
    public let sensorSignature: [UInt8]
    public let captureTime: Date
    /// Identifies the signing hardware. Revocation is keyed on this, not on the
    /// reference: when a sensor is found to be compromised, *every* attestation it ever
    /// produced is withdrawn at once.
    public let hardwareIdentifier: String

    public init(assetID: String, sensorSignature: [UInt8], captureTime: Date, hardwareIdentifier: String) {
        self.assetID = assetID
        self.sensorSignature = sensorSignature
        self.captureTime = captureTime
        self.hardwareIdentifier = hardwareIdentifier
    }

    /// Stable key for de-duplicating a retried develop call.
    ///
    /// A develop request that times out may well have succeeded server-side. Retrying
    /// without a key mints a second reference for one capture, and then the two
    /// disagree about which one a sidecar names. Hashing the signature rather than
    /// sending it twice also keeps the key stable across process launches.
    public var idempotencyKey: String {
        let material = Array(assetID.utf8)
            + Array(hardwareIdentifier.utf8)
            + sensorSignature
        return Digest.hex(Digest.sha256(material))
    }
}

/// The developed "digital negative" plus the identity the service assigned it.
public struct ReferenceRecord: Sendable, Equatable {
    public let referenceID: ReferenceID
    public let hardwareIdentifier: String
    public let developedAt: Date
    /// Luminance plane of the reference, used for perceptual comparison. The real API
    /// hands back an image; this package only ever needs its luminance.
    public let referencePlane: GrayscaleBuffer

    public init(
        referenceID: ReferenceID,
        hardwareIdentifier: String,
        developedAt: Date,
        referencePlane: GrayscaleBuffer
    ) {
        self.referenceID = referenceID
        self.hardwareIdentifier = hardwareIdentifier
        self.developedAt = developedAt
        self.referencePlane = referencePlane
    }
}

public enum RevocationState: Sendable, Equatable {
    case valid
    case revoked(RevocationReason)
}

public enum ProviderError: Error, Sendable, Equatable {
    case timedOut
    case offline
    case regionUnavailable
    case sensorRejected
    /// Retryable server-side failure.
    case transient(code: Int)

    public var isRetryable: Bool {
        switch self {
        case .timedOut, .transient: return true
        case .offline, .regionUnavailable, .sensorRejected: return false
        }
    }
}

/// The one seam between this package and the platform API.
///
/// Everything above this protocol is testable on any platform; everything below it is
/// an OS version and a device away. The API surface is thinly documented and ships
/// after this package does, so the adapter is the only thing that has to change when it
/// lands — the pipeline, the cache and the copy policy do not.
public protocol ReferenceImageProvider: Sendable {
    /// Lazy authentication: contacts the developing service. Never called at capture.
    func developReference(for capture: CaptureDescriptor) async throws -> ReferenceRecord
    /// Batched revocation check. Batched because it runs off the hot path on a timer,
    /// and one round trip for the visible set beats one per badge.
    func revocationStates(for references: [ReferenceID]) async throws -> [ReferenceID: RevocationState]
}
