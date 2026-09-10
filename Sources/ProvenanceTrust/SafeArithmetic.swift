import Foundation

/// Saturating conversions for values that originate in floating-point maths.
///
/// Swift does not wrap or clamp on a bad `Int(Double)` conversion — it traps. `Int(.nan)`,
/// `Int(.infinity)` and `Int(1e300)` are all crashes, as are `Int.max + 1`, `x / 0`,
/// `x % 0` and `Int.min / -1`. Every match score, SSIM value and block count in this
/// package is derived from `Double` arithmetic that an adversarial derivative image can
/// influence, so those conversions are reachable through the public API. Rather than
/// scattering `guard` statements at each call site, all of them route through here.
public enum SafeArithmetic {

    /// Smallest `Double` at or above which conversion to `Int` is unsafe.
    ///
    /// Derived from `Int.max`, never hardcoded as a 64-bit literal: `Int` is 32-bit on
    /// some Apple platforms, and a hardcoded `9.223e18` would silently stop protecting
    /// anything there. Note `Double(Int.max)` rounds *up* to 2^63 on 64-bit platforms,
    /// which is why the comparison below is `>=` and not `>`.
    public static let unsafeUpperBound = Double(Int.max)

    /// Largest `Double` at or below which conversion to `Int` is unsafe.
    /// `Double(Int.min)` is exactly representable (it is a power of two), so `<=` is
    /// conservative by exactly one representable value and never wrong.
    public static let unsafeLowerBound = Double(Int.min)

    /// Converts to any fixed-width integer, clamping instead of trapping.
    ///
    /// Generic on purpose: the bounds are derived from `T.max`/`T.min` rather than
    /// written as 64-bit literals, and making the width a parameter is what lets a test
    /// prove the derivation. `SafeArithmeticTests.testClampingIsDerivedFromTheTargetWidth`
    /// runs it at `Int32` and `Int8`, where a hardcoded 2^63 bound is visibly wrong —
    /// on a 64-bit `Int` the two are indistinguishable, so an `Int`-only test could not
    /// catch the mistake this API exists to prevent. It matters because `Int` is 32-bit
    /// on some Apple platforms.
    @inlinable
    public static func clamped<T: FixedWidthInteger>(_ value: Double, as type: T.Type, whenNaN: T = 0) -> T {
        if value.isNaN { return whenNaN }
        // `Double(T.max)` may round *up* past `T.max` (it does for `Int64`), which is
        // why these comparisons are `>=` and `<=` rather than `>` and `<`.
        if value >= Double(T.max) { return T.max }
        if value <= Double(T.min) { return T.min }
        return T(value)
    }

    /// Converts to `Int`, clamping instead of trapping. NaN maps to `zeroForNaN`.
    @inlinable
    public static func clampedInt(_ value: Double, zeroForNaN: Int = 0) -> Int {
        clamped(value, as: Int.self, whenNaN: zeroForNaN)
    }

    /// Division that yields `fallback` rather than NaN/infinity/trap on a bad denominator.
    @inlinable
    public static func ratio(_ numerator: Double, _ denominator: Double, fallback: Double = 0) -> Double {
        guard denominator.isFinite, denominator != 0, numerator.isFinite else { return fallback }
        let result = numerator / denominator
        return result.isFinite ? result : fallback
    }

    /// Integer division guarding both `/ 0` and the `Int.min / -1` overflow trap.
    @inlinable
    public static func dividing(_ lhs: Int, by rhs: Int, fallback: Int = 0) -> Int {
        guard rhs != 0 else { return fallback }
        let (quotient, overflow) = lhs.dividedReportingOverflow(by: rhs)
        return overflow ? fallback : quotient
    }

    /// Remainder guarding both `% 0` and the `Int.min % -1` overflow trap.
    @inlinable
    public static func remainder(_ lhs: Int, _ rhs: Int, fallback: Int = 0) -> Int {
        guard rhs != 0 else { return fallback }
        let (value, overflow) = lhs.remainderReportingOverflow(dividingBy: rhs)
        return overflow ? fallback : value
    }

    @inlinable
    public static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? Int.max : Int.min
    }

    @inlinable
    public static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return product }
        let negative = (lhs < 0) != (rhs < 0)
        return negative ? Int.min : Int.max
    }

    /// Clamps a score to the unit interval, mapping NaN to `0`.
    @inlinable
    public static func unitClamped(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return Swift.min(1, Swift.max(0, value))
    }
}
