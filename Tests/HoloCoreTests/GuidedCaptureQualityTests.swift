import XCTest
@testable import HoloCore

final class GuidedCaptureQualityTests: XCTestCase {
    func testAcceptsCleanTapAtThresholds() {
        XCTAssertNil(GuidedCaptureQuality.issue(for: quality(
            snr: GuidedCaptureQuality.minimumSignalToNoiseDB,
            peak: GuidedCaptureQuality.minimumPeakAmplitude,
            clipping: GuidedCaptureQuality.maximumClippingFraction
        )))
    }

    func testRejectsClippedTapFirst() {
        XCTAssertEqual(
            GuidedCaptureQuality.issue(for: quality(snr: 2, peak: 0.001, clipping: 0.21)),
            .clipped
        )
    }

    func testRejectsWeakTapBeforeLowSignalToNoise() {
        XCTAssertEqual(
            GuidedCaptureQuality.issue(for: quality(snr: 2, peak: 0.0029, clipping: 0)),
            .weak
        )
    }

    func testRejectsNoisyTap() {
        XCTAssertEqual(
            GuidedCaptureQuality.issue(for: quality(
                snr: GuidedCaptureQuality.minimumSignalToNoiseDB - 0.1,
                peak: 0.02,
                clipping: 0
            )),
            .noisy
        )
    }

    private func quality(snr: Double, peak: Double, clipping: Double) -> SignalQuality {
        SignalQuality(
            signalToNoiseDB: snr,
            peakAmplitude: peak,
            rmsAmplitude: 0.01,
            clippingFraction: clipping,
            noiseFloorRMS: 0.0005,
            durationMilliseconds: 90
        )
    }
}
