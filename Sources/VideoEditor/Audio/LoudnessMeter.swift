import Foundation

/// Integrated loudness in LUFS (ITU-R BS.1770-4) of a mono signal, fed in
/// buffers: K-weighting (a high shelf and a high-pass), 400 ms blocks with
/// 75% overlap, an absolute gate at −70 LUFS and a relative gate 10 LU
/// below the absolute-gated mean. Apple's SDK has no loudness meter (PRD AU-2).
struct LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0
        var z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf: Biquad
    private var highPass: Biquad
    /// Mean square of each 100 ms step; blocks are four consecutive steps.
    private var steps: [Double] = []
    private var stepSum = 0.0
    private var stepCount = 0
    private let stepLength: Int

    init(sampleRate: Double) {
        // Coefficients from the standard's analog prototypes, for any rate.
        var k = tan(Double.pi * 1681.974450955533 / sampleRate)
        let gain = pow(10, 3.999843853973347 / 20)
        let vb = pow(gain, 0.4996667741545416)
        var q = 0.7071752369554196
        var a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (gain + vb * k / q + k * k) / a0, b1: 2 * (k * k - gain) / a0, b2: (gain - vb * k / q + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        stepLength = max(1, Int(sampleRate * 0.1))
    }

    mutating func process(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            let weighted = highPass.process(shelf.process(Double(sample)))
            stepSum += weighted * weighted
            stepCount += 1
            if stepCount == stepLength {
                steps.append(stepSum / Double(stepLength))
                stepSum = 0
                stepCount = 0
            }
        }
    }

    /// `nil` when there's under 400 ms of signal or everything is silent.
    var integratedLoudness: Double? {
        guard steps.count >= 4 else { return nil }
        let blocks = (0...(steps.count - 4)).map { (steps[$0] + steps[$0 + 1] + steps[$0 + 2] + steps[$0 + 3]) / 4 }
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-12)) }
        let absolute = blocks.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let threshold = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > threshold }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}
