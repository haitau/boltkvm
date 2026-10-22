import Foundation
import AppKit
import Metal
import MetalKit
import CoreVideo

final class DisplayModeSwitcher {
    private let displayID = CGMainDisplayID()
    private var original: CGDisplayMode?

    func switchTo4K1x() -> Bool {
        original = CGDisplayCopyDisplayMode(displayID)
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return false }
        let candidates = modes.filter {
            $0.pixelWidth == 3840 && $0.pixelHeight == 2160 &&
            $0.width == 3840 && $0.height == 2160 &&
            $0.refreshRate >= 59.0
        }
        guard let mode = candidates.first else {
            log("no 1x 3840x2160@60 mode found; modes=\(modes.count)")
            for m in modes where m.pixelWidth == 3840 {
                log("  mode pixel=\(m.pixelWidth)x\(m.pixelHeight) logical=\(m.width)x\(m.height) \(m.refreshRate)Hz")
            }
            return false
        }
        for attempt in 1...3 {
            let st = CGDisplaySetDisplayMode(displayID, mode, nil)
            if st == .success {
                log("switch display mode -> \(mode.width)x\(mode.height) 1x: ok (attempt \(attempt))")
                return true
            }
            log("switch display mode attempt \(attempt) failed: \(st.rawValue)")
            usleep(300_000)
        }
        log("switch display mode failed; continuing at current mode")
        return false
    }

    func restore() {
        guard let original else { return }
        let st = CGDisplaySetDisplayMode(displayID, original, nil)
        log("restore display mode: \(st == .success ? "ok" : "failed \(st.rawValue)")")
    }
}

struct ColorParams {
    var fullRange: Float
    var tenBit: Float
}

/// Must match `struct ViewParams` in the shader source (one float2).
struct ViewParams {
    var scale: SIMD2<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    let view: MTKView
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Aspect ratio of the picture currently on screen; the input map needs it to
    /// know where the letterbox bars are.
    private var pictureAspect: CGFloat = 0
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestCaptureMicros: Int64 = 0
    private var drawPending = false
    private var latencies: [Double] = []
    private var loggedTexture = false
    private var frames = 0
    private var firstAt: UInt64 = 0
    // Rolling window, reset by reportWindow() so a long run yields a time
    // series (fps/P95 drift) instead of a single number at exit.
    private var winFrames = 0
    private var winLatencies: [Double] = []
    private var winStart: UInt64 = 0
    // Queueing delay scales with encoded frame size, so the alert line has to
    // as well. Measured 2026-10-22 (4K drawable, 51 fps present ceiling):
    // 25 KB/frame -> p95 35.9 ms, 89 KB -> 30.5 ms, 2480 KB -> 48.4 ms.
    private var budgetMs: Double = 33
    private var sloWindows = 0
    private var sloHits = 0
    private var tierBreaches = 0

    init(device: MTLDevice) throws {
        self.device = device
        winStart = DispatchTime.now().uptimeNanoseconds
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "render", code: 1) }
        queue = q
        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // Experiment knobs for the 51 fps present ceiling; defaults keep the
        // shipping behaviour (no vsync, 60 fps cap, system drawable count).
        let env = ProcessInfo.processInfo.environment
        let preferred = Int(env["BOLTKVM_PREFERRED_FPS"] ?? "") ?? 60
        view.preferredFramesPerSecond = preferred
        // Syncing to the display refresh is what keeps presentation at 60 fps.
        // Turning it off (the old default) let the compositor coalesce frames:
        // measured 48.8 fps vs 59.5 fps, and the extra queueing also pushed
        // P95 up. Keep it on; BOLTKVM_DISPLAY_SYNC=0 restores the old behaviour.
        let sync = (env["BOLTKVM_DISPLAY_SYNC"] ?? "1") != "0"
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = sync
        if let n = Int(env["BOLTKVM_DRAWABLES"] ?? ""), n > 0 {
            (view.layer as? CAMetalLayer)?.maximumDrawableCount = n
        }
        view.presentsWithTransaction = false

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        struct ViewParams { float2 scale; };
        vertex VOut vmain(uint vid [[vertex_id]], constant ViewParams &vp [[buffer(0)]]) {
            float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            // Scale keeps the picture at its own aspect ratio and leaves black
            // bars instead of stretching it to fill the window.
            float2 q = p[vid] * vp.scale;
            VOut o;
            o.pos = float4(q, 0.0, 1.0);
            o.uv = (q + 1.0) * 0.5;
            o.uv.y = 1.0 - o.uv.y;
            return o;
        }
        struct ColorParams { float fullRange; float tenBit; };
        fragment float4 fmain(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> cTex [[texture(1)]],
                              constant ColorParams &p [[buffer(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float y = yTex.sample(s, in.uv).r;
            float2 c = cTex.sample(s, in.uv).rg;
            float yy, cb, cr;
            if (p.tenBit > 0.5) {
                float y10 = y * 1023.0;
                float2 c10 = c * 1023.0;
                if (p.fullRange > 0.5) {
                    yy = y10 / 1023.0;
                } else {
                    yy = (y10 - 64.0) / (940.0 - 64.0);
                }
                cb = c10.x / 1023.0 - 0.5;
                cr = c10.y / 1023.0 - 0.5;
            } else {
                yy = p.fullRange > 0.5 ? y : (y - 16.0/255.0) * (255.0/219.0);
                cb = c.x - 0.5;
                cr = c.y - 0.5;
            }
            float r = yy + 1.5748 * cr;
            float g = yy - 0.1873 * cb - 0.4681 * cr;
            float b = yy + 1.8556 * cb;
            return float4(r, g, b, 1.0);
        }
        """
        let lib = try device.makeLibrary(source: src, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        super.init()
        view.delegate = self
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func attach(to window: NSWindow) {
        view.frame = window.contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        window.contentView = view
    }

    var imageAspect: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return pictureAspect
    }

    func submit(_ pb: CVPixelBuffer, captureLocalMicros: Int64) {
        lock.lock()
        latest = pb
        latestCaptureMicros = captureLocalMicros
        drawPending = true
        lock.unlock()
    }

    func draw(in view: MTKView) {
        lock.lock()
        guard let pb = latest else { lock.unlock(); return }
        let captureMicros = latestCaptureMicros
        latest = nil
        drawPending = false
        lock.unlock()

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cache = textureCache,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        guard CVPixelBufferGetPlaneCount(pb) >= 2 else {
            log("render: non-planar pixel buffer format \(CVPixelBufferGetPixelFormatType(pb))")
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1)
        let ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let is10 = fmt == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        let isFull = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_422YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        var yRef: CVMetalTexture?
        var cRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, is10 ? .r16Unorm : .r8Unorm, w, h, 0, &yRef)
        let cStatus = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, is10 ? .rg16Unorm : .rg8Unorm, cw, ch, 1, &cRef)
        if !loggedTexture {
            loggedTexture = true
            log("render texture fmt=0x\(String(fmt, radix: 16)) is10=\(is10) planes=\(CVPixelBufferGetPlaneCount(pb)) ioSurface=\(CVPixelBufferGetIOSurface(pb) != nil) yStatus=\(yStatus) cStatus=\(cStatus) size=\(w)x\(h) chroma=\(cw)x\(ch)")
        }
        guard let yRef, let cRef,
              let yTex = CVMetalTextureGetTexture(yRef),
              let cTex = CVMetalTextureGetTexture(cRef) else {
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }

        let viewAspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let imgAspect = Float(w) / Float(max(1, h))
        var viewParams = ViewParams(scale: SIMD2<Float>(1, 1))
        if viewAspect > imgAspect {
            viewParams.scale.x = imgAspect / viewAspect
        } else {
            viewParams.scale.y = viewAspect / imgAspect
        }
        lock.lock(); pictureAspect = CGFloat(imgAspect); lock.unlock()

        var params = ColorParams(fullRange: isFull ? 1.0 : 0.0, tenBit: is10 ? 1.0 : 0.0)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&viewParams, length: MemoryLayout<ViewParams>.size, index: 0)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        let latency = Double(Int64(Date().timeIntervalSince1970 * 1_000_000) - captureMicros) / 1000.0
        lock.lock()
        if captureMicros > 0 && latency > 0 && latency < 10_000 {
            latencies.append(latency)
            winLatencies.append(latency)
        }
        frames += 1
        winFrames += 1
        if firstAt == 0 { firstAt = DispatchTime.now().uptimeNanoseconds }
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Called by the receive loop each window with the average encoded frame
    /// size. The 33 ms SLO stays the product target; this only sets the alert
    /// line so a 1.2 Gbps ProRes stream stops flagging every single minute.
    func setBudget(_ ms: Double) {
        lock.lock(); budgetMs = ms; lock.unlock()
    }

    static func budget(forFrameKB kb: Double) -> Double {
        if kb >= 512 { return 55 }
        if kb >= 64 { return 40 }
        return 33
    }

    func report() {
        // Copy under the lock: draw() keeps appending from the render thread,
        // and reading the array outside the lock raced with it.
        lock.lock()
        let f = frames, first = firstAt
        let sorted = latencies.sorted()
        let budget = budgetMs
        lock.unlock()
        let e = first > 0 ? Double(DispatchTime.now().uptimeNanoseconds - first) / 1e9 : 0
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxv = sorted.last ?? 0
        log(String(format: "render frames=%d elapsed=%.2fs fps=%.1f drawable=%.0fx%.0f latency p50=%.1fms p95=%.1fms max=%.1fms",
                   f, e, e > 0 ? Double(f) / e : 0,
                   view.drawableSize.width, view.drawableSize.height, p50, p95, maxv))
        log(String(format: "SLO33 windows hit=%d/%d (%.0f%%) tierBreaches=%d",
                   sloHits, sloWindows,
                   sloWindows > 0 ? Double(sloHits) / Double(sloWindows) * 100 : 0, tierBreaches))
        if p95 > budget { log("WARNING: capture→present P95 \(String(format: "%.1f", p95))ms exceeds tier budget \(String(format: "%.0f", budget))ms") }
    }

    /// Per-interval line for long runs: each call covers the frames drawn since
    /// the previous call, so drift shows up as a series of 60s windows.
    func reportWindow() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let start = winStart == 0 ? now : winStart
        let f = winFrames
        let sorted = winLatencies.sorted()
        winFrames = 0
        winLatencies.removeAll(keepingCapacity: true)
        winStart = now
        let total = frames
        lock.unlock()

        lock.lock()
        let budget = budgetMs
        lock.unlock()
        let e = Double(now - start) / 1e9
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxv = sorted.last ?? 0
        log(String(format: "render.win elapsed=%.1fs frames=%d total=%d fps=%.1f drawable=%.0fx%.0f p50=%.1fms p95=%.1fms max=%.1fms budget=%.0fms",
                   e, f, total, e > 0 ? Double(f) / e : 0,
                   view.drawableSize.width, view.drawableSize.height, p50, p95, maxv, budget))
        lock.lock()
        if sorted.count > 0 {
            sloWindows += 1
            if p95 <= 33 { sloHits += 1 }
            if p95 > budget { tierBreaches += 1 }
        }
        lock.unlock()
        if sorted.count > 0 && p95 > budget {
            log("WARNING: window P95 \(String(format: "%.1f", p95))ms exceeds tier budget \(String(format: "%.0f", budget))ms (SLO 33ms)")
        }
        if f == 0 {
            log("WARNING: window drew 0 frames (display asleep, occluded, or decoder stalled)")
        }
    }
}

final class RenderSession: NSObject, NSApplicationDelegate {
    static let shared = RenderSession()
    private var window: NSWindow?
    private(set) var renderer: Renderer?
    private var modeSwitcher = DisplayModeSwitcher()
    private var switchedMode = false
    var decoder: VideoDecoder?
    private(set) var inputCapture: InputCapture?
    private var statsTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?

    func stopInput() {
        inputCapture?.stop()
        inputCapture = nil
    }

    func restartInput(conn: TCPConnection) {
        stopInput()
        startInput(conn: conn)
    }

    func startInput(conn: TCPConnection) {
        guard inputCapture == nil else { return }
        let cap = InputCapture(conn: conn)
        if cap.start() {
            inputCapture = cap
        } else {
            log("input: not started")
        }
    }

    func start(switchMode: Bool) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        // The server and pattern modes already assert this; the render client did
        // not, so macOS was free to sleep the display mid-run, which stalls
        // MTKView and silently zeroes the render leg of a long test.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: "boltkvm client render"
        )
        do {
            let r = try Renderer(device: device)
            renderer = r
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 3840, height: 2160)
            let w = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = .black
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            r.attach(to: w)
            window = w
            NSApplication.shared.presentationOptions = [.hideDock, .hideMenuBar]
            w.orderFrontRegardless()
            w.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                w.orderFrontRegardless()
            }
            if switchMode {
                switchedMode = modeSwitcher.switchTo4K1x()
                w.setFrame(NSScreen.main?.frame ?? screen, display: true)
            }
            r.view.needsDisplay = true
            w.displayIfNeeded()
            let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
            let env = ProcessInfo.processInfo.environment
            let syncEffective = (env["BOLTKVM_DISPLAY_SYNC"] ?? "1") != "0"
            log("render window ready drawable=\(r.view.drawableSize.width)x\(r.view.drawableSize.height) switched=\(switchedMode) display=\(mode?.width ?? 0)x\(mode?.height ?? 0)@\(mode?.refreshRate ?? 0)Hz pref=\(env["BOLTKVM_PREFERRED_FPS"] ?? "60") sync=\(syncEffective ? 1 : 0)")
            // 60s cadence: one line per minute makes an 8h run a readable
            // series (fps/P95 drift, input liveness) instead of a single tail.
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 60, repeating: 60)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.renderer?.reportWindow()
                if let cap = self.inputCapture {
                    log("input.win sent=\(cap.sentEvents) tapDisabled=\(cap.tapDisabledCount)")
                } else {
                    log("input.win active=0")
                }
            }
            t.resume()
            statsTimer = t
        } catch {
            log("renderer init failed: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statsTimer?.cancel()
        statsTimer = nil
        inputCapture?.stop()
        if switchedMode { modeSwitcher.restore() }
        renderer?.report()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
