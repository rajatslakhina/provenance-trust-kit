import Foundation

/// One cell of the "what changed" heatmap.
public struct BlockScore: Sendable, Equatable {
    public let column: Int
    public let row: Int
    /// Structural similarity in `[0, 1]`; 1 means indistinguishable.
    public let similarity: Double

    public init(column: Int, row: Int, similarity: Double) {
        self.column = column
        self.row = row
        self.similarity = similarity
    }
}

/// The result of comparing a derivative against its reference.
public struct DiffReport: Sendable, Equatable {
    /// Hamming distance between the two 64-bit perceptual hashes, `0...64`.
    public let hashDistance: Int
    /// Mean structural similarity across all blocks, `[0, 1]`.
    public let meanSimilarity: Double
    /// Similarity of the single worst block — the number that actually catches a small,
    /// deliberate, local edit that a global mean would average away.
    public let worstBlockSimilarity: Double
    /// Row-major heatmap cells.
    public let blocks: [BlockScore]
    /// How similar the two images are **overall**, `[0, 1]`.
    ///
    /// Deliberately global-only: the mean of the two whole-image signals, with no term
    /// for the worst block. Weighting the worst block into this number would make the
    /// separate `MatchPolicy.worstBlockFloor` unreachable — a low worst block would drag
    /// the score under the threshold before the floor ever got a chance to fire, and the
    /// floor would be dead code that a README nonetheless bragged about. Two independent
    /// questions get two independent numbers: *how similar overall* and *is any single
    /// region destroyed*.
    public let matchScore: Double

    public init(
        hashDistance: Int,
        meanSimilarity: Double,
        worstBlockSimilarity: Double,
        blocks: [BlockScore],
        matchScore: Double
    ) {
        self.hashDistance = hashDistance
        self.meanSimilarity = meanSimilarity
        self.worstBlockSimilarity = worstBlockSimilarity
        self.blocks = blocks
        self.matchScore = matchScore
    }

    /// The worst block, or `nil` when the grid is empty.
    public var worstBlock: BlockScore? {
        blocks.min(by: { $0.similarity < $1.similarity })
    }
}

/// Perceptual comparison, in pure Swift with no imaging framework dependency.
///
/// Two independent signals, because each one fails differently:
///
/// * A **DCT perceptual hash** is robust to re-encoding and scaling — exactly the
///   transforms an upload pipeline applies — but it is a 64-bit summary, so a small
///   local edit can leave it untouched.
/// * **Block-wise SSIM** is sensitive to local structural change and is what produces
///   the heatmap, but it is not scale-invariant, so it needs the resample first.
///
/// Using either alone gives a confident wrong answer on the other's blind spot.
public enum PerceptualDiff {

    /// Hash working size. 32x32 feeds a 2D DCT whose top-left 8x8 block is the hash.
    public static let hashWorkingSize = 8 * 4
    /// SSIM working size. Both images are resampled to this before comparison so the
    /// grid is stable regardless of the derivative's actual dimensions.
    public static let similarityWorkingSize = 64

    // SSIM stabilisers for 8-bit data (L = 255).
    private static let dynamicRange: Double = 255
    private static let c1: Double = (0.01 * dynamicRange) * (0.01 * dynamicRange)
    private static let c2: Double = (0.03 * dynamicRange) * (0.03 * dynamicRange)

    // MARK: - Perceptual hash

    /// 64-bit DCT hash. Never fails: the buffer is already validated non-empty.
    public static func perceptualHash(_ buffer: GrayscaleBuffer) -> UInt64 {
        let n = hashWorkingSize
        let resampled = boxResample(buffer, to: n, height: n)
        let coefficients = dct2D(resampled, size: n)

        // Top-left 8x8 coefficients. The DC term at index 0 is included in the hashed
        // bits but excluded from the median below, so overall brightness does not drag
        // every bit in one direction.
        var values: [Double] = []
        values.reserveCapacity(64)
        for row in 0..<8 {
            for column in 0..<8 {
                values.append(coefficients[row * n + column])
            }
        }
        guard values.count == 64 else { return 0 }

        let median = medianExcludingDC(values)
        var hash: UInt64 = 0
        for (index, value) in values.enumerated() where value > median {
            hash |= (UInt64(1) << UInt64(index))
        }
        return hash
    }

    /// `0...64`.
    public static func hashDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    // MARK: - Structural similarity

    /// Block-wise SSIM heatmap plus summary statistics.
    ///
    /// - Parameter blockSize: edge length of one heatmap cell, clamped to
    ///   `1...similarityWorkingSize` so a caller cannot request a zero or negative grid.
    public static func compare(
        reference: GrayscaleBuffer,
        derivative: GrayscaleBuffer,
        blockSize requestedBlockSize: Int = 8
    ) -> DiffReport {
        let n = similarityWorkingSize
        let blockSize = min(max(requestedBlockSize, 1), n)
        let blocksPerAxis = max(1, SafeArithmetic.dividing(n, by: blockSize, fallback: 1))

        let left = boxResample(reference, to: n, height: n)
        let right = boxResample(derivative, to: n, height: n)

        var blocks: [BlockScore] = []
        blocks.reserveCapacity(blocksPerAxis * blocksPerAxis)

        for blockRow in 0..<blocksPerAxis {
            for blockColumn in 0..<blocksPerAxis {
                let originX = blockColumn * blockSize
                let originY = blockRow * blockSize
                let similarity = ssim(
                    left, right,
                    size: n,
                    originX: originX,
                    originY: originY,
                    blockSize: blockSize
                )
                blocks.append(BlockScore(column: blockColumn, row: blockRow, similarity: similarity))
            }
        }

        // `blocks` is non-empty by construction (blocksPerAxis >= 1), but the mean is
        // still computed through the guarded ratio so a future refactor that can empty
        // the grid degrades instead of dividing by zero.
        let total = blocks.reduce(0.0) { $0 + $1.similarity }
        let mean = SafeArithmetic.unitClamped(
            SafeArithmetic.ratio(total, Double(blocks.count), fallback: 0)
        )
        let worst = blocks.map(\.similarity).min() ?? 0

        let distance = hashDistance(perceptualHash(reference), perceptualHash(derivative))
        let hashAgreement = SafeArithmetic.unitClamped(
            1 - SafeArithmetic.ratio(Double(distance), 64, fallback: 1)
        )

        // Global agreement only — see `DiffReport.matchScore`. `worstBlockSimilarity`
        // is reported separately and checked separately.
        let combined = 0.5 * hashAgreement + 0.5 * mean

        return DiffReport(
            hashDistance: distance,
            meanSimilarity: mean,
            worstBlockSimilarity: SafeArithmetic.unitClamped(worst),
            blocks: blocks,
            matchScore: SafeArithmetic.unitClamped(combined)
        )
    }

    // MARK: - Internals

    /// Area-average resample. Every read goes through `clampedPixel`, so a degenerate
    /// source-to-target ratio cannot walk off the buffer.
    static func boxResample(_ buffer: GrayscaleBuffer, to width: Int, height: Int) -> [Double] {
        let targetWidth = max(1, width)
        let targetHeight = max(1, height)
        var output = [Double](repeating: 0, count: targetWidth * targetHeight)

        let scaleX = SafeArithmetic.ratio(Double(buffer.width), Double(targetWidth), fallback: 1)
        let scaleY = SafeArithmetic.ratio(Double(buffer.height), Double(targetHeight), fallback: 1)

        for targetY in 0..<targetHeight {
            let startY = SafeArithmetic.clampedInt((Double(targetY) * scaleY).rounded(.down))
            let rawEndY = SafeArithmetic.clampedInt((Double(targetY + 1) * scaleY).rounded(.down))
            let endY = max(startY + 1, rawEndY)

            for targetX in 0..<targetWidth {
                let startX = SafeArithmetic.clampedInt((Double(targetX) * scaleX).rounded(.down))
                let rawEndX = SafeArithmetic.clampedInt((Double(targetX + 1) * scaleX).rounded(.down))
                let endX = max(startX + 1, rawEndX)

                var sum = 0.0
                var samples = 0
                for sourceY in startY..<endY {
                    for sourceX in startX..<endX {
                        sum += Double(buffer.clampedPixel(x: sourceX, y: sourceY))
                        samples += 1
                    }
                }
                output[targetY * targetWidth + targetX] =
                    SafeArithmetic.ratio(sum, Double(samples), fallback: 0)
            }
        }
        return output
    }

    /// Separable 2D DCT-II. O(n^3) with `n = 32`, which is ~33k multiply-adds — cheap
    /// enough to run on demand and simple enough to read, which matters more here than
    /// an FFT would.
    static func dct2D(_ values: [Double], size: Int) -> [Double] {
        guard size > 0, values.count == size * size else {
            return [Double](repeating: 0, count: max(0, values.count))
        }

        var cosine = [Double](repeating: 0, count: size * size)
        for u in 0..<size {
            for x in 0..<size {
                cosine[u * size + x] = cos(Double(2 * x + 1) * Double(u) * .pi / Double(2 * size))
            }
        }

        var rows = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for u in 0..<size {
                var sum = 0.0
                for x in 0..<size {
                    sum += values[y * size + x] * cosine[u * size + x]
                }
                rows[y * size + u] = sum * (u == 0 ? sqrt(0.5) : 1)
            }
        }

        var output = [Double](repeating: 0, count: size * size)
        for u in 0..<size {
            for v in 0..<size {
                var sum = 0.0
                for y in 0..<size {
                    sum += rows[y * size + u] * cosine[v * size + y]
                }
                output[v * size + u] = sum * (v == 0 ? sqrt(0.5) : 1)
            }
        }
        return output
    }

    /// Median of the hash coefficients with the DC term (index 0) removed, so overall
    /// brightness does not drag every bit in one direction.
    static func medianExcludingDC(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let sorted = Array(values.dropFirst()).sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        // `middle >= 1` here because an even count of at least 2 puts middle at >= 1.
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func ssim(
        _ lhs: [Double],
        _ rhs: [Double],
        size: Int,
        originX: Int,
        originY: Int,
        blockSize: Int
    ) -> Double {
        let endX = min(originX + blockSize, size)
        let endY = min(originY + blockSize, size)
        guard originX < endX, originY < endY else { return 1 }

        var sumL = 0.0, sumR = 0.0
        var count = 0
        for y in originY..<endY {
            for x in originX..<endX {
                let index = y * size + x
                guard index >= 0, index < lhs.count, index < rhs.count else { continue }
                sumL += lhs[index]
                sumR += rhs[index]
                count += 1
            }
        }
        guard count > 0 else { return 1 }

        let denominator = Double(count)
        let meanL = SafeArithmetic.ratio(sumL, denominator, fallback: 0)
        let meanR = SafeArithmetic.ratio(sumR, denominator, fallback: 0)

        var varianceL = 0.0, varianceR = 0.0, covariance = 0.0
        for y in originY..<endY {
            for x in originX..<endX {
                let index = y * size + x
                guard index >= 0, index < lhs.count, index < rhs.count else { continue }
                let deltaL = lhs[index] - meanL
                let deltaR = rhs[index] - meanR
                varianceL += deltaL * deltaL
                varianceR += deltaR * deltaR
                covariance += deltaL * deltaR
            }
        }
        varianceL = SafeArithmetic.ratio(varianceL, denominator, fallback: 0)
        varianceR = SafeArithmetic.ratio(varianceR, denominator, fallback: 0)
        covariance = SafeArithmetic.ratio(covariance, denominator, fallback: 0)

        let numerator = (2 * meanL * meanR + c1) * (2 * covariance + c2)
        let denom = (meanL * meanL + meanR * meanR + c1) * (varianceL + varianceR + c2)
        // `denom` is >= c1 * c2 > 0 analytically, but it is a product of accumulated
        // floating-point sums, so the division is still guarded.
        return SafeArithmetic.unitClamped(SafeArithmetic.ratio(numerator, denom, fallback: 0))
    }
}
