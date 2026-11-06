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
    private let systemStereo = vx_xros_vr_system_stereo() != 0
    private var tracking = false
    private var hands = false
    private var lastReport = CACurrentMediaTime()
    private var cleared = 0
    // (h60c: the compositor's pacing, every 5 s - how late the frame starts against its optimal input time, how long from
    //  there to the commit, the GPU's end against the frame's rendering deadline (misses), the presentation interval (11 ms
    //  at 90 Hz, 22 at 45): does the system drop us to half rate because our frames miss their deadline?)
    private let pace = PaceStats()
    final class PaceStats: @unchecked Sendable {
        let lock = NSLock()
        var n = 0, misses = 0, gpuN = 0, lastPres = 0.0, presSum = 0.0, presN = 0, presMax = 0.0
        var late = 0.0, lateMax = 0.0, sub = 0.0, subMax = 0.0, margin = 0.0, marginMin = 1e9, gpu = 0.0, last = CACurrentMediaTime()
    }
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
        let tq = CACurrentMediaTime()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        let toi = Self.seconds(timing.optimalInputTime), tdl = Self.seconds(timing.renderingDeadline), tpr = Self.seconds(timing.presentationTime)
        let tw = CACurrentMediaTime()
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
            if systemStereo && d.views.count == 2 {
                var left = d.views[0].transform
                var right = d.views[1].transform
                withUnsafePointer(to: &left) { lp in
                    lp.withMemoryRebound(to: Float.self, capacity: 16) { l in
                        withUnsafePointer(to: &right) { rp in
                            rp.withMemoryRebound(to: Float.self, capacity: 16) { r in
                                vx_xros_vr_set_eye_views(l, r)
                            }
                        }
                    }
                }
            } else if systemStereo {
                vx_xros_vr_set_eye_views(nil, nil)
            }
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
        let ps = pace
        cb.addCompletedHandler { c in
            ps.lock.lock()
            ps.gpuN += 1; ps.gpu += (c.gpuEndTime - c.gpuStartTime) * 1e3
            let m = (tdl - c.gpuEndTime) * 1e3; ps.margin += m; if m < ps.marginMin { ps.marginMin = m }; if m < 0 { ps.misses += 1 }
            ps.lock.unlock()
        }
        cb.commit()
        frame.endSubmission()
        do {
            let tc = CACurrentMediaTime()
            pace.lock.lock()
            pace.n += 1
            let lt = (tw - toi) * 1e3; pace.late += lt; if lt > pace.lateMax { pace.lateMax = lt }
            let sb = (tc - tw) * 1e3; pace.sub += sb; if sb > pace.subMax { pace.subMax = sb }
            if pace.lastPres > 0 { let d = (tpr - pace.lastPres) * 1e3; if d > 0 && d < 200 { pace.presSum += d; pace.presN += 1; if d > pace.presMax { pace.presMax = d } } }
            pace.lastPres = tpr
            if tc - pace.last >= 5 {
                let f = String(format: "\"frames\":%d,\"present_interval_ms\":%.2f,\"present_interval_max_ms\":%.1f,\"start_late_ms\":%.2f,\"start_late_max_ms\":%.1f,\"input_to_commit_ms\":%.2f,\"input_to_commit_max_ms\":%.1f,\"gpu_ms\":%.2f,\"deadline_margin_ms\":%.2f,\"deadline_margin_min_ms\":%.1f,\"missed\":%d,\"query_to_input_ms\":%.1f",
                                   pace.n, pace.presN > 0 ? pace.presSum / Double(pace.presN) : 0, pace.presMax, pace.late / Double(pace.n), pace.lateMax, pace.sub / Double(pace.n), pace.subMax,
                                   pace.gpuN > 0 ? pace.gpu / Double(pace.gpuN) : 0, pace.gpuN > 0 ? pace.margin / Double(pace.gpuN) : 0, pace.marginMin, pace.misses, (toi - tq) * 1e3)
                vxmtl_compositor_interval(pace.presN > 0 ? pace.presSum / Double(pace.presN) : 0)
                vxmtl_pacing_report(Int32(pace.misses))
                pace.n = 0; pace.misses = 0; pace.gpuN = 0; pace.presSum = 0; pace.presN = 0; pace.presMax = 0; pace.late = 0; pace.lateMax = 0
                pace.sub = 0; pace.subMax = 0; pace.margin = 0; pace.marginMin = 1e9; pace.gpu = 0; pace.last = tc
                pace.lock.unlock()
                vxmac_jlog("compositor_pacing", f)
            } else { pace.lock.unlock() }
        }
        // (the hands after the frame is submitted, from the provider's latest anchors: a query here never delays a
        // frame; with handAnchors(at:) before the submission the compositor fell to 45 Hz, h2b)
        if hands { feedHands(head) }
        report()
    }

    // Both hands' thumb tip, index tip and pointing anchor (between the index finger's and the thumb's knuckles) in the
    // room, for the runtime's hand input.
    private var handsLogged = false
    private var wristBasis = [(forward: SIMD3<Float>, across: SIMD3<Float>)?](repeating: nil, count: 2)
    private var wristOffset = [SIMD3<Float>](repeating: .zero, count: 2)
    private var wristCalibrated = [Bool](repeating: false, count: 2)
    private var joyWristIDs = [UUID?](repeating: nil, count: 2)
    private var joyAnchors = [(anchor: HandAnchor, received: Double)?](repeating: nil, count: 2)
    private lazy var joyWristTracking = vx_xros_vr_bare_enabled() == 0 &&
        getenv("VXMAC_JOY_HOLD").map { String(cString: $0) == "1" } == true
    private func feedHands(_ head: simd_float4x4) {
        let (left, right) = handTracking.latestAnchors
        let now = CACurrentMediaTime()
        var v = [Float](repeating: 0, count: 20)
        var j = [Float](repeating: 0, count: 50)      // (h70: the joints for the magazine by hand, vr/hand_weapon.h)
        var arms = [Float](repeating: 0, count: 14)
        var skeleton = [Float](repeating: 0, count: 134)
        var wrists = [Float](repeating: 0, count: 20)
        var middlePinch = [Float](repeating: -1, count: 2)
        let bare = vx_xros_vr_bare_enabled() != 0
        let joy = joyWristTracking
        let buttons = vx_xros_vr_controller_buttons(now)
        for (k, update) in [left, right].enumerated() {
            var sample = update
            if joy {
                // Reading latestAnchors consumes each update. An empty read between
                // samples must not cancel a grip or make one hand disappear.
                if let update, update.isTracked { joyAnchors[k] = (update, now) }
                if handTracking.state != .running { joyAnchors[k] = nil }
                if let cached = joyAnchors[k], now - cached.received <= 0.14 { sample = cached.anchor }
                else { sample = nil }
            }
            guard let a = sample, a.isTracked else { continue }
            let sk = a.handSkeleton
            if joy && joyWristIDs[k] != a.id {
                joyWristIDs[k] = a.id
                wristBasis[k] = nil
                wristOffset[k] = .zero
                wristCalibrated[k] = false
            }
            func localPosition(_ joint: HandSkeleton.Joint) -> SIMD3<Float> {
                let p = joint.anchorFromJointTransform.columns.3
                return SIMD3(p.x, p.y, p.z)
            }
            if let sk {
                let wrist = sk.joint(.wrist)
                let middle = sk.joint(.middleFingerKnuckle)
                let index = sk.joint(.indexFingerKnuckle)
                let little = sk.joint(.littleFingerKnuckle)
                let trackedBasis = wrist.isTracked && middle.isTracked && index.isTracked && little.isTracked
                if !joy && wrist.isTracked { wristOffset[k] = localPosition(wrist) }
                if (!joy || !wristCalibrated[k]) && (trackedBasis || (joy && wristBasis[k] == nil)) {
                    let offset = localPosition(wrist)
                    let forward = localPosition(middle) - offset
                    let across = (localPosition(index) - localPosition(little)) * (k == 0 ? -1 : 1)
                    if (0.015...0.16).contains(simd_length(forward)), (0.015...0.13).contains(simd_length(across)),
                       abs(simd_dot(simd_normalize(forward), simd_normalize(across))) < 0.8 {
                        wristBasis[k] = (simd_normalize(forward), simd_normalize(across))
                        if joy && trackedBasis {
                            wristOffset[k] = offset
                            wristCalibrated[k] = true
                        }
                    }
                }
            }
            // The ARKit hand anchor is based at the wrist. Seed from its rest
            // axes if even the skeleton is absent, then calibrate once when visible.
            let basis = wristBasis[k] ?? (forward: SIMD3<Float>(0, 0, -1), across: SIMD3<Float>(-1, 0, 0))
            if joy || (wristBasis[k] != nil && (!bare || sk?.joint(.wrist).isTracked == true)) {
                let m = a.originFromAnchorTransform
                let f = m * SIMD4(basis.forward, 0)
                let s = m * SIMD4(basis.across, 0)
                let t = m * SIMD4(wristOffset[k], 1)
                let base = k * 10
                wrists[base] = 1
                for i in 0..<3 {
                    wrists[base + 1 + i] = t[i]
                    wrists[base + 4 + i] = f[i]
                    wrists[base + 7 + i] = s[i]
                }
            }
            guard let sk else { continue }
            func p(_ j: HandSkeleton.JointName) -> SIMD3<Float> {
                let m = a.originFromAnchorTransform * sk.joint(j).anchorFromJointTransform
                return SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            }
            let elbow = p(.forearmArm), fwrist = p(.forearmWrist)
            let armOK = simd_distance(elbow, fwrist) > 0.05 &&
                (!joy || (sk.joint(.forearmArm).isTracked && sk.joint(.forearmWrist).isTracked))
            if armOK {
                arms[k * 7] = 1
                for i in 0..<3 { arms[k * 7 + 1 + i] = elbow[i]; arms[k * 7 + 4 + i] = fwrist[i] }
            }
            let names: [HandSkeleton.JointName] = [.forearmArm, .wrist,
                .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip,
                .indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerTip,
                .middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerTip,
                .ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerTip,
                .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerTip]
            let wristPoint = p(.wrist)
            let direction = fwrist - elbow
            let forward = simd_length(direction) > 0.001 ? simd_normalize(direction) : SIMD3<Float>(0, 0, -1)
            let ref = abs(forward.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let across = simd_normalize(simd_cross(forward, ref)) * (k == 0 ? -1 : 1)
            let normal = simd_normalize(simd_cross(across, forward))
            let active = !bare && (buttons & (1 << 15)) != 0
            let grab = (buttons & (1 << (k == 0 ? 0 : 2))) != 0
            let trigger = (buttons & (1 << (k == 0 ? 1 : 3))) != 0
            skeleton[k * 67] = 1
            for (n, name) in names.enumerated() {
                var q = p(name)
                if n >= 2 && active && armOK && simd_distance(q, wristPoint) < 0.005 {
                    let finger = n < 6 ? 0 : (n - 6) / 4 + 1
                    let part = n < 6 ? n - 2 : (n - 6) % 4
                    let spread: Float = [0.045, 0.027, 0.009, -0.009, -0.027][finger]
                    let curl = finger == 1 ? trigger : grab
                    let advance: Float = finger == 0 ? 0.022 : 0.025
                    let length = Float(part) * (curl ? 0.012 : 0.020)
                    let bend = curl ? Float(max(0, part - 1)) * 0.015 : 0
                    q = fwrist + across * spread + forward * (advance + length) - normal * bend
                }
                for i in 0..<3 { skeleton[k * 67 + 1 + n * 3 + i] = q[i] }
            }
            let thumb = p(.thumbTip), index = p(.indexFingerTip)
            let anchor = (p(.indexFingerKnuckle) + p(.thumbKnuckle)) * 0.5
            let thumbTracked = sk.joint(.thumbTip).isTracked
            let indexTracked = sk.joint(.indexFingerTip).isTracked
            if bare && thumbTracked && sk.joint(.middleFingerTip).isTracked {
                middlePinch[k] = simd_distance(thumb, p(.middleFingerTip))
            }
            v[k * 10] = (!bare && !joy) || (thumbTracked && indexTracked) ? 1 : 0
            for i in 0..<3 { v[k * 10 + 1 + i] = thumb[i]; v[k * 10 + 4 + i] = index[i]; v[k * 10 + 7 + i] = anchor[i] }
            j[k * 25] = 1
            for (n, name) in [HandSkeleton.JointName.wrist, .indexFingerKnuckle, .middleFingerKnuckle, .littleFingerKnuckle,
                              .middleFingerTip, .ringFingerTip, .littleFingerTip, .indexFingerTip].enumerated() {
                var q = p(name)
                if n > 0 && simd_distance(q, wristPoint) < 0.005 && armOK {
                    let d = fwrist - elbow
                    let f = simd_length(d) > 0.001 ? simd_normalize(d) : SIMD3<Float>(0, 0, -1)
                    let ref = abs(f.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                    let across = simd_normalize(simd_cross(f, ref))
                    q = n == 0 ? fwrist : fwrist + f * 0.07 + across * (n == 1 ? -0.025 : n == 3 ? 0.025 : 0)
                }
                for i in 0..<3 { j[k * 25 + 1 + n * 3 + i] = q[i] }
            }
        }
        skeleton.withUnsafeBufferPointer { vx_xros_vr_hand_skeleton($0.baseAddress) }
        wrists.withUnsafeBufferPointer { vx_xros_vr_wrist_poses($0.baseAddress) }
        if bare { middlePinch.withUnsafeBufferPointer { vx_xros_vr_middle_pinches($0.baseAddress) } }
        arms.withUnsafeBufferPointer { vx_xros_vr_hand_arms($0.baseAddress) }
        j.withUnsafeBufferPointer { vx_xros_vr_hand_joints($0.baseAddress) }
        let detected = joy ? wrists : v
        if !handsLogged && (detected[0] > 0 || detected[10] > 0) {
            handsLogged = true
            vxmac_jlog("input_source", "\"source\":\"hand_tracking\",\"first_hand\":\"\(detected[10] > 0 ? "right" : "left")\"")
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
