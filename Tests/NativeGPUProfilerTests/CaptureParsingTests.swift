import XCTest
@testable import NativeGPUProfiler

final class CaptureParsingTests: XCTestCase {
    func testParseCaptureToken() {
        let log = "Success starting GPU frame capture at path file:///var/folders/abc123/test-capture"
        XCTAssertEqual(parseCaptureToken(from: log), "file:///var/folders/abc123/test-capture")
    }

    func testNormalizeCapturePath() {
        XCTAssertEqual(
            normalizedCapturePath(from: "file:///var/folders/abc123/test-capture"),
            "/var/folders/abc123/test-capture"
        )
    }

    func testWrappedLaunchURLForWebGL() async throws {
        let launchContext = try resolvedLaunchContext(
            baseURL: "https://playcanvas.com",
            graphicsAPI: .webgl,
            webglMode: .wrapped
        )
        defer { launchContext.stop() }

        XCTAssertTrue(launchContext.launchURL.hasPrefix("http://localhost:"))

        let wrapperURL = try XCTUnwrap(URL(string: launchContext.launchURL))
        let (wrapperData, response) = try await URLSession.shared.data(from: wrapperURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let wrapperHTML = try XCTUnwrap(String(data: wrapperData, encoding: .utf8))
        XCTAssertTrue(wrapperHTML.contains("playcanvas.com"))
        XCTAssertTrue(wrapperHTML.contains("ngp-webgpu-helper"))
    }

    func testWebGPULaunchURLUnchanged() throws {
        let base = "https://example.com"
        let launchContext = try resolvedLaunchContext(baseURL: base, graphicsAPI: .webgpu, webglMode: .wrapped)
        defer { launchContext.stop() }

        XCTAssertEqual(
            launchContext.launchURL,
            base
        )
    }

    func testWebKitWrappedWebGLUsesBaseURL() throws {
        let base = "https://example.com"
        let launchContext = try resolvedLaunchContext(baseURL: base, graphicsAPI: .webgl, webglMode: .wrapped, runtime: .webkit)
        defer { launchContext.stop() }

        XCTAssertEqual(launchContext.launchURL, base)
    }
}
