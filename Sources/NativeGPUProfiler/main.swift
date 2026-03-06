import ArgumentParser
import Darwin
import Foundation

let captureNotificationName = "com.apple.WebKit.WebGPU.CaptureFrame"

enum GraphicsAPI: String, ExpressibleByArgument {
    case webgpu
    case webgl
}

enum WebGLMode: String, ExpressibleByArgument {
    case wrapped
    case inPage = "in-page"
}

enum CaptureRuntime: String, ExpressibleByArgument {
    case webkit
    case chrome
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct BrowserRuntimeConfig {
    let appName: String
    let processMarkers: [String]
}

struct LaunchContext {
    let launchURL: String
    private let wrapperServer: LocalHTTPServer?

    init(launchURL: String, wrapperServer: LocalHTTPServer? = nil) {
        self.launchURL = launchURL
        self.wrapperServer = wrapperServer
    }

    func stop() {
        wrapperServer?.stop()
    }
}

struct RuntimeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var combinedOutput = ""
    private var captureTokenString: String?

    func append(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        combinedOutput += text
        if captureTokenString == nil, let parsed = parseCaptureToken(from: combinedOutput) {
            captureTokenString = parsed
            return true
        }
        return false
    }

    func tail(_ maxCharacters: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(combinedOutput.suffix(maxCharacters))
    }

    func captureToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return captureTokenString
    }
}

@main
struct NGP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ngp",
        abstract: "Native macOS GPU frame capture helper for WebKit MiniBrowser or Chrome.",
        subcommands: [Doctor.self, Trace.self, WebKit.self, Profile.self, Helper.self]
    )
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check local prerequisites.")

    @Option(name: .long, help: "Path to a WebKit checkout to validate.")
    var webkitDir: String?

    mutating func run() throws {
        let arch = (try? runCommand(executable: "/usr/bin/uname", arguments: ["-m"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"

        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Arch: \(arch)")

        var hasFailure = false

        if arch != "arm64" {
            print("[WARN] This flow is tested on Apple Silicon (arm64).")
        } else {
            print("[OK] Apple Silicon detected.")
        }

        let xcodePathResult = try runCommand(executable: "/usr/bin/xcode-select", arguments: ["-p"])
        if xcodePathResult.status == 0 {
            print("[OK] Xcode path: \(xcodePathResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            print("[FAIL] Xcode CLI tools are not configured. Run: xcode-select --install")
            hasFailure = true
        }

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/notifyutil") {
            print("[OK] notifyutil found.")
        } else {
            print("[FAIL] /usr/bin/notifyutil is missing.")
            hasFailure = true
        }

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            print("[OK] xcrun found.")
        } else {
            print("[FAIL] /usr/bin/xcrun is missing.")
            hasFailure = true
        }

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            print("[OK] git found.")
        } else {
            print("[FAIL] /usr/bin/git is missing.")
            hasFailure = true
        }

        if let browser = try resolveBrowserRuntimeConfig() {
            print("[OK] Browser runtime available: \(browser.appName)")
        } else {
            print("[WARN] Chrome runtime not found (Google Chrome / Canary / Chromium).")
        }

        let webKitDirectory = resolveWebKitDirectory(from: webkitDir)
        if fileExists(webKitDirectory) {
            if hasWebKitScripts(webKitDirectory) {
                print("[OK] WebKit checkout detected at: \(webKitDirectory.path)")
                let issues = webKitBuildIssues(webKitDirectory)
                if issues.isEmpty {
                    print("[OK] MiniBrowser build artifacts detected and version-matched.")
                } else if hasMiniBrowserArtifacts(webKitDirectory) {
                    print("[WARN] MiniBrowser artifacts exist, but the build is incomplete:")
                    for issue in issues {
                        print("       - \(issue)")
                    }
                } else {
                    print("[WARN] WebKit checkout exists but MiniBrowser release artifacts were not found.")
                }
            } else {
                print("[FAIL] Directory exists but does not look like a WebKit checkout: \(webKitDirectory.path)")
                hasFailure = true
            }
        } else {
            print("[WARN] No WebKit checkout at default path: \(webKitDirectory.path)")
            print("       Run: ngp webkit ensure --webkit-dir \"\(webKitDirectory.path)\"")
        }

        if hasFailure {
            Foundation.exit(2)
        }
    }
}

struct WebKit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webkit",
        abstract: "Manage the WebKit dependency.",
        subcommands: [Ensure.self]
    )

    struct Ensure: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clone/build WebKit for MiniBrowser capture.")

        @Option(name: .long, help: "Path for the WebKit checkout.")
        var webkitDir: String?

        @Option(name: .long, help: "WebKit branch to clone when checkout is missing.")
        var branch: String = "main"

        @Flag(name: .long, inversion: .prefixedNo, help: "Run WebKit build if artifacts are missing.")
        var build: Bool = true

        mutating func run() throws {
            let directory = resolveWebKitDirectory(from: webkitDir)
            try ensureWebKit(at: directory, branch: branch, autoBuild: build)
            print("WebKit ready at: \(directory.path)")
        }
    }
}

struct Trace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Quick trace commands with sensible defaults for web apps.",
        subcommands: [WebGL.self, WebGPU.self]
    )

    struct WebGL: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "webgl",
            abstract: "Capture a WebGL app. Defaults to the WebKit flow used for Xcode frame replay."
        )

        @Argument(help: "Target URL to open and capture.")
        var url: String

        @Option(name: .long, help: "Runtime backend: webkit for frame replay, chrome for a Metal System Trace.")
        var runtime: CaptureRuntime = .webkit

        @Option(name: .long, help: "WebGL behavior: wrapped (default) or in-page if the site blocks iframe embedding.")
        var webglMode: WebGLMode = .wrapped

        @Option(name: .long, help: "Seconds to wait before capture. Defaults to 15 for webkit or 8 for chrome.")
        var captureAfter: Int?

        @Option(name: .long, help: "Frames to capture when runtime=webkit. Defaults to 3.")
        var frames: Int?

        @Option(name: .long, help: "Seconds to record when runtime=chrome.")
        var recordFor: Int = 8

        @Option(name: .long, help: "Seconds to wait for a runtime process/capture path.")
        var timeout: Int = 180

        @Option(name: .long, help: "Path for the WebKit checkout.")
        var webkitDir: String?

        @Option(name: .long, help: "Directory where trace artifacts are stored.")
        var outputDir: String = "traces"

        @Flag(name: .long, inversion: .prefixedNo, help: "Clone/build WebKit automatically if missing.")
        var autoBuild: Bool = true

        @Flag(name: .long, inversion: .prefixedNo, help: "Open the capture in Xcode.")
        var openXcode: Bool = true

        @Flag(name: .long, inversion: .prefixedNo, help: "Keep the browser running after capture.")
        var keepRunning: Bool = false

        @Flag(name: .long, help: "Stream runtime output while running.")
        var verbose: Bool = false

        mutating func run() throws {
            let arguments = quickProfileArguments(
                url: url,
                runtime: runtime,
                graphicsApi: .webgl,
                webglMode: webglMode,
                recordFor: recordFor,
                frames: frames,
                captureAfter: captureAfter ?? defaultCaptureAfter(for: .webgl, runtime: runtime),
                timeout: timeout,
                webkitDir: webkitDir,
                outputDir: outputDir,
                autoBuild: autoBuild,
                openXcode: openXcode,
                keepRunning: keepRunning,
                verbose: verbose
            )
            var profile = try Profile.parse(arguments)
            try profile.run()
        }
    }

    struct WebGPU: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "webgpu",
            abstract: "Capture a WebGPU app. Defaults to Chrome for the fastest setup."
        )

        @Argument(help: "Target URL to open and capture.")
        var url: String

        @Option(name: .long, help: "Runtime backend: chrome for a Metal System Trace, or webkit for MiniBrowser capture.")
        var runtime: CaptureRuntime = .chrome

        @Option(name: .long, help: "Seconds to wait before capture. Defaults to 8 for chrome or 5 for webkit.")
        var captureAfter: Int?

        @Option(name: .long, help: "Frames to capture when runtime=webkit. Defaults to 1.")
        var frames: Int?

        @Option(name: .long, help: "Seconds to record when runtime=chrome.")
        var recordFor: Int = 8

        @Option(name: .long, help: "Seconds to wait for a runtime process/capture path.")
        var timeout: Int = 180

        @Option(name: .long, help: "Path for the WebKit checkout.")
        var webkitDir: String?

        @Option(name: .long, help: "Directory where trace artifacts are stored.")
        var outputDir: String = "traces"

        @Flag(name: .long, inversion: .prefixedNo, help: "Clone/build WebKit automatically if missing.")
        var autoBuild: Bool = true

        @Flag(name: .long, inversion: .prefixedNo, help: "Open the capture in Xcode.")
        var openXcode: Bool = true

        @Flag(name: .long, inversion: .prefixedNo, help: "Keep the browser running after capture.")
        var keepRunning: Bool = false

        @Flag(name: .long, help: "Stream runtime output while running.")
        var verbose: Bool = false

        mutating func run() throws {
            let arguments = quickProfileArguments(
                url: url,
                runtime: runtime,
                graphicsApi: .webgpu,
                webglMode: .wrapped,
                recordFor: recordFor,
                frames: frames,
                captureAfter: captureAfter ?? defaultCaptureAfter(for: .webgpu, runtime: runtime),
                timeout: timeout,
                webkitDir: webkitDir,
                outputDir: outputDir,
                autoBuild: autoBuild,
                openXcode: openXcode,
                keepRunning: keepRunning,
                verbose: verbose
            )
            var profile = try Profile.parse(arguments)
            try profile.run()
        }
    }
}

struct Profile: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run one-shot GPU capture and optionally open Xcode.")

    @Option(name: .long, help: "Target URL to open in the selected runtime.")
    var url: String

    @Option(name: .long, help: "Runtime backend: chrome (xctrace attach) or webkit (MiniBrowser + notifyutil).")
    var runtime: CaptureRuntime = .chrome

    @Option(name: .long, help: "Graphics API workload: webgpu or webgl.")
    var graphicsApi: GraphicsAPI = .webgpu

    @Option(name: .long, help: "WebGL behavior: wrapped (inject helper in a wrapper page) or in-page (app provides helper).")
    var webglMode: WebGLMode = .wrapped

    @Option(name: .long, help: "Seconds to record when runtime=chrome.")
    var recordFor: Int = 12

    @Option(name: .long, help: "Frames to capture (default: 1 for webgpu, 3 for webgl).")
    var frames: Int?

    @Option(name: .long, help: "Seconds to wait before capture trigger (webkit) or before xctrace starts (chrome).")
    var captureAfter: Int = 5

    @Option(name: .long, help: "Seconds to wait for a runtime process/capture path.")
    var timeout: Int = 180

    @Option(name: .long, help: "Path for the WebKit checkout.")
    var webkitDir: String?

    @Option(name: .long, help: "Directory where trace artifacts are stored. Relative paths are resolved from the current working directory.")
    var outputDir: String = "traces"

    @Flag(name: .long, inversion: .prefixedNo, help: "Clone/build WebKit automatically if missing.")
    var autoBuild: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Open the capture in Xcode.")
    var openXcode: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Keep runtime browser running after capture (webkit only).")
    var keepRunning: Bool = false

    @Flag(name: .long, help: "Stream runtime output while running.")
    var verbose: Bool = false

    mutating func run() throws {
        guard URL(string: url) != nil else {
            fatalExit("Invalid URL: \(url)", code: 2)
        }

        if captureAfter < 0 {
            fatalExit("--capture-after must be >= 0", code: 2)
        }

        if timeout < 1 {
            fatalExit("--timeout must be >= 1", code: 2)
        }

        let outputDirectory = resolveOutputDirectory(from: outputDir)
        do {
            try ensureDirectoryExists(outputDirectory)
        } catch {
            fatalExit("Failed to create output directory at \(outputDirectory.path): \(error)", code: 2)
        }

        switch runtime {
        case .webkit:
            try runWebKitProfile(outputDirectory: outputDirectory)
        case .chrome:
            try runChromeProfile(outputDirectory: outputDirectory)
        }
    }

    private func printWebGLModeInfo(for runtime: CaptureRuntime) {
        guard graphicsApi == .webgl else {
            return
        }

        switch webglMode {
        case .wrapped:
            if runtime == .webkit {
                print("WebGL wrapped mode enabled. MiniBrowser will inject a hidden WebGPU helper script into the top-level page.")
            } else {
                print("WebGL wrapped mode enabled. A hidden WebGPU helper canvas will be injected in a localhost wrapper page.")
                print("If the target blocks iframe embedding (X-Frame-Options/CSP), use --webgl-mode in-page.")
            }
        case .inPage:
            print("WebGL in-page mode enabled. Ensure your app includes a tiny WebGPU helper workload.")
        }
    }

    private func runWebKitProfile(outputDirectory: URL) throws {
        let notifyutil = "/usr/bin/notifyutil"
        guard FileManager.default.isExecutableFile(atPath: notifyutil) else {
            fatalExit("notifyutil is missing at /usr/bin/notifyutil.", code: 2)
        }

        let webKitDirectory = resolveWebKitDirectory(from: webkitDir)
        try ensureWebKit(at: webKitDirectory, branch: "main", autoBuild: autoBuild)
        try ensureMiniBrowserWebGPUEnabled()

        let effectiveFrames = frames ?? (graphicsApi == .webgl ? 3 : 1)
        if effectiveFrames < 1 {
            fatalExit("--frames must be >= 1", code: 2)
        }

        let launchContext = try resolvedLaunchContext(baseURL: url, graphicsAPI: graphicsApi, webglMode: webglMode, runtime: .webkit)
        defer { launchContext.stop() }
        let launchURL = launchContext.launchURL
        printWebGLModeInfo(for: .webkit)

        print("Starting MiniBrowser...")
        let miniBrowser = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        miniBrowser.executableURL = miniBrowserExecutableURL(webKitDirectory)
        miniBrowser.arguments = ["--url", launchURL, "--mac"]
        miniBrowser.currentDirectoryURL = webKitDirectory
        miniBrowser.standardOutput = stdoutPipe
        miniBrowser.standardError = stderrPipe

        miniBrowser.environment = webKitLaunchEnvironment(
            buildRoot: webKitBuildReleaseDirectory(webKitDirectory),
            captureEnabled: true,
            webGLHelperScript: webKitInjectedWebGLHelperScript(graphicsAPI: graphicsApi, webglMode: webglMode)
        )

        let captureState = CaptureState()
        let isVerbose = verbose

        let consume: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            if isVerbose {
                print(text, terminator: "")
            }
            _ = captureState.append(text)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            consume(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            consume(data)
        }

        do {
            try miniBrowser.run()
        } catch {
            fatalExit("Failed to start MiniBrowser: \(error)", code: 2)
        }

        print("Waiting \(captureAfter)s before triggering capture...")
        Thread.sleep(forTimeInterval: Double(captureAfter))

        let captureBaseline = captureCandidatesSnapshot()

        let setFrames = try runCommand(executable: notifyutil, arguments: ["-s", captureNotificationName, String(effectiveFrames)])
        if setFrames.status != 0 {
            terminate(miniBrowser)
            fatalExit("Failed to configure frame count via notifyutil.", code: 4)
        }

        let triggerCapture = try runCommand(executable: notifyutil, arguments: ["-p", captureNotificationName])
        if triggerCapture.status != 0 {
            terminate(miniBrowser)
            fatalExit("Failed to trigger frame capture via notifyutil.", code: 4)
        }

        print("Capture triggered. Waiting for capture output path...")
        let deadline = Date().addingTimeInterval(Double(timeout))
        var discoveredCapturePath: String?
        while Date() < deadline {
            if let token = captureState.captureToken(),
               let parsedPath = normalizedCapturePath(from: token),
               fileExists(URL(fileURLWithPath: parsedPath)) {
                discoveredCapturePath = parsedPath
                break
            }

            if let fallbackPath = latestCaptureCandidate(excluding: captureBaseline) {
                discoveredCapturePath = fallbackPath
                break
            }

            if !miniBrowser.isRunning {
                break
            }

            Thread.sleep(forTimeInterval: 0.2)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if discoveredCapturePath == nil {
            terminate(miniBrowser)
            let tail = captureState.tail(1200)
            var message = "Timed out waiting for capture path."
            if !miniBrowser.isRunning {
                message += " MiniBrowser exited with status \(miniBrowser.terminationStatus)."
            }
            message += "\n\(tail)"
            fatalExit(message, code: 5)
        }

        let capturePath = discoveredCapturePath ?? ""
        let storedCapturePath: String
        do {
            storedCapturePath = try storeCaptureArtifact(atPath: capturePath, in: outputDirectory)
        } catch {
            terminate(miniBrowser)
            fatalExit("Capture succeeded but storing the trace in \(outputDirectory.path) failed: \(error)", code: 5)
        }

        print("Capture path: \(storedCapturePath)")

        if openXcode {
            let openResult = try runCommand(executable: "/usr/bin/open", arguments: ["-a", "Xcode", storedCapturePath])
            if openResult.status == 0 {
                print("Opened in Xcode.")
            } else {
                print("Warning: failed to open Xcode automatically. You can open this path manually: \(storedCapturePath)")
            }
        }

        if keepRunning {
            print("MiniBrowser kept running (pid \(miniBrowser.processIdentifier)).")
        } else {
            terminate(miniBrowser)
        }
    }

    private func runChromeProfile(outputDirectory: URL) throws {
        guard recordFor > 0 else {
            fatalExit("--record-for must be >= 1", code: 2)
        }

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
            fatalExit("xcrun is missing at /usr/bin/xcrun.", code: 2)
        }

        guard let browser = try resolveBrowserRuntimeConfig() else {
            fatalExit("Unable to find Google Chrome, Google Chrome Canary, or Chromium in /Applications.", code: 2)
        }

        let launchContext = try resolvedLaunchContext(baseURL: url, graphicsAPI: graphicsApi, webglMode: webglMode, runtime: .chrome)
        defer { launchContext.stop() }
        let launchURL = launchContext.launchURL
        printWebGLModeInfo(for: .chrome)

        let initialGPUProcesses = try gpuProcessIDs(matching: browser.processMarkers)

        print("Launching \(browser.appName)...")
        let openResult = try runCommand(executable: "/usr/bin/open", arguments: ["-a", browser.appName, launchURL])
        if openResult.status != 0 {
            let details = [openResult.stdout, openResult.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fatalExit("Failed to launch \(browser.appName). \(details)", code: 2)
        }

        if captureAfter > 0 {
            print("Waiting \(captureAfter)s for page load...")
            Thread.sleep(forTimeInterval: Double(captureAfter))
        }

        print("Locating browser GPU process...")
        let gpuDeadline = Date().addingTimeInterval(Double(timeout))
        var attachPID: Int32?
        while Date() < gpuDeadline {
            let currentProcesses = try gpuProcessIDs(matching: browser.processMarkers)
            let newProcesses = currentProcesses.subtracting(initialGPUProcesses)
            if let selected = newProcesses.max() ?? currentProcesses.max() {
                attachPID = selected
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        guard let gpuPID = attachPID else {
            fatalExit("Timed out waiting for browser GPU process. Ensure Chrome is running and hardware acceleration is enabled.", code: 5)
        }

        let outputPath = chromeTraceOutputPath(in: outputDirectory)
        print("Recording Metal trace for \(recordFor)s from pid \(gpuPID)...")
        let trace = try runCommand(
            executable: "/usr/bin/xcrun",
            arguments: [
                "xctrace",
                "record",
                "--template",
                "Metal System Trace",
                "--output",
                outputPath,
                "--time-limit",
                "\(recordFor)s",
                "--attach",
                String(gpuPID)
            ]
        )

        if verbose {
            if !trace.stdout.isEmpty {
                print(trace.stdout, terminator: "")
            }
            if !trace.stderr.isEmpty {
                print(trace.stderr, terminator: "")
            }
        }

        if trace.status != 0 {
            let details = [trace.stdout, trace.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fatalExit("xctrace failed while recording Chrome GPU workload.\n\(details)", code: 5)
        }

        guard fileExists(URL(fileURLWithPath: outputPath)) else {
            let details = [trace.stdout, trace.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fatalExit("xctrace completed but no trace was written to \(outputPath).\n\(details)", code: 5)
        }

        print("Capture path: \(outputPath)")

        if openXcode {
            let openResult = try runCommand(executable: "/usr/bin/open", arguments: ["-a", "Xcode", outputPath])
            if openResult.status == 0 {
                print("Opened in Xcode.")
            } else {
                print("Warning: failed to open Xcode automatically. You can open this path manually: \(outputPath)")
            }
        }

        if !keepRunning {
            print("Chrome remains running. Automatic Chrome termination is disabled for safety.")
        }
    }
}

struct Helper: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Utility helpers for WebGL capture setup.",
        subcommands: [WebGLSnippet.self]
    )

    struct WebGLSnippet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "webgl-snippet",
            abstract: "Print a standalone WebGPU helper snippet for WebGL capture."
        )

        mutating func run() throws {
            print(webGLHelperSnippet)
        }
    }
}

func quickProfileArguments(
    url: String,
    runtime: CaptureRuntime,
    graphicsApi: GraphicsAPI,
    webglMode: WebGLMode,
    recordFor: Int,
    frames: Int?,
    captureAfter: Int,
    timeout: Int,
    webkitDir: String?,
    outputDir: String,
    autoBuild: Bool,
    openXcode: Bool,
    keepRunning: Bool,
    verbose: Bool
) -> [String] {
    var arguments = [
        "--url", url,
        "--runtime", runtime.rawValue,
        "--graphics-api", graphicsApi.rawValue,
        "--record-for", String(recordFor),
        "--capture-after", String(captureAfter),
        "--timeout", String(timeout),
        "--output-dir", outputDir
    ]

    if graphicsApi == .webgl {
        arguments += ["--webgl-mode", webglMode.rawValue]
    }

    if let frames {
        arguments += ["--frames", String(frames)]
    }

    if let webkitDir {
        arguments += ["--webkit-dir", webkitDir]
    }

    if !autoBuild {
        arguments.append("--no-auto-build")
    }

    if !openXcode {
        arguments.append("--no-open-xcode")
    }

    if keepRunning {
        arguments.append("--keep-running")
    }

    if verbose {
        arguments.append("--verbose")
    }

    return arguments
}

func defaultCaptureAfter(for graphicsApi: GraphicsAPI, runtime: CaptureRuntime) -> Int {
    switch (graphicsApi, runtime) {
    case (.webgl, .webkit):
        return 15
    case (.webgl, .chrome):
        return 8
    case (.webgpu, .webkit):
        return 5
    case (.webgpu, .chrome):
        return 8
    }
}

func runCommand(
    executable: String,
    arguments: [String],
    cwd: URL? = nil,
    environment: [String: String] = [:],
    passthroughOutput: Bool = false
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd

    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment

    if passthroughOutput {
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: "", stderr: "")
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return CommandResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

func resolveBrowserRuntimeConfig() throws -> BrowserRuntimeConfig? {
    let candidates: [BrowserRuntimeConfig] = [
        BrowserRuntimeConfig(
            appName: "Google Chrome",
            processMarkers: ["/Google Chrome.app/"]
        ),
        BrowserRuntimeConfig(
            appName: "Google Chrome Canary",
            processMarkers: ["/Google Chrome Canary.app/"]
        ),
        BrowserRuntimeConfig(
            appName: "Chromium",
            processMarkers: ["/Chromium.app/"]
        )
    ]

    for candidate in candidates {
        let check = try runCommand(executable: "/usr/bin/open", arguments: ["-Ra", candidate.appName])
        if check.status == 0 {
            return candidate
        }
    }

    return nil
}

func gpuProcessIDs(matching markers: [String]) throws -> Set<Int32> {
    let gpuCandidates = try runCommand(executable: "/usr/bin/pgrep", arguments: ["-f", "--", "--type=gpu-process"])
    guard gpuCandidates.status == 0 else {
        return []
    }

    var result = Set<Int32>()
    for line in gpuCandidates.stdout.split(whereSeparator: \.isNewline) {
        guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            continue
        }

        let commandLine = try runCommand(executable: "/bin/ps", arguments: ["-p", String(pid), "-o", "args="])
        guard commandLine.status == 0 else {
            continue
        }

        let args = commandLine.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if markers.allSatisfy({ args.contains($0) }) {
            result.insert(pid)
        }
    }

    return result
}

func resolveOutputDirectory(from raw: String) -> URL {
    let expanded = (raw as NSString).expandingTildeInPath
    let candidate = URL(fileURLWithPath: expanded, isDirectory: true)
    if candidate.path.hasPrefix("/") {
        return candidate.standardizedFileURL
    }

    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(expanded, isDirectory: true)
        .standardizedFileURL
}

func ensureDirectoryExists(_ directory: URL) throws {
    var isDirectoryFlag = ObjCBool(false)
    if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectoryFlag) {
        if !isDirectoryFlag.boolValue {
            fatalExit("Output path exists but is not a directory: \(directory.path)", code: 2)
        }
        return
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

func storeCaptureArtifact(atPath sourcePath: String, in outputDirectory: URL) throws -> String {
    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
    waitForCaptureArtifactToStabilize(at: sourceURL)
    if sourceURL.deletingLastPathComponent() == outputDirectory.standardizedFileURL {
        return sourceURL.path
    }

    let destinationURL = uniqueCaptureDestinationURL(
        baseName: sourceURL.deletingPathExtension().lastPathComponent,
        pathExtension: sourceURL.pathExtension,
        outputDirectory: outputDirectory
    )
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL.path
}

func waitForCaptureArtifactToStabilize(
    at sourceURL: URL,
    timeout: TimeInterval = 20,
    pollInterval: TimeInterval = 0.5,
    requiredStableSamples: Int = 4
) {
    guard fileExists(sourceURL) else {
        return
    }

    let deadline = Date().addingTimeInterval(timeout)
    var lastSignature: CaptureArtifactSignature?
    var stableSamples = 0

    while Date() < deadline {
        guard let signature = captureArtifactSignature(at: sourceURL) else {
            return
        }

        if signature == lastSignature {
            stableSamples += 1
        } else {
            stableSamples = 0
            lastSignature = signature
        }

        if stableSamples >= requiredStableSamples {
            return
        }

        Thread.sleep(forTimeInterval: pollInterval)
    }
}

func captureArtifactSignature(at sourceURL: URL) -> CaptureArtifactSignature? {
    let fileManager = FileManager.default
    var isDirectoryFlag = ObjCBool(false)
    guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectoryFlag) else {
        return nil
    }

    if !isDirectoryFlag.boolValue {
        let size = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return CaptureArtifactSignature(entryCount: 1, totalBytes: UInt64(max(size, 0)))
    }

    guard let enumerator = fileManager.enumerator(
        at: sourceURL,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return CaptureArtifactSignature(entryCount: 0, totalBytes: 0)
    }

    var entryCount = 0
    var totalBytes: UInt64 = 0
    for case let entry as URL in enumerator {
        entryCount += 1
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey])
        if values?.isDirectory == true {
            continue
        }

        let size = values?.totalFileSize ?? values?.fileSize ?? 0
        totalBytes += UInt64(max(size, 0))
    }

    return CaptureArtifactSignature(entryCount: entryCount, totalBytes: totalBytes)
}

struct CaptureArtifactSignature: Equatable {
    let entryCount: Int
    let totalBytes: UInt64
}

func uniqueCaptureDestinationURL(baseName: String, pathExtension: String, outputDirectory: URL) -> URL {
    let fileManager = FileManager.default
    let normalizedBase = baseName.isEmpty ? "capture" : baseName
    while true {
        let timestamp = Int(Date().timeIntervalSince1970)
        let random = UUID().uuidString.prefix(8)
        var candidateName = "\(normalizedBase)-\(timestamp)-\(random)"
        if !pathExtension.isEmpty {
            candidateName += ".\(pathExtension)"
        }
        let candidateURL = outputDirectory.appendingPathComponent(candidateName)
        if !fileManager.fileExists(atPath: candidateURL.path) {
            return candidateURL
        }
    }
}

func chromeTraceOutputPath(in outputDirectory: URL) -> String {
    let timestamp = Int(Date().timeIntervalSince1970)
    let random = UUID().uuidString.prefix(8)
    let filename = "ngp-chrome-\(timestamp)-\(random).trace"
    return outputDirectory
        .appendingPathComponent(filename)
        .path
}

func ensureWebKit(at directory: URL, branch: String, autoBuild: Bool) throws {
    if !FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
        fatalExit("git is required but missing at /usr/bin/git", code: 2)
    }

    if !fileExists(directory) {
        if !autoBuild {
            fatalExit("WebKit checkout is missing at \(directory.path). Re-run with --auto-build.", code: 2)
        }

        print("Cloning WebKit into \(directory.path)...")
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clone = try runCommand(
            executable: "/usr/bin/git",
            arguments: ["clone", "--depth", "1", "--branch", branch, "https://github.com/WebKit/WebKit.git", directory.path],
            passthroughOutput: true
        )
        if clone.status != 0 {
            fatalExit("WebKit clone failed.", code: 3)
        }
    }

    if !hasWebKitScripts(directory) {
        fatalExit("Directory is not a valid WebKit checkout: \(directory.path)", code: 2)
    }

    let patchedMiniBrowser = try ensureMiniBrowserHelperInjectionSupport(at: directory)

    if !hasMiniBrowserArtifacts(directory) {
        if !autoBuild {
            fatalExit("MiniBrowser build artifacts are missing. Re-run with --auto-build or run build-webkit manually.", code: 3)
        }

        print("Building WebKit MiniBrowser (release, WebGPU enabled). This can take a while...")
        try buildMiniBrowserArtifacts(at: directory)
    } else if patchedMiniBrowser {
        if !autoBuild {
            fatalExit("MiniBrowser source was patched to support automatic WebGL helper injection. Re-run with --auto-build so MiniBrowser can be rebuilt.", code: 3)
        }

        print("Rebuilding MiniBrowser to apply the automatic WebGL helper injection patch...")
        try buildMiniBrowserApp(at: directory)
    }

    try ensureMiniBrowserWebGPUEnabled()
    try synchronizeFrameworkXPCServices(at: directory)

    let initialIssues = webKitBuildIssues(directory)
    if initialIssues.isEmpty {
        if let launchIssue = miniBrowserSmokeTestFailure(at: directory) {
            if !autoBuild {
                fatalExit("MiniBrowser launch smoke test failed: \(launchIssue)", code: 3)
            }
        } else {
            return
        }
    }

    if !autoBuild {
        fatalExit("WebKit build artifacts are present but incomplete: \(initialIssues.joined(separator: "; ")). Re-run with --auto-build.", code: 3)
    }

    print("Repairing WebKit framework/XPC services to produce a coherent MiniBrowser build...")
    try buildWebKitFrameworkAndServices(at: directory)
    try synchronizeFrameworkXPCServices(at: directory)

    let finalIssues = webKitBuildIssues(directory)
    if !finalIssues.isEmpty {
        fatalExit("WebKit build is still incomplete after repair: \(finalIssues.joined(separator: "; "))", code: 3)
    }

    if let launchIssue = miniBrowserSmokeTestFailure(at: directory) {
        fatalExit("MiniBrowser launch smoke test still fails after repair: \(launchIssue)", code: 3)
    }
}

func buildMiniBrowserArtifacts(at directory: URL) throws {
    let build = try runCommand(
        executable: "/bin/zsh",
        arguments: ["-lc", "Tools/Scripts/build-webkit -cmakeargs=\"-DENABLE_WEBGPU_BY_DEFAULT=1\" --release COMPILATION_CACHE_ENABLE_CACHING=NO -jobs \(recommendedBuildJobs())"],
        cwd: directory,
        passthroughOutput: true
    )

    if build.status != 0 {
        fatalExit("WebKit MiniBrowser build failed.", code: 3)
    }
}

func buildMiniBrowserApp(at directory: URL) throws {
    let buildRoot = directory.appendingPathComponent("WebKitBuild", isDirectory: true)
    let precompiledHeaders = buildRoot.appendingPathComponent("PrecompiledHeaders", isDirectory: true)
    let build = try runCommand(
        executable: "/usr/bin/xcodebuild",
        arguments: [
            "-project", "Tools/MiniBrowser/MiniBrowser.xcodeproj",
            "-scheme", "MiniBrowser",
            "-configuration", "Release",
            "-destination", "platform=macOS,arch=arm64",
            "SYMROOT=\(buildRoot.path)",
            "OBJROOT=\(buildRoot.path)",
            "SHARED_PRECOMPS_DIR=\(precompiledHeaders.path)",
            "SDKROOT=macosx",
            "COMPILATION_CACHE_ENABLE_CACHING=NO",
            "-jobs", recommendedBuildJobs()
        ],
        cwd: directory,
        passthroughOutput: true
    )

    if build.status != 0 {
        fatalExit("MiniBrowser rebuild failed while applying the automatic WebGL helper injection patch.", code: 3)
    }
}

func buildWebKitFrameworkAndServices(at directory: URL) throws {
    let buildRoot = directory.appendingPathComponent("WebKitBuild", isDirectory: true)
    let precompiledHeaders = buildRoot.appendingPathComponent("PrecompiledHeaders", isDirectory: true)
    let build = try runCommand(
        executable: "/usr/bin/xcodebuild",
        arguments: [
            "-project", "Source/WebKit/WebKit.xcodeproj",
            "-scheme", "Framework, XPC Services, Extensions, and daemons",
            "-configuration", "Release",
            "-destination", "platform=macOS,arch=arm64",
            "SYMROOT=\(buildRoot.path)",
            "OBJROOT=\(buildRoot.path)",
            "SHARED_PRECOMPS_DIR=\(precompiledHeaders.path)",
            "SDKROOT=macosx",
            "COMPILATION_CACHE_ENABLE_CACHING=NO",
            "-jobs", recommendedBuildJobs()
        ],
        cwd: directory,
        passthroughOutput: true
    )

    if build.status != 0 {
        fatalExit("WebKit framework/XPC services repair build failed.", code: 3)
    }
}

func recommendedBuildJobs() -> String {
    String(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
}

func resolveWebKitDirectory(from raw: String?) -> URL {
    if let raw {
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)
        .appendingPathComponent("ngp", isDirectory: true)
        .appendingPathComponent("WebKit", isDirectory: true)
}

func hasWebKitScripts(_ directory: URL) -> Bool {
    let buildScript = directory.appendingPathComponent("Tools/Scripts/build-webkit").path
    let runScript = directory.appendingPathComponent("Tools/Scripts/run-minibrowser").path
    return FileManager.default.isExecutableFile(atPath: buildScript) && FileManager.default.isExecutableFile(atPath: runScript)
}

func hasMiniBrowserBuild(_ directory: URL) -> Bool {
    webKitBuildIssues(directory).isEmpty
}

func hasMiniBrowserArtifacts(_ directory: URL) -> Bool {
    let releaseDir = webKitBuildReleaseDirectory(directory)
    if !isDirectory(releaseDir) {
        return false
    }

    let requiredFrameworkBinary = releaseDir.appendingPathComponent("WebKit.framework/Versions/A/WebKit")
    if !fileExists(requiredFrameworkBinary) {
        return false
    }

    let candidates = [
        releaseDir.appendingPathComponent("MiniBrowser.app"),
        releaseDir.appendingPathComponent("MiniBrowser"),
        releaseDir.appendingPathComponent("MiniBrowser.app/Contents/MacOS/MiniBrowser")
    ]

    for candidate in candidates where fileExists(candidate) {
        return true
    }

    return false
}

func webKitBuildIssues(_ directory: URL) -> [String] {
    let releaseDir = webKitBuildReleaseDirectory(directory)
    guard isDirectory(releaseDir) else {
        return ["missing WebKitBuild/Release output directory"]
    }

    var issues: [String] = []
    let frameworkBinary = releaseDir.appendingPathComponent("WebKit.framework/Versions/A/WebKit")
    if !fileExists(frameworkBinary) {
        issues.append("missing WebKit.framework binary")
    }

    let miniBrowserBinary = releaseDir.appendingPathComponent("MiniBrowser.app/Contents/MacOS/MiniBrowser")
    if !fileExists(miniBrowserBinary) {
        issues.append("missing MiniBrowser.app")
    }

    let embeddedServicesDirectory = releaseDir.appendingPathComponent("WebKit.framework/Versions/A/XPCServices", isDirectory: true)
    let requiredServices = [
        "com.apple.WebKit.WebContent.xpc",
        "com.apple.WebKit.WebContent.Development.xpc",
        "com.apple.WebKit.Networking.xpc",
        "com.apple.WebKit.GPU.xpc"
    ]

    for service in requiredServices {
        let topLevelService = releaseDir.appendingPathComponent(service, isDirectory: true)
        guard fileExists(topLevelService) else {
            issues.append("missing \(service)")
            continue
        }

        let embeddedService = embeddedServicesDirectory.appendingPathComponent(service, isDirectory: true)
        guard fileExists(embeddedService) else {
            issues.append("missing WebKit.framework/XPCServices/\(service)")
            continue
        }

        if embeddedService.resolvingSymlinksInPath().standardizedFileURL.path != topLevelService.standardizedFileURL.path {
            issues.append("WebKit.framework/XPCServices/\(service) is not linked to the rebuilt top-level \(service)")
        }
    }

    return issues
}

func webKitBuildReleaseDirectory(_ directory: URL) -> URL {
    directory.appendingPathComponent("WebKitBuild/Release", isDirectory: true)
}

func miniBrowserExecutableURL(_ directory: URL) -> URL {
    webKitBuildReleaseDirectory(directory).appendingPathComponent("MiniBrowser.app/Contents/MacOS/MiniBrowser")
}

func ensureMiniBrowserHelperInjectionSupport(at directory: URL) throws -> Bool {
    let sourceURL = directory.appendingPathComponent("Tools/MiniBrowser/mac/AppDelegate.m")
    guard fileExists(sourceURL) else {
        fatalExit("MiniBrowser source file is missing at \(sourceURL.path)", code: 2)
    }

    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    if source.contains("NGP_WEBGL_HELPER_SCRIPT") {
        return false
    }

    let environmentFunction = """
    static NSString *ngpWebGLHelperScriptFromEnvironment(void)
    {
        NSString *script = [[[NSProcessInfo processInfo] environment] objectForKey:@"NGP_WEBGL_HELPER_SCRIPT"];
        if (![script isKindOfClass:[NSString class]] || ![script length])
            return nil;
        return script;
    }

    """

    let functionAnchor = "static BOOL sOpenWebInspector = NO;\n"
    guard let functionRange = source.range(of: functionAnchor) else {
        fatalExit("Unable to patch MiniBrowser: failed to find AppDelegate helper insertion point.", code: 3)
    }

    var patchedSource = source
    patchedSource.insert(contentsOf: environmentFunction, at: functionRange.upperBound)

    let configurationAnchor = "        configuration.websiteDataStore = [self persistentDataStore];\n"
    guard let configurationRange = patchedSource.range(of: configurationAnchor) else {
        fatalExit("Unable to patch MiniBrowser: failed to find configuration insertion point.", code: 3)
    }

    let configurationPatch = """
    
            NSString *ngpWebGLHelperScript = ngpWebGLHelperScriptFromEnvironment();
            if ([ngpWebGLHelperScript length]) {
                WKUserScript *userScript = [[WKUserScript alloc] initWithSource:ngpWebGLHelperScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
                [configuration.userContentController addUserScript:userScript];
                NSLog(@\"NGP WebGL helper user script installed.\");
            }
    """

    patchedSource.insert(contentsOf: configurationPatch, at: configurationRange.upperBound)
    try patchedSource.write(to: sourceURL, atomically: true, encoding: .utf8)
    return true
}

func ensureMiniBrowserWebGPUEnabled() throws {
    let result = try runCommand(
        executable: "/usr/bin/defaults",
        arguments: ["write", "org.webkit.MiniBrowser", "WebGPUEnabled", "-bool", "YES"]
    )

    if result.status != 0 {
        let details = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fatalExit("Failed to enable MiniBrowser WebGPU support via defaults write org.webkit.MiniBrowser WebGPUEnabled -bool YES.\n\(details)", code: 2)
    }
}

func webKitLaunchEnvironment(buildRoot: URL, captureEnabled: Bool, webGLHelperScript: String?) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["DYLD_FRAMEWORK_PATH"] = buildRoot.path
    environment["__XPC_DYLD_FRAMEWORK_PATH"] = buildRoot.path
    environment["DYLD_LIBRARY_PATH"] = buildRoot.path
    environment["__XPC_DYLD_LIBRARY_PATH"] = buildRoot.path
    environment["WEBKIT_UNSET_DYLD_FRAMEWORK_PATH"] = "YES"
    if captureEnabled {
        environment["__XPC_METAL_CAPTURE_ENABLED"] = "1"
    }
    if let webGLHelperScript, !webGLHelperScript.isEmpty {
        environment["NGP_WEBGL_HELPER_SCRIPT"] = webGLHelperScript
    }
    return environment
}

func synchronizeFrameworkXPCServices(at directory: URL) throws {
    let releaseDir = webKitBuildReleaseDirectory(directory)
    let embeddedServicesDirectory = releaseDir.appendingPathComponent("WebKit.framework/Versions/A/XPCServices", isDirectory: true)
    try ensureDirectoryExists(embeddedServicesDirectory)

    let services = [
        "com.apple.WebKit.WebContent.xpc",
        "com.apple.WebKit.WebContent.CaptivePortal.xpc",
        "com.apple.WebKit.WebContent.Development.xpc",
        "com.apple.WebKit.WebContent.EnhancedSecurity.xpc",
        "com.apple.WebKit.Networking.xpc",
        "com.apple.WebKit.GPU.xpc",
        "com.apple.WebKit.Model.xpc"
    ]

    let fileManager = FileManager.default
    for service in services {
        let embeddedService = embeddedServicesDirectory.appendingPathComponent(service, isDirectory: true)
        let topLevelService = releaseDir.appendingPathComponent(service, isDirectory: true)
        guard fileExists(topLevelService) else {
            continue
        }

        if fileExists(embeddedService) {
            try fileManager.removeItem(at: embeddedService)
        }

        let relativeTarget = "../../../../\(service)"
        try fileManager.createSymbolicLink(atPath: embeddedService.path, withDestinationPath: relativeTarget)
    }
}

func miniBrowserSmokeTestFailure(at directory: URL, timeoutSeconds: TimeInterval = 5) -> String? {
    let executable = miniBrowserExecutableURL(directory)
    guard fileExists(executable) else {
        return "missing MiniBrowser executable at \(executable.path)"
    }

    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let outputState = CaptureState()

    process.executableURL = executable
    process.arguments = ["--url", "about:blank", "--mac"]
    process.currentDirectoryURL = directory
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.environment = webKitLaunchEnvironment(buildRoot: webKitBuildReleaseDirectory(directory), captureEnabled: false, webGLHelperScript: nil)

    let consume: @Sendable (Data) -> Void = { data in
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }
        _ = outputState.append(text)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        consume(data)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        consume(data)
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return "failed to launch MiniBrowser: \(error)"
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var failureMessage: String?
    while Date() < deadline {
        let tail = outputState.tail(4000)
        if tail.contains("WebKit framework version mismatch") {
            failureMessage = tail
            break
        }
        if tail.contains("WebContent process crashed; reloading") {
            failureMessage = tail
            break
        }
        if !process.isRunning {
            failureMessage = "MiniBrowser exited with status \(process.terminationStatus).\n\(tail)"
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    terminate(process)

    return failureMessage
}

func isDirectory(_ url: URL) -> Bool {
    var isDir = ObjCBool(false)
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func shellQuote(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func parseCaptureToken(from log: String) -> String? {
    let patterns = [
        #"file:///[^[:space:]"]+"#,
        #"/private/var/folders/[^[:space:]"]*com\.apple\.WebKit\.GPU\+org\.webkit\.MiniBrowser[^[:space:]"]*"#,
        #"/var/folders/[^[:space:]"]*com\.apple\.WebKit\.GPU\+org\.webkit\.MiniBrowser[^[:space:]"]*"#
    ]

    for pattern in patterns {
        if let range = log.range(of: pattern, options: .regularExpression) {
            return String(log[range])
        }
    }

    return nil
}

func normalizedCapturePath(from token: String) -> String? {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
        return url.path
    }

    if trimmed.hasPrefix("/") {
        return trimmed
    }

    return nil
}

func captureCandidatesSnapshot() -> Set<String> {
    Set(captureCandidatePaths())
}

func latestCaptureCandidate(excluding baseline: Set<String>) -> String? {
    let fileManager = FileManager.default
    let candidates = captureCandidatePaths().filter { !baseline.contains($0) }
    if candidates.isEmpty {
        return nil
    }

    let sorted = candidates.sorted { lhs, rhs in
        let lhsDate = (try? URL(fileURLWithPath: lhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        let rhsDate = (try? URL(fileURLWithPath: rhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        if lhsDate == rhsDate {
            return lhs < rhs
        }
        return lhsDate > rhsDate
    }

    for path in sorted where fileManager.fileExists(atPath: path) {
        return path
    }

    return nil
}

func captureCandidatePaths() -> [String] {
    let fileManager = FileManager.default
    let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    guard let topLevelEntries = try? fileManager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return []
    }

    var candidates: [String] = []
    for entry in topLevelEntries where entry.lastPathComponent.hasPrefix("com.apple.WebKit.GPU+org.webkit.MiniBrowser") {
        candidates.append(entry.path)
        if let nestedEntries = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            candidates.append(contentsOf: nestedEntries.map(\.path))
        }
    }

    return candidates
}

func resolvedLaunchContext(baseURL: String, graphicsAPI: GraphicsAPI, webglMode: WebGLMode, runtime: CaptureRuntime = .chrome) throws -> LaunchContext {
    guard graphicsAPI == .webgl, webglMode == .wrapped else {
        return LaunchContext(launchURL: baseURL)
    }

    if runtime == .webkit {
        return LaunchContext(launchURL: baseURL)
    }

    let wrapperServer = try LocalHTTPServer(html: wrappedWebGLPageHTML(targetURL: baseURL))
    return LaunchContext(launchURL: wrapperServer.url.absoluteString, wrapperServer: wrapperServer)
}

func wrappedWebGLPageHTML(targetURL: String) -> String {
    let targetJSONString = jsonString(targetURL)
    return """
    <!doctype html>
    <html>
    <head>
      <meta charset=\"utf-8\" />
      <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
      <title>ngp-webgl-wrapper</title>
      <style>
        html, body { margin: 0; width: 100%; height: 100%; background: #000; }
        iframe { width: 100%; height: 100%; border: 0; display: block; }
        #ngp-webgpu-helper {
          position: fixed;
          top: 0;
          left: 0;
          width: 20px;
          height: 20px;
          opacity: 0.01;
          pointer-events: none;
          z-index: 2147483647;
        }
      </style>
    </head>
    <body>
      <canvas id=\"ngp-webgpu-helper\" width=\"20\" height=\"20\"></canvas>
      <iframe id=\"ngp-target\"></iframe>
      <script>
        const targetURL = \(targetJSONString);
        document.getElementById('ngp-target').src = targetURL;

        (async () => {
          try {
            if (!('gpu' in navigator)) {
              console.warn('[ngp] WebGPU unavailable. For WebGL capture, inject a helper script into your app and use --webgl-mode in-page.');
              return;
            }
            const canvas = document.getElementById('ngp-webgpu-helper');
            const adapter = await navigator.gpu.requestAdapter();
            if (!adapter) {
              console.warn('[ngp] No WebGPU adapter available.');
              return;
            }
            const device = await adapter.requestDevice();
            const context = canvas.getContext('webgpu');
            context.configure({ device, format: 'bgra8unorm' });

            function tick() {
              const textureView = context.getCurrentTexture().createView();
              const commandEncoder = device.createCommandEncoder();
              const pass = commandEncoder.beginRenderPass({
                colorAttachments: [{
                  view: textureView,
                  clearValue: { r: 1, g: 0, b: 0, a: 1 },
                  loadOp: 'clear',
                  storeOp: 'store'
                }]
              });
              pass.end();
              device.queue.submit([commandEncoder.finish()]);
              requestAnimationFrame(tick);
            }

            requestAnimationFrame(tick);
          } catch (error) {
            console.error('[ngp] WebGL helper setup failed:', error);
          }
        })();
      </script>
    </body>
    </html>
    """
}

func jsonString(_ value: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [value]),
       let json = String(data: data, encoding: .utf8) {
        // JSON array containing one element, strip [ and ]
        return String(json.dropFirst().dropLast())
    }
    return "\"\""
}

final class LocalHTTPServer: @unchecked Sendable {
    let url: URL

    private let responseBody: Data
    private let port: UInt16
    private let lock = NSLock()
    private var listeningSocket: Int32
    private var isStopping = false

    init(html: String) throws {
        responseBody = Data(html.utf8)

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw RuntimeError(message: "socket() failed: \(errnoDescription())")
        }

        var reuseAddress: Int32 = 1
        if setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            let error = errnoDescription()
            close(socket)
            throw RuntimeError(message: "setsockopt(SO_REUSEADDR) failed: \(error)")
        }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(0),
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = errnoDescription()
            close(socket)
            throw RuntimeError(message: "bind(127.0.0.1) failed: \(error)")
        }

        guard Darwin.listen(socket, 16) == 0 else {
            let error = errnoDescription()
            close(socket)
            throw RuntimeError(message: "listen() failed: \(error)")
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socketNameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socket, sockaddrPointer, &boundAddressLength)
            }
        }
        guard socketNameResult == 0 else {
            let error = errnoDescription()
            close(socket)
            throw RuntimeError(message: "getsockname() failed: \(error)")
        }

        listeningSocket = socket
        port = UInt16(bigEndian: boundAddress.sin_port)
        url = URL(string: "http://localhost:\(port)/index.html")!

        let acceptQueue = DispatchQueue(label: "ngp.wrapper-http-server.\(port)")
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        stop()
    }

    func stop() {
        let socketToClose: Int32
        lock.lock()
        if isStopping || listeningSocket < 0 {
            lock.unlock()
            return
        }
        isStopping = true
        socketToClose = listeningSocket
        listeningSocket = -1
        lock.unlock()

        wakeAcceptLoop()
        Darwin.shutdown(socketToClose, SHUT_RDWR)
        close(socketToClose)
    }

    private func acceptLoop() {
        while true {
            let clientSocket = Darwin.accept(listeningSocket, nil, nil)
            if clientSocket < 0 {
                if shouldStop {
                    return
                }
                if errno == EINTR {
                    continue
                }
                return
            }

            if shouldStop {
                close(clientSocket)
                return
            }

            handleClient(clientSocket)
        }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopping
    }

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let request = readRequest(from: clientSocket)
        let path = requestedPath(from: request)
        let response = responseData(for: path)

        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            var bytesSent = 0
            while bytesSent < response.count {
                let result = Darwin.send(clientSocket, baseAddress.advanced(by: bytesSent), response.count - bytesSent, 0)
                if result <= 0 {
                    break
                }
                bytesSent += result
            }
        }
    }

    private func readRequest(from clientSocket: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < 16384 {
            let bytesRead = Darwin.recv(clientSocket, &buffer, buffer.count, 0)
            if bytesRead <= 0 {
                break
            }

            data.append(buffer, count: bytesRead)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func requestedPath(from request: String) -> String {
        guard let requestLine = request.split(whereSeparator: \.isNewline).first else {
            return "/"
        }

        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else {
            return "/"
        }

        return String(components[1])
    }

    private func responseData(for path: String) -> Data {
        if path == "/" || path == "/index.html" {
            return httpResponse(
                statusLine: "HTTP/1.1 200 OK",
                contentType: "text/html; charset=utf-8",
                body: responseBody
            )
        }

        if path == "/favicon.ico" {
            return httpResponse(
                statusLine: "HTTP/1.1 204 No Content",
                contentType: "image/x-icon",
                body: Data()
            )
        }

        return httpResponse(
            statusLine: "HTTP/1.1 404 Not Found",
            contentType: "text/plain; charset=utf-8",
            body: Data("not found".utf8)
        )
    }

    private func httpResponse(statusLine: String, contentType: String, body: Data) -> Data {
        let headers = statusLine + "\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        var response = Data(headers.utf8)
        response.append(body)
        return response
    }

    private func wakeAcceptLoop() {
        let clientSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            return
        }
        defer { close(clientSocket) }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(clientSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

func errnoDescription() -> String {
    String(cString: strerror(errno))
}

func terminate(_ process: Process) {
    guard process.isRunning else {
        return
    }

    process.terminate()

    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }

    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

func fatalExit(_ message: String, code: Int32) -> Never {
    if let data = "error: \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    Foundation.exit(code)
}

let webGLHelperSnippet = """
(() => {
  if (window.__ngpWebGLHelperInstalled) {
    return;
  }
  window.__ngpWebGLHelperInstalled = true;

  const install = async () => {
    if (!document.body) {
      window.addEventListener('DOMContentLoaded', install, { once: true });
      return;
    }

  if (!('gpu' in navigator)) {
    console.warn('[ngp] WebGPU unavailable; WebGL capture may not be visible to Xcode.');
    return;
  }

  const canvas = document.createElement('canvas');
  canvas.width = 20;
  canvas.height = 20;
  canvas.style.position = 'fixed';
  canvas.style.top = '0';
  canvas.style.left = '0';
  canvas.style.opacity = '0.01';
  canvas.style.pointerEvents = 'none';
  canvas.style.zIndex = '2147483647';
  document.body.appendChild(canvas);

    try {
      const adapter = await navigator.gpu.requestAdapter();
      if (!adapter) {
        console.warn('[ngp] No WebGPU adapter available.');
        return;
      }
      const device = await adapter.requestDevice();
      const context = canvas.getContext('webgpu');
      context.configure({ device, format: 'bgra8unorm' });

      const frame = () => {
        const view = context.getCurrentTexture().createView();
        const encoder = device.createCommandEncoder();
        const pass = encoder.beginRenderPass({
          colorAttachments: [{
            view,
            clearValue: { r: 1, g: 0, b: 0, a: 1 },
            loadOp: 'clear',
            storeOp: 'store'
          }]
        });
        pass.end();
        device.queue.submit([encoder.finish()]);
        requestAnimationFrame(frame);
      };

      console.log('[ngp] WebGL helper armed.');
      requestAnimationFrame(frame);
    } catch (err) {
      console.error('[ngp] Failed to initialize WebGPU helper:', err);
    }
  };

  install();
})();
"""

func webKitInjectedWebGLHelperScript(graphicsAPI: GraphicsAPI, webglMode: WebGLMode) -> String? {
    guard graphicsAPI == .webgl, webglMode == .wrapped else {
        return nil
    }

    return webGLHelperSnippet
}
