import Foundation

/// Identifier the developing service returns for a developed reference image.
public struct ReferenceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Fails rather than traps on an empty or whitespace-only identifier: this value
    /// arrives from a network response and is used as a cache key and a revocation
    /// join key, so an empty one would silently collapse distinct assets together.
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

/// Why an attestation was withdrawn after it had already been granted.
public enum RevocationReason: String, Sendable, Equatable, Codable, CaseIterable {
    /// The signing sensor was found to be compromised; every past authentication from
    /// that hardware is withdrawn retroactively.
    case sensorCompromised
    /// The developing service no longer recognises the signature format.
    case attestationExpired
    /// Withdrawn by policy (legal hold, regional change) rather than by evidence.
    case policyWithdrawn
}

/// Why no verdict can be produced at all.
public enum UnavailabilityReason: String, Sendable, Equatable, Codable, CaseIterable {
    case regionUnavailable
    case osTooOld
    case captureDeviceUnsupported
    case developingServiceUnreachable
    case developingServiceTimedOut
    case userOptedOut
}

/// Coarse trust bucket. UI colour, sort order and analytics bucket off this rather
/// than pattern-matching the verdict, so adding a case does not touch every call site.
public enum TrustTier: Int, Sendable, Comparable, CaseIterable {
    case withdrawn = 0
    case contradicted = 1
    case none = 2
    case provisional = 3
    case attested = 4

    public static func < (lhs: TrustTier, rhs: TrustTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The state of a single asset's provenance claim.
///
/// The important property is that `verified` is **not terminal**. Apple can withdraw a
/// sensor's authentications retroactively, so a claim that was true when it was cached
/// can become false with no user action and no new capture. Modelling this as a plain
/// `Bool isVerified` is the bug this whole package exists to prevent.
public enum ProvenanceVerdict: Sendable, Equatable {
    /// No signed sensor data accompanies the asset.
    case unsigned
    /// Signed at capture; the reference has not been developed yet. Authentication is
    /// lazy, so most assets sit here until a user actually asks.
    case pendingDevelopment
    /// Developed, and the derivative still matches the reference within tolerance.
    case verified(reference: ReferenceID, matchScore: Double)
    /// Developed, but the derivative has diverged from the reference beyond tolerance.
    case mismatch(reference: ReferenceID, matchScore: Double)
    /// The attestation was withdrawn after the fact.
    case revoked(reference: ReferenceID, reason: RevocationReason)
    /// Gating or infrastructure prevents a verdict.
    case unavailable(reason: UnavailabilityReason)

    public var trustTier: TrustTier {
        switch self {
        case .revoked: return .withdrawn
        case .mismatch: return .contradicted
        case .unsigned, .unavailable: return .none
        case .pendingDevelopment: return .provisional
        case .verified: return .attested
        }
    }

    /// The reference this verdict is about, when it has one.
    public var referenceID: ReferenceID? {
        switch self {
        case .verified(let reference, _), .mismatch(let reference, _), .revoked(let reference, _):
            return reference
        case .unsigned, .pendingDevelopment, .unavailable:
            return nil
        }
    }

    /// Whether a caller may act on this verdict without a fresh revocation check.
    /// Only `attested` claims are worth re-checking; everything else is already
    /// at or below the trust floor, so a stale answer cannot over-claim.
    public var requiresRevocationRecheck: Bool { trustTier == .attested }
}

/// Why a proposed verdict transition was rejected.
public enum TransitionRejection: String, Sendable, Equatable {
    /// Trust was withdrawn; only an explicit re-development may leave this state.
    case revocationIsSticky
    /// A verdict cannot become `verified` without passing through development.
    case skippedDevelopment
    /// The reference identity changed underneath an existing claim.
    case referenceIdentityChanged
}

extension ProvenanceVerdict {
    /// Validates a proposed state change.
    ///
    /// Three rules, each of which corresponds to a real failure a naive client hits:
    ///
    /// 1. **Revocation is sticky.** Once withdrawn, a claim may not drift back up to
    ///    `verified` because a later cache write happened to carry an older, cheerier
    ///    answer. Leaving `revoked` requires `TrustRegistry.reauthorize`, which is a
    ///    deliberate, auditable call — not an incidental cache refresh.
    /// 2. **No skipped development.** `unsigned → verified` would mean the client
    ///    invented an attestation it never asked the service for.
    /// 3. **Reference identity is stable.** A claim about reference A may not silently
    ///    become a claim about reference B; that is how one asset's badge ends up
    ///    describing a different asset's negative.
    public static func rejection(
        movingFrom current: ProvenanceVerdict,
        to proposed: ProvenanceVerdict
    ) -> TransitionRejection? {
        if current == proposed { return nil }

        if case .revoked = current {
            // Re-revoking with a different reason is a legitimate update.
            if case .revoked = proposed { return nil }
            return .revocationIsSticky
        }

        switch (current, proposed) {
        case (.unsigned, .verified), (.unsigned, .mismatch):
            return .skippedDevelopment
        default:
            break
        }

        if let currentReference = current.referenceID,
           let proposedReference = proposed.referenceID,
           currentReference != proposedReference {
            return .referenceIdentityChanged
        }

        return nil
    }

    public static func canTransition(from current: ProvenanceVerdict, to proposed: ProvenanceVerdict) -> Bool {
        rejection(movingFrom: current, to: proposed) == nil
    }
}
