import XCTest
@testable import NativeGPUProfiler

final class QuickProfileTests: XCTestCase {
    func testDefaultCaptureAfterForWebGL() {
        XCTAssertEqual(defaultCaptureAfter(for: .webgl, runtime: .webkit), 15)
        XCTAssertEqual(defaultCaptureAfter(for: .webgl, runtime: .chrome), 8)
    }

    func testDefaultCaptureAfterForWebGPU() {
        XCTAssertEqual(defaultCaptureAfter(for: .webgpu, runtime: .webkit), 5)
        XCTAssertEqual(defaultCaptureAfter(for: .webgpu, runtime: .chrome), 8)
    }

    func testQuickProfileBuildsExpectedWebGLPreset() {
        let arguments = quickProfileArguments(
            url: "https://example.com",
            runtime: .webkit,
            graphicsApi: .webgl,
            webglMode: .wrapped,
            recordFor: 8,
            frames: nil,
            captureAfter: defaultCaptureAfter(for: .webgl, runtime: .webkit),
            timeout: 180,
            webkitDir: nil,
            outputDir: "traces",
            autoBuild: true,
            openXcode: true,
            keepRunning: false,
            verbose: false
        )

        XCTAssertEqual(
            arguments,
            [
                "--url", "https://example.com",
                "--runtime", "webkit",
                "--graphics-api", "webgl",
                "--record-for", "8",
                "--capture-after", "15",
                "--timeout", "180",
                "--output-dir", "traces",
                "--webgl-mode", "wrapped"
            ]
        )
    }
}
