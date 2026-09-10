import Foundation

/// A validated 8-bit luminance plane.
///
/// Deliberately a value type with a failable initialiser rather than a bag of
/// `(width, height, pointer)` parameters: every downstream algorithm indexes it in a
/// nested loop, and the cheapest place to prove `y * width + x` is in range is once, at
/// construction, instead of at several million call sites.
public struct GrayscaleBuffer: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    /// Fails if the dimensions are non-positive, if `width * height` overflows, or if
    /// the pixel count disagrees with the dimensions.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0 else { return nil }
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, area == pixels.count else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Bounds-checked access. Returns `nil` outside the plane rather than trapping.
    @inlinable
    public func pixel(x: Int, y: Int) -> UInt8? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return pixels[y * width + x]
    }

    /// Bounds-clamped access, for resamplers that legitimately want edge extension.
    @inlinable
    public func clampedPixel(x: Int, y: Int) -> UInt8 {
        let cx = Swift.min(Swift.max(x, 0), width - 1)
        let cy = Swift.min(Swift.max(y, 0), height - 1)
        return pixels[cy * width + cx]
    }

    public var pixelCount: Int { pixels.count }

    /// Largest edge length `solid(width:height:value:)` will allocate.
    /// Callers that legitimately need a larger plane already have the pixels, so they
    /// use the failable initialiser and supply their own storage.
    public static let maximumSolidEdge = 4096

    private init(checkedWidth: Int, checkedHeight: Int, checkedPixels: [UInt8]) {
        self.width = checkedWidth
        self.height = checkedHeight
        self.pixels = checkedPixels
    }

    /// Non-failable constructor for a uniform plane.
    ///
    /// Exists so that fixture and fallback paths never need a force-unwrap: dimensions
    /// are clamped into `1...maximumSolidEdge`, which makes both failure modes of the
    /// failable initialiser unreachable by construction.
    public static func solid(width: Int, height: Int, value: UInt8) -> GrayscaleBuffer {
        let clampedWidth = Swift.min(Swift.max(width, 1), maximumSolidEdge)
        let clampedHeight = Swift.min(Swift.max(height, 1), maximumSolidEdge)
        let area = clampedWidth * clampedHeight  // <= 4096 * 4096, cannot overflow Int32 or Int64
        return GrayscaleBuffer(
            checkedWidth: clampedWidth,
            checkedHeight: clampedHeight,
            checkedPixels: [UInt8](repeating: value, count: area)
        )
    }
}
