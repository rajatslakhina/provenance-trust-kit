import Foundation

/// Deterministic synthetic imagery.
///
/// Deterministic on purpose: a fixture built from `Double.random` gives a test that
/// passes 95% of the time, which is worse than no test. The generator below is a fixed
/// linear congruential sequence, so every run — and every platform — sees identical
/// pixels.
public enum DemoFixtures {

    public static let defaultEdge = 96

    /// A synthetic "scene": a diagonal luminance ramp with two blocks and a soft
    /// vignette, giving the DCT hash real structure to latch onto.
    public static func referenceScene(edge: Int = defaultEdge) -> GrayscaleBuffer {
        let size = min(max(edge, 8), 512)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let ramp = Double(x + y) / Double(max(1, 2 * (size - 1)))
                var value = 40 + ramp * 170

                if x >= size / 6, x < size / 6 + size / 4, y >= size / 5, y < size / 5 + size / 4 {
                    value += 45
                }
                if x >= size / 2, x < size / 2 + size / 3, y >= size / 2, y < size / 2 + size / 4 {
                    value -= 35
                }

                let dx = Double(x) - Double(size) / 2
                let dy = Double(y) - Double(size) / 2
                let radius = (dx * dx + dy * dy).squareRoot()
                let vignette = SafeArithmetic.ratio(radius, Double(size), fallback: 0)
                value -= vignette * 25

                pixels[y * size + x] = UInt8(SafeArithmetic.clampedInt(min(255, max(0, value))))
            }
        }
        return GrayscaleBuffer(width: size, height: size, pixels: pixels)
            ?? .solid(width: size, height: size, value: 128)
    }

    /// What an upload pipeline does to an untouched photo: resample and re-quantise.
    /// Structurally the same image, byte-for-byte a different one — which is precisely
    /// why the binding is a content hash in a sidecar and not a metadata field.
    public static func pipelineDerivative(of reference: GrayscaleBuffer, quantisation: Int = 6) -> GrayscaleBuffer {
        let step = max(1, min(quantisation, 64))
        var pixels = reference.pixels
        var generator = LinearCongruential(seed: 0x5EED_1234)
        for index in pixels.indices {
            let quantised = SafeArithmetic.dividing(Int(pixels[index]), by: step, fallback: 0) * step
            // `next()` returns a `UInt64` that routinely exceeds `Int.max`, so a bare
            // `Int(_:)` on it traps. Reducing modulo 3 in `UInt64` first keeps the
            // conversion inside `Int`'s range on every platform, 32-bit included.
            let noise = Int(generator.next() % 3) - 1
            pixels[index] = UInt8(SafeArithmetic.clampedInt(Double(min(255, max(0, quantised + noise)))))
        }
        return GrayscaleBuffer(width: reference.width, height: reference.height, pixels: pixels)
            ?? reference
    }

    /// A small, local, deliberate edit: one patch overwritten with flat grey.
    /// This is the case a global similarity score averages into nothing.
    public static func locallyEditedDerivative(
        of reference: GrayscaleBuffer,
        patchOriginX: Int = 8,
        patchOriginY: Int = 8,
        patchEdge: Int = 28
    ) -> GrayscaleBuffer {
        var pixels = reference.pixels
        let edge = max(1, min(patchEdge, min(reference.width, reference.height)))
        let originX = min(max(patchOriginX, 0), reference.width - 1)
        let originY = min(max(patchOriginY, 0), reference.height - 1)
        let endX = min(originX + edge, reference.width)
        let endY = min(originY + edge, reference.height)

        for y in originY..<endY {
            for x in originX..<endX {
                let index = y * reference.width + x
                guard index >= 0, index < pixels.count else { continue }
                // Inverted, not blanked: a flat patch is trivially detectable, an
                // inversion preserves local contrast and is the harder case.
                pixels[index] = 255 &- pixels[index]
            }
        }
        return GrayscaleBuffer(width: reference.width, height: reference.height, pixels: pixels)
            ?? reference
    }

    /// Replaces a square region with that region's own average luminance.
    ///
    /// This is the shape of a removed object — content-aware fill, a patched-out licence
    /// plate, a scrubbed watermark. It is a harder case than an inversion precisely
    /// because it is *mean-preserving*: the perceptual hash does not move at all and the
    /// image-wide SSIM barely does, while the affected block loses its structure
    /// entirely. It is the fixture that makes `MatchPolicy.worstBlockFloor` decisive.
    public static func regionReplacedDerivative(
        of reference: GrayscaleBuffer,
        patchOriginX: Int = 40,
        patchOriginY: Int = 40,
        patchEdge: Int = 12
    ) -> GrayscaleBuffer {
        var pixels = reference.pixels
        let edge = max(1, min(patchEdge, min(reference.width, reference.height)))
        let originX = min(max(patchOriginX, 0), reference.width - 1)
        let originY = min(max(patchOriginY, 0), reference.height - 1)
        let endX = min(originX + edge, reference.width)
        let endY = min(originY + edge, reference.height)

        var total = 0
        var samples = 0
        for y in originY..<endY {
            for x in originX..<endX {
                let index = y * reference.width + x
                guard index >= 0, index < pixels.count else { continue }
                total = SafeArithmetic.saturatingAdd(total, Int(pixels[index]))
                samples += 1
            }
        }
        guard samples > 0 else { return reference }
        let average = UInt8(min(255, max(0, SafeArithmetic.dividing(total, by: samples, fallback: 0))))

        for y in originY..<endY {
            for x in originX..<endX {
                let index = y * reference.width + x
                guard index >= 0, index < pixels.count else { continue }
                pixels[index] = average
            }
        }
        return GrayscaleBuffer(width: reference.width, height: reference.height, pixels: pixels)
            ?? reference
    }

    public static func capture(
        assetID: String,
        hardwareIdentifier: String = "sensor-A",
        capturedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> CaptureDescriptor {
        // Seeded from the asset's bytes, never from `assetID.hashValue`: Swift seeds
        // `Hasher` randomly per process, so a `hashValue` seed would give a different
        // sensor signature — and therefore a different `idempotencyKey` and reference
        // ID — on every launch, which is the opposite of what a fixture is for.
        var generator = LinearCongruential(seed: stableSeed(for: assetID))
        let signature = (0..<32).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        return CaptureDescriptor(
            assetID: assetID,
            sensorSignature: signature,
            captureTime: capturedAt,
            hardwareIdentifier: hardwareIdentifier
        )
    }

    /// FNV-1a over the UTF-8 bytes. Not a hash for security or for `Hashable` — just a
    /// deterministic, process-independent way to turn a string into a seed.
    static func stableSeed(for text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash | 1
    }

    /// Fixed-seed LCG (Numerical Recipes constants). Not for anything security-bearing —
    /// it exists so fixtures are byte-identical on every run.
    struct LinearCongruential {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        /// Returns the high bits: the low bits of an LCG have short periods, and the
        /// fixtures reduce the output modulo small numbers.
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state &>> 17
        }
    }
}
