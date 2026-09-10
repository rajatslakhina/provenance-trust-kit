import Foundation

/// User-facing copy for a verdict, split so a caller cannot render the headline
/// without also having the disclosure available.
public struct TrustStatement: Sendable, Equatable {
    public let headline: String
    public let detail: String
    /// The limitation that must be rendered somewhere reachable. Never optional.
    public let disclosure: String

    public init(headline: String, detail: String, disclosure: String) {
        self.headline = headline
        self.detail = detail
        self.disclosure = disclosure
    }
}

public struct TrustLanguageViolation: Sendable, Equatable, CustomStringConvertible {
    public let phrase: String
    public let field: String

    public var description: String { "\(field) contains prohibited claim \"\(phrase)\"" }
}

/// The copy policy, enforced in code rather than in a style guide nobody reads.
///
/// The system can attest that a particular sensor produced particular data at a
/// particular time. It cannot attest that the scene was not staged, that the caption is
/// accurate, or that the image is "real". Every phrase below is one a product or growth
/// team will eventually propose, and each one converts a narrow, defensible claim into
/// an indefensible one — which matters most in exactly the case the copy is meant to
/// cover: a revoked attestation on a photo a user already acted on.
public enum TrustLanguage {

    /// Matched case-insensitively against every field of a statement.
    public static let prohibitedClaims: [String] = [
        "authentic",
        "genuine",
        "this is real",
        "proves",
        "proof that",
        "guaranteed",
        "cannot be faked",
        "not ai",
        "not generated",
        "unedited",
        "untampered",
        "certified true",
    ]

    public static func statement(for verdict: ProvenanceVerdict) -> TrustStatement {
        switch verdict {
        case .unsigned:
            return TrustStatement(
                headline: "No capture record",
                detail: "This image arrived without signed camera data.",
                disclosure: "Most images have no capture record. Its absence says nothing about the image."
            )

        case .pendingDevelopment:
            return TrustStatement(
                headline: "Capture record not checked yet",
                detail: "Signed camera data is attached. Checking it contacts Apple's service.",
                disclosure: "Checking is optional and happens only when you ask."
            )

        case .verified(let reference, let matchScore):
            return TrustStatement(
                headline: "Camera record matches",
                detail: "The sensor recorded this scene, and this copy still matches that record "
                    + "(similarity \(formattedScore(matchScore))). Record \(reference.rawValue).",
                disclosure: "Describes what the sensor recorded, not whether the scene or the caption is accurate. "
                    + "Apple can withdraw this record later."
            )

        case .mismatch(let reference, let matchScore):
            return TrustStatement(
                headline: "Copy differs from camera record",
                detail: "A camera record exists, but this copy has diverged from it "
                    + "(similarity \(formattedScore(matchScore))). Record \(reference.rawValue).",
                disclosure: "Cropping, filters and re-compression all cause this. It does not by itself indicate intent."
            )

        case .revoked(let reference, let reason):
            return TrustStatement(
                headline: "Camera record withdrawn",
                detail: "Apple withdrew the record for this image (\(reasonPhrase(reason))). Record \(reference.rawValue).",
                disclosure: "A record shown earlier may have been based on this withdrawn attestation."
            )

        case .unavailable(let reason):
            return TrustStatement(
                headline: "Capture records unavailable here",
                detail: unavailabilityPhrase(reason),
                disclosure: "Availability depends on region, device and system version."
            )
        }
    }

    /// Returns every prohibited claim found. Empty means the statement is within policy.
    public static func validate(_ statement: TrustStatement) -> [TrustLanguageViolation] {
        let fields: [(String, String)] = [
            ("headline", statement.headline),
            ("detail", statement.detail),
            ("disclosure", statement.disclosure),
        ]
        var violations: [TrustLanguageViolation] = []
        for (field, text) in fields {
            let lowered = text.lowercased()
            for phrase in prohibitedClaims where lowered.contains(phrase) {
                violations.append(TrustLanguageViolation(phrase: phrase, field: field))
            }
        }
        return violations
    }

    private static func formattedScore(_ score: Double) -> String {
        let clamped = SafeArithmetic.unitClamped(score)
        // `Int(...)` on a Double that could be NaN would trap; `clampedInt` is why it
        // cannot. `unitClamped` already handles NaN, but the conversion is still routed
        // through the saturating helper so the safety does not depend on call ordering.
        let percent = SafeArithmetic.clampedInt((clamped * 100).rounded())
        return "\(percent)%"
    }

    private static func reasonPhrase(_ reason: RevocationReason) -> String {
        switch reason {
        case .sensorCompromised: return "the camera that signed it is no longer trusted"
        case .attestationExpired: return "the record is no longer readable by the service"
        case .policyWithdrawn: return "it was withdrawn by policy"
        }
    }

    private static func unavailabilityPhrase(_ reason: UnavailabilityReason) -> String {
        switch reason {
        case .regionUnavailable: return "Capture records are not offered in this region."
        case .osTooOld: return "This system version cannot read capture records."
        case .captureDeviceUnsupported: return "This device cannot create capture records."
        case .developingServiceUnreachable: return "Apple's service could not be reached."
        case .developingServiceTimedOut: return "Apple's service did not respond in time."
        case .userOptedOut: return "Capture records are turned off for this account."
        }
    }
}
