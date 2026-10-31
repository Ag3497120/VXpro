// The compositor loop of VX Mac Host's immersive space: as VX Runtime's (avp-port xros/app/Sources/VXImmersive.swift,
// copied with the names changed): every compositor frame the head's pose (ARKit), then each eye warped from the
// program's newest frame by the shared presenter (../../vr/xros_vr.m), depth for the system's late reprojection;
// the hands to the presenter (pointer, pinches as clicks). Added: the frame's presentation time to libvxmtl's
// CAMetalDisplayLink stand-in (vxmtl_displaylink_tick).
import ARKit
import CompositorServices
import Metal
import QuartzCore
import simd

final class VXMacImmersiveRenderer: @unchecked Sendable {
    private let layerRenderer: LayerRenderer
    private let queue: MTLCommandQueue
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let handTracking = HandTrackingProvider()
    private var tracking = false
    private var hands = false
    private var lastReport = CACurrentMediaTime()
    private var cleared = 0
    private static let near: Float = 0.1, far: Float = 10000

    static func start(_ layerRenderer: LayerRenderer) {
        guard let q = layerRenderer.device.makeCommandQueue() else {
            vxmac_jlog("vr_error", "\"what\":\"no command queue\"")
            return
        }
        let r = VXMacImmersiveRenderer(layerRenderer, q)
        Task {
            // (hand tracking: the pointer, clicks and the wheel for the game, src/xros_vr.m vx_xros_vr_hands; the system
            // asks the person once, NSHandsTrackingUsageDescription)
            var handsOK = false
            if HandTrackingProvider.isSupported {
                let auth = await r.arSession.requestAuthorization(for: [.handTracking])
                handsOK = auth[.handTracking] == .allowed
                vxmac_jlog("input_source", "\"source\":\"hand_tracking\",\"supported\":1,\"authorization\":\"\(auth[.handTracking].map { "\($0)" } ?? "none")\"")
            } else {
                vxmac_jlog("input_source", "\"source\":\"hand_tracking\",\"supported\":0")
            }
            if WorldTrackingProvider.isSupported {
                do {
                    if handsOK { try await r.arSession.run([r.worldTracking, r.handTracking]); r.hands = true }
                    else { try await r.arSession.run([r.worldTracking]) }
                    r.tracking = true
                } catch {
                    vxmac_jlog("vr_error", "\"what\":\"tracking: \(error.localizedDescription)\",\"with_hands\":\(handsOK)")
                    if handsOK {
                        do { try await r.arSession.run([r.worldTracking]); r.tracking = true }
                        catch { vxmac_jlog("vr_error", "\"what\":\"world tracking: \(error.localizedDescription)\"") }
                    }
                }
            }
            vxmac_jlog("input_source", "\"source\":\"hand_tracking\",\"running\":\(r.hands ? 1 : 0)")
            let thread = Thread { r.loop() }
            thread.name = "VX Mac compositor"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    private init(_ layerRenderer: LayerRenderer, _ queue: MTLCommandQueue) {
        self.layerRenderer = layerRenderer
        self.queue = queue
        queue.label = "VX Mac compositor"
    }

    private static func seconds(_ i: LayerRenderer.Clock.Instant) -> Double {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: i).components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    private func loop() {
        let cfg = layerRenderer.configuration
        vxmac_jlog("vr_start", "\"foveation\":\(cfg.isFoveationEnabled),\"layout\":\"\(cfg.layout)\",\"color\":\(cfg.colorFormat.rawValue),\"depth\":\(cfg.depthFormat.rawValue),\"tracking\":\(tracking)")
        vxmac_vr_space_set(1)
        while true {
            switch layerRenderer.state {
            case .invalidated:
                vxmac_jlog("vr_end", "\"why\":\"layer invalidated\"")
                vxmac_vr_space_set(0)
                return
            case .paused:
                vxmac_jlog("vr_paused", nil)
                layerRenderer.waitUntilRunning()
                vxmac_jlog("vr_running", nil)
                continue
            default:
                autoreleasepool { frame() }
            }
        }
    }

    private func frame() {
        guard let frame = layerRenderer.queryNextFrame() else { Thread.sleep(forTimeInterval: 0.001); return }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        // (no drawables: the system cancelled this frame; ending its submission would abort the app)
        guard !drawables.isEmpty else { return }
        let presentation = Self.seconds(timing.presentationTime)
        vxmtl_displaylink_tick(presentation)
        let anchor = tracking ? worldTracking.queryDeviceAnchor(atTimestamp: presentation) : nil
        var head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let have = withUnsafePointer(to: &head) {
            $0.withMemoryRebound(to: Float.self, capacity: 16) { vx_xros_vr_begin_frame($0, presentation) }
        }
        guard let cb = queue.makeCommandBuffer() else { vx_xros_vr_end_frame(nil); frame.endSubmission(); return }
        cb.label = "VX eyes"
        let cbp = Unmanaged.passUnretained(cb as AnyObject).toOpaque()
        for d in drawables {
            d.deviceAnchor = anchor
            d.depthRange = SIMD2<Float>(Self.far, Self.near)
            for i in d.views.indices {
                let color = d.colorTextures[min(i, d.colorTextures.count - 1)]
                let depth = d.depthTextures[min(i, d.depthTextures.count - 1)]
                var ok: Int32 = 0
                if have != 0 {
                    let maps = d.rasterizationRateMaps
                    vx_xros_vr_set_rate_map(maps.isEmpty ? nil : Unmanaged.passUnretained(maps[min(i, maps.count - 1)] as AnyObject).toOpaque())
                    var viewFromOrigin = (head * d.views[i].transform).inverse
                    // the eye's frustum from its projection (right-up-back: x_ndc = (P00 x + P20 z) / -z)
                    let p = d.computeProjection(convention: .rightUpBack, viewIndex: i)
                    var tan = SIMD4<Float>((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                                           (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
                    ok = withUnsafePointer(to: &viewFromOrigin) { vp in
                        vp.withMemoryRebound(to: Float.self, capacity: 16) { v in
                            withUnsafePointer(to: &tan) { tp in
                                tp.withMemoryRebound(to: Float.self, capacity: 4) { t in
                                    vx_xros_vr_draw_eye(cbp, Int32(i), v, t, Self.near,
                                                        Unmanaged.passUnretained(color as AnyObject).toOpaque(),
                                                        Unmanaged.passUnretained(depth as AnyObject).toOpaque())
                                }
                            }
                        }
                    }
                }
                if ok == 0 { clear(cb, color, depth) }
            }
            d.encodePresent(commandBuffer: cb)
        }
        vx_xros_vr_end_frame(cbp)
        cb.commit()
        frame.endSubmission()
        // (the hands after the frame is submitted, from the provider's latest anchors: a query here never delays a
        // frame; with handAnchors(at:) before the submission the compositor fell to 45 Hz, h2b)
        if hands { feedHands(head) }
        report()
    }

    // Both hands' thumb tip, index tip and pointing anchor (between the index finger's and the thumb's knuckles) in the
    // room, for the runtime's hand input.
    private var handsLogged = false
    private func feedHands(_ head: simd_float4x4) {
        let (left, right) = handTracking.latestAnchors
        var v = [Float](repeating: 0, count: 20)
        for (k, a) in [left, right].enumerated() {
            guard let a, a.isTracked, let sk = a.handSkeleton else { continue }
            func p(_ j: HandSkeleton.JointName) -> SIMD3<Float> {
                let m = a.originFromAnchorTransform * sk.joint(j).anchorFromJointTransform
                return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            }
            let thumb = p(.thumbTip), index = p(.indexFingerTip)
            let anchor = (p(.indexFingerKnuckle) + p(.thumbKnuckle)) * 0.5
            v[k * 10] = 1
            for i in 0..<3 { v[k * 10 + 1 + i] = thumb[i]; v[k * 10 + 4 + i] = index[i]; v[k * 10 + 7 + i] = anchor[i] }
        }
        if !handsLogged && (v[0] > 0 || v[10] > 0) {
            handsLogged = true
            vxmac_jlog("input_source", "\"source\":\"hand_tracking\",\"first_hand\":\"\(v[10] > 0 ? "right" : "left")\"")
        }
        var h = head
        withUnsafePointer(to: &h) { hp in
            hp.withMemoryRebound(to: Float.self, capacity: 16) { m in v.withUnsafeBufferPointer { vx_xros_vr_hands(m, $0.baseAddress, CACurrentMediaTime()) } }
        }
    }

    // (no game frame yet: a dark grey room, depth far)
    private func clear(_ cb: MTLCommandBuffer, _ color: MTLTexture, _ depth: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cleared += 1
    }

    private func report() {
        let now = CACurrentMediaTime()
        guard now - lastReport >= 1 else { return }
        lastReport = now
        var buf = [CChar](repeating: 0, count: 2048)
        vx_xros_vr_stats(&buf, UInt32(buf.count))
        let fields = String(cString: buf) + ",\"cleared_eyes\":\(cleared)"
        cleared = 0
        vxmac_jlog("vr", fields)
    }
}
