// SPDX-License-Identifier: MIT
import ARKit
import CompositorServices
import Foundation
import Metal
import QuartzCore
import simd

final class ReprojectionRenderer: @unchecked Sendable {
    private let layer: LayerRenderer
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let control: TestControl
    private let plan: TestPlan
    private let trace: TestTrace
    private let session = ARKitSession()
    private let tracking = WorldTrackingProvider()
    private let completed = CompletionCounts()
    private let slots = DispatchSemaphore(value: 3)
    private let digitBuffers: [MTLBuffer]
    private var slot = 0
    private let grid: (MTLBuffer,Int), sphere: (MTLBuffer,Int), label: (MTLBuffer,Int)
    private var labels: [String: MTLTexture] = [:]
    private var sceneOrigin: simd_float4x4?
    private var startTime: Double?
    private var pausedSeconds = 0.0
    private var frameID: UInt64 = 0
    private var phaseKey = ""
    private var meter = CadenceMeter()
    private var lastReport = 0.0
    private var lastThermal = -1
    private var finished = false
    private var lastElapsed = 0.0
    private var failureMessage: String?
    private let createdAt = CACurrentMediaTime()

    static func start(_ layer: LayerRenderer, control: TestControl) {
        Task {
            do {
                let renderer = try ReprojectionRenderer(layer, control: control)
                try await renderer.session.run([renderer.tracking])
                let thread = Thread { renderer.loop() }
                thread.name = "Apple reprojection comparison"; thread.qualityOfService = .userInteractive
                thread.start()
            } catch { control.end("開始できませんでした：\(error.localizedDescription)") }
        }
    }
    private init(_ layer: LayerRenderer, control: TestControl) throws {
        self.layer = layer; self.control = control; self.plan = control.plan()
        trace = try TestTrace()
        let device = layer.device
        guard let q = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
              let vs = library.makeFunction(name:"test_vertex"), let fs = library.makeFunction(name:"test_fragment") else {
            throw NSError(domain:"ReprojectionTest",code:1,userInfo:[NSLocalizedDescriptionKey:"描画の準備に失敗しました。"])
        }
        commandQueue = q; commandQueue.label = "Reprojection test native scene"
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vs; d.fragmentFunction = fs
        d.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        d.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try device.makeRenderPipelineState(descriptor:d)
        let ds = MTLDepthStencilDescriptor(); ds.depthCompareFunction = .greaterEqual; ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor:ds)!
        let g = TestMesh.grid(), s = TestMesh.sphere(), l = TestMesh.labelPlane()
        grid = (g.buffer(device),g.vertices.count); sphere = (s.buffer(device),s.vertices.count)
        label = (l.buffer(device),l.vertices.count)
        digitBuffers = (0..<3).map { _ in device.makeBuffer(length:65536,options:.storageModeShared)! }
        for p in [TestPlan.full,.half,.third] { for look in [true,false] {
            let instruction = look ? "格子を見ながら、頭をゆっくり左右に" : "頭を止めて、左右に動く球を見る"
            labels["\(p.rawValue)-\(look)"] = testLabel(device:device,title:"\(p.nominalFPS) FPS相当　／　Apple補正の比較",instruction:instruction)
        } }
        trace.event("start",["plan":plan.rawValue,"nominal_hz":90,"phase_seconds":15,"total_seconds":60,
            "independent_app_reprojection":false,"frame_interpolation":false,"depth_write":true,
            "display_count_is_scheduled_not_scanout":true,"vertex_stride":MemoryLayout<TestVertex>.stride,
            "layout":"\(layer.configuration.layout)","foveation":layer.configuration.isFoveationEnabled,
            "os":ProcessInfo.processInfo.operatingSystemVersionString])
    }
    private static func seconds(_ instant: LayerRenderer.Clock.Instant) -> Double {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to:instant).components
        return Double(c.seconds)+Double(c.attoseconds)*1e-18
    }
    private func loop() {
        while !finished {
            switch layer.state {
            case .invalidated: finished = true
            case .paused:
                let began = CACurrentMediaTime()
                summarize("pause"); trace.event("paused"); trace.flush()
                layer.waitUntilRunning()
                pausedSeconds += CACurrentMediaTime()-began
                phaseKey = ""; meter = CadenceMeter()
                trace.event("resumed")
            default: autoreleasepool { frame() }
            }
        }
        // All per-frame buffers and the last phase's completion metrics have now finished.
        if let drain = commandQueue.makeCommandBuffer() { drain.commit(); drain.waitUntilCompleted() }
        summarize("end")
        trace.event("end",["submitted_frames":frameID,"completion_counts":completed.snapshot(),
                           "elapsed_s":lastElapsed,"completed_test":lastElapsed>=60 && failureMessage == nil,
                           "actual_panel_fps_measured":false])
        trace.flush(); session.stop()
        let message = lastElapsed>=60 ? "比較が終わりました。記録を保存しました。\n実際に滑らかだった速さを教えてください。" : "比較を途中で終了しました。記録は保存しました。"
        control.end(failureMessage ?? message)
    }
    private func summarize(_ why: String) {
        guard meter.count > 0 else { return }
        trace.event("phase_summary",["key":phaseKey,"why":why,"submitted":meter.count,
            "scheduled_span_s":meter.duration,"app_submission_hz":meter.submissionHz,
            "scheduled_display_hz":meter.scheduledDisplayHz,"unsubmitted_scheduled_slots":meter.unsubmittedSlots,
            "invalid_pairs":meter.invalidPairs,"first_index":meter.firstIndex,"last_index":meter.lastIndex,
            "actual_panel_fps_measured":false])
    }
    private func frame() {
        slots.wait()
        guard let frame = layer.queryNextFrame() else { slots.signal(); Thread.sleep(forTimeInterval:0.001); return }
        frame.startUpdate(); frame.endUpdate()
        guard let predicted = frame.predictTiming() else { slots.signal(); return }
        // The first frame after a change may still have the old interval; the log carries
        // both the requested repeat count and the actual scheduled index/time pair.
        let predictedTime = Self.seconds(predicted.presentationTime)
        let elapsed = startTime.map { max(0,predictedTime-$0-pausedSeconds) } ?? 0
        let phase = plan.phase(at:elapsed)
        layer.minimumFrameRepeatCount = phase.mode.repeats
        LayerRenderer.Clock().wait(until:predicted.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { slots.signal(); return }
        guard let cb = commandQueue.makeCommandBuffer() else { slots.signal(); frame.endSubmission(); return }
        cb.label = "Reprojection native frame \(frameID)"
        let builtin = drawables.first { $0.target == .builtIn }
        let timing = builtin?.frameTiming ?? predicted
        let presentation = Self.seconds(timing.presentationTime)
        let deadline = Self.seconds(timing.renderingDeadline)
        let anchor = tracking.queryDeviceAnchor(atTimestamp:presentation)
        let valid = anchor?.isTracked == true
        if startTime == nil && CACurrentMediaTime()-createdAt > 15 {
            failureMessage = "頭の位置を取得できなかったため終了しました。装着した状態でもう一度開始してください。"
            finished = true
        }
        if valid, let head = anchor?.originFromAnchorTransform, sceneOrigin == nil {
            sceneOrigin = testSceneOrigin(head)
            startTime = presentation; pausedSeconds = 0
        }
        let t = startTime.map { max(0,presentation-$0-pausedSeconds) } ?? 0
        lastElapsed = t
        let actualPhase = plan.phase(at:t)
        if actualPhase.key != phaseKey && valid {
            summarize("phase_change"); meter = CadenceMeter(); phaseKey = actualPhase.key
            trace.event("phase",["key":phaseKey,"nominal_fps":actualPhase.mode.nominalFPS,
                "repeat_count":actualPhase.mode.repeats,"elapsed_s":t,
                "thermal":ProcessInfo.processInfo.thermalState.rawValue])
        }
        frameID += 1
        var digits = TestMesh()
        digits.digits(UInt64(actualPhase.mode.nominalFPS),count:2,x:-0.48,y:-0.55,scale:0.09)
        digits.digits(frameID % 100000,count:5,x:0.03,y:-0.55,scale:0.07)
        let digitBuffer = digitBuffers[slot]; slot = (slot+1)%digitBuffers.count
        digits.vertices.withUnsafeBytes { raw in
            precondition(raw.count <= digitBuffer.length)
            memcpy(digitBuffer.contents(),raw.baseAddress!,raw.count)
        }
        let texture = labels["\(actualPhase.mode.rawValue)-\(actualPhase.lookAround)"]!
        for drawable in drawables {
            // Correct depth and the pose used to draw this source frame are handed
            // straight to Apple. No cached-image blit, image warp or optical flow runs here.
            drawable.deviceAnchor = anchor; drawable.depthRange = layer.configuration.defaultDepthRange
            for i in drawable.views.indices {
                let map = drawable.views[i].textureMap
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = drawable.colorTextures[map.textureIndex]
                rp.colorAttachments[0].slice = map.sliceIndex
                rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0.012,0.018,0.025,1)
                rp.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
                rp.depthAttachment.slice = map.sliceIndex
                rp.depthAttachment.loadAction = .clear; rp.depthAttachment.storeAction = .store; rp.depthAttachment.clearDepth = 0
                guard let e = cb.makeRenderCommandEncoder(descriptor:rp) else { continue }
                e.setViewport(map.viewport); e.setRenderPipelineState(pipeline); e.setDepthStencilState(depthState)
                e.setCullMode(.none); e.setFragmentTexture(texture,index:0)
                if valid, let head = anchor?.originFromAnchorTransform, let origin = sceneOrigin {
                    let projection = drawable.computeProjection(convention:.rightUpBack,viewIndex:i)
                    let vp = projection * (head * drawable.views[i].transform).inverse * origin
                    func draw(_ buffer: MTLBuffer, _ count: Int, _ transform: simd_float4x4) {
                        var m = vp * transform
                        e.setVertexBuffer(buffer,offset:0,index:0)
                        e.setVertexBytes(&m,length:MemoryLayout<simd_float4x4>.stride,index:1)
                        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:count)
                    }
                    draw(grid.0,grid.1,matrix_identity_float4x4)
                    var ball = matrix_identity_float4x4
                    ball.columns.0.x = 0.12; ball.columns.1.y = 0.12; ball.columns.2.z = 0.12
                    ball.columns.3 = .init(Float(sin(t*2*Double.pi/5))*0.65,0,-1.8,1)
                    draw(sphere.0,sphere.1,ball)
                    draw(label.0,label.1,matrix_identity_float4x4)
                    draw(digitBuffer,digits.vertices.count,matrix_identity_float4x4)
                }
                e.endEncoding()
            }
            drawable.encodePresent(commandBuffer:cb)
        }
        let id = frameID, key = phaseKey, recorder = trace, counts = completed, semaphore = slots
        cb.addCompletedHandler { c in
            let late = c.gpuEndTime > deadline
            let failed = c.status == .error
            counts.add(key:key,gpuMS:(c.gpuEndTime-c.gpuStartTime)*1000,late:late,failed:failed)
            recorder.event("gpu",["source_id":id,"key":key,"gpu_start_s":c.gpuStartTime,"gpu_end_s":c.gpuEndTime,
                "deadline_s":deadline,"late":late,"failed":failed])
            semaphore.signal()
        }
        cb.commit(); frame.endSubmission()
        if valid, let d = builtin {
            meter.add(time:presentation,index:d.presentationFrameIndex)
            trace.event("frame",["source_id":id,"key":phaseKey,"elapsed_s":t,"presentation_s":presentation,
                "presentation_index":d.presentationFrameIndex,"repeat_count":actualPhase.mode.repeats,
                "tracked":true,"capture_targets":drawables.filter { $0.target == .capture }.count,
                "head_position":[anchor!.originFromAnchorTransform.columns.3.x,
                    anchor!.originFromAnchorTransform.columns.3.y,anchor!.originFromAnchorTransform.columns.3.z],
                "head_orientation_xyzw":[simd_quatf(anchor!.originFromAnchorTransform).vector.x,
                    simd_quatf(anchor!.originFromAnchorTransform).vector.y,simd_quatf(anchor!.originFromAnchorTransform).vector.z,
                    simd_quatf(anchor!.originFromAnchorTransform).vector.w]])
        } else { trace.event("tracking_missing",["source_id":id]) }
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        if thermal != lastThermal { trace.event("thermal",["state":thermal]); lastThermal = thermal }
        if t-lastReport >= 1 && valid {
            trace.event("progress",["elapsed_s":t,"key":phaseKey,"app_submission_hz":meter.submissionHz,
                "scheduled_display_hz":meter.scheduledDisplayHz,"thermal":thermal])
            control.update(String(format:"%@　描画 %.1f FPS／表示予定 %.1f Hz　残り %.0f秒",
                                  actualPhase.mode.title,meter.submissionHz,meter.scheduledDisplayHz,max(0,60-t)))
            lastReport = t
        }
        if t>=60 { finished = true }
    }
}
