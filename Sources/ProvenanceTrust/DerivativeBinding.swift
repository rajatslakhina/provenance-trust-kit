import Foundation

/// One transform applied between the reference and the bytes actually served.
public struct TransformStep: Sendable, Equatable, Codable {
    public let kind: String
    public let parameters: [String: String]

    public init(kind: String, parameters: [String: String] = [:]) {
        self.kind = kind
        self.parameters = parameters
    }
}

/// The out-of-band record that survives a media pipeline.
///
/// Resizing and transcoding strip metadata — that is the pipeline working as designed,
/// not a bug to fix. So the binding cannot live *in* the file. It travels beside it as
/// a signed sidecar that names the reference, pins the exact derivative bytes by
/// content hash, and records the transform chain that produced them.
public struct ProvenanceSidecar: Sendable, Equatable, Codable {
    public let referenceID: String
    /// Lowercase hex SHA-256 of the derivative bytes as served.
    public let derivativeDigest: String
    public let transformChain: [TransformStep]
    public let issuedAt: Date
    /// Lowercase hex HMAC-SHA-256 over `canonicalBytes`.
    public let signature: String

    /// Deterministic byte encoding used for signing and verification.
    ///
    /// Every variable-length field is length-prefixed and every dictionary is key-sorted.
    /// Naive concatenation is the classic hole here: `["a": "bc"]` and `["ab": "c"]`
    /// flatten to the same string, so one signature would validate two different
    /// transform chains. `SidecarTests.testCanonicalEncodingIsUnambiguousWhereNaiveConcatenationIsNot`
    /// pins that case.
    static func canonicalBytes(
        referenceID: String,
        derivativeDigest: String,
        transformChain: [TransformStep],
        issuedAt: Date
    ) -> [UInt8] {
        var output = [UInt8]()

        func appendField(_ string: String) {
            let bytes = Array(string.utf8)
            // 4-byte big-endian length prefix; `bytes.count` fits because a sidecar
            // field is never near 4 GiB, and `truncatingIfNeeded` cannot trap even so.
            let length = UInt32(truncatingIfNeeded: bytes.count)
            output.append(UInt8(truncatingIfNeeded: length >> 24))
            output.append(UInt8(truncatingIfNeeded: length >> 16))
            output.append(UInt8(truncatingIfNeeded: length >> 8))
            output.append(UInt8(truncatingIfNeeded: length))
            output.append(contentsOf: bytes)
        }

        appendField("provenance-sidecar-v1")
        appendField(referenceID)
        appendField(derivativeDigest)
        // Whole seconds since the epoch, rendered without locale or formatter, so the
        // signed bytes do not change with the device's calendar settings.
        appendField(String(SafeArithmetic.clampedInt(issuedAt.timeIntervalSince1970.rounded())))
        appendField(String(transformChain.count))
        for step in transformChain {
            appendField(step.kind)
            appendField(String(step.parameters.count))
            for key in step.parameters.keys.sorted() {
                appendField(key)
                appendField(step.parameters[key] ?? "")
            }
        }
        return output
    }

    var canonicalBytes: [UInt8] {
        Self.canonicalBytes(
            referenceID: referenceID,
            derivativeDigest: derivativeDigest,
            transformChain: transformChain,
            issuedAt: issuedAt
        )
    }
}

public enum SidecarVerification: Sendable, Equatable {
    case valid(ReferenceID)
    /// The bytes served are not the bytes that were signed.
    case digestMismatch(expected: String, actual: String)
    /// The sidecar was not signed by the expected key, or was altered after signing.
    case signatureInvalid
    /// The sidecar names a reference the client cannot use.
    case malformedReference

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Issues sidecars. In production the key is the upload service's, not the client's —
/// the client never holds a signing key, it only verifies.
public struct SidecarSigner: Sendable {
    private let key: [UInt8]

    public init(key: [UInt8]) {
        self.key = key
    }

    public func sign(
        referenceID: ReferenceID,
        derivativeBytes: [UInt8],
        transformChain: [TransformStep],
        issuedAt: Date
    ) -> ProvenanceSidecar {
        let digest = Digest.hex(Digest.sha256(derivativeBytes))
        let canonical = ProvenanceSidecar.canonicalBytes(
            referenceID: referenceID.rawValue,
            derivativeDigest: digest,
            transformChain: transformChain,
            issuedAt: issuedAt
        )
        let signature = Digest.hex(Digest.hmacSHA256(key: key, message: canonical))
        return ProvenanceSidecar(
            referenceID: referenceID.rawValue,
            derivativeDigest: digest,
            transformChain: transformChain,
            issuedAt: issuedAt,
            signature: signature
        )
    }
}

public struct SidecarVerifier: Sendable {
    private let key: [UInt8]

    public init(key: [UInt8]) {
        self.key = key
    }

    /// Order matters: the signature is checked **before** the digest.
    ///
    /// Checking the digest first would let an attacker who cannot forge a signature
    /// still learn, from which error came back, whether a given byte string matches the
    /// digest in a sidecar they intercepted. Signature first means an unsigned sidecar
    /// is rejected without revealing anything about its contents.
    public func verify(_ sidecar: ProvenanceSidecar, derivativeBytes: [UInt8]) -> SidecarVerification {
        guard let expectedSignature = Digest.bytes(fromHex: sidecar.signature) else {
            return .signatureInvalid
        }
        let actualSignature = Digest.hmacSHA256(key: key, message: sidecar.canonicalBytes)
        guard Digest.constantTimeEquals(expectedSignature, actualSignature) else {
            return .signatureInvalid
        }

        let actualDigest = Digest.hex(Digest.sha256(derivativeBytes))
        guard actualDigest == sidecar.derivativeDigest else {
            return .digestMismatch(expected: sidecar.derivativeDigest, actual: actualDigest)
        }

        guard let reference = ReferenceID(sidecar.referenceID) else {
            return .malformedReference
        }
        return .valid(reference)
    }
}
