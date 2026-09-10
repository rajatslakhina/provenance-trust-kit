import Foundation

/// The App Store storefront the user is in. Capture availability is storefront-gated
/// independently of device and OS, which is why this is a separate axis rather than a
/// flag on the device profile.
public enum Storefront: String, Sendable, Equatable, Codable, CaseIterable {
    case unitedStates
    case europeanUnion
    case china
    case restOfWorld
}

public struct DeviceProfile: Sendable, Equatable, Codable {
    /// Whether this device has a camera sensor that signs its data at capture time.
    public let hasSigningSensor: Bool
    /// Major OS version. Viewing and developing require the OS that ships the API,
    /// even on hardware that cannot capture.
    public let osMajorVersion: Int
    /// The user-level opt-in. Provenance is opt-in, not on by default.
    public let userOptedIn: Bool

    public init(hasSigningSensor: Bool, osMajorVersion: Int, userOptedIn: Bool = true) {
        self.hasSigningSensor = hasSigningSensor
        self.osMajorVersion = osMajorVersion
        self.userOptedIn = userOptedIn
    }
}

/// What a given (storefront, device) pair can actually do.
public enum ProvenanceCapability: Sendable, Equatable {
    /// Can sign at capture, develop a reference, and view one.
    case captureDevelopAndView
    /// Cannot originate signed captures, but can develop and view references that
    /// arrived from elsewhere. This is the EU-at-launch shape, and it is the case
    /// most clients get wrong by disabling the whole feature.
    case developAndViewOnly
    /// Nothing is available; render no badge at all rather than a negative one.
    case unsupported(UnavailabilityReason)

    public var canCapture: Bool { self == .captureDevelopAndView }

    public var canDevelop: Bool {
        switch self {
        case .captureDevelopAndView, .developAndViewOnly: return true
        case .unsupported: return false
        }
    }
}

/// Region x device x OS gating, as a pure function.
///
/// Written as a total function over `Storefront` rather than a chain of `if` statements
/// so that adding a storefront is a compiler error rather than a silent default.
public enum AvailabilityMatrix {

    /// The OS major version that first exposes the third-party viewing API.
    public static let minimumOSMajorVersion = 27

    public static func capability(storefront: Storefront, device: DeviceProfile) -> ProvenanceCapability {
        guard device.osMajorVersion >= minimumOSMajorVersion else {
            return .unsupported(.osTooOld)
        }
        guard device.userOptedIn else {
            return .unsupported(.userOptedOut)
        }

        switch storefront {
        case .china:
            // Not offered at all. Distinct from "device cannot capture": there is
            // nothing to view either, so the UI should show no provenance affordance.
            return .unsupported(.regionUnavailable)
        case .europeanUnion:
            // Capture is unavailable at launch; developing and viewing are not.
            return .developAndViewOnly
        case .unitedStates, .restOfWorld:
            return device.hasSigningSensor ? .captureDevelopAndView : .developAndViewOnly
        }
    }

    /// The verdict to show when the capability itself forbids producing one.
    /// Returns `nil` when a real verdict should be computed instead.
    public static func gatedVerdict(storefront: Storefront, device: DeviceProfile) -> ProvenanceVerdict? {
        switch capability(storefront: storefront, device: device) {
        case .unsupported(let reason):
            return .unavailable(reason: reason)
        case .captureDevelopAndView, .developAndViewOnly:
            return nil
        }
    }
}
