// SPDX-License-Identifier: MIT
import SwiftUI
import CompositorServices

final class TestControl: ObservableObject, @unchecked Sendable {
    @Published var status = "比較する速さを選んで開始してください。"
    @Published var finished = false
    private let lock = NSLock()
    private var selected: TestPlan = .automatic
    func select(_ plan: TestPlan) {
        lock.lock(); selected = plan; lock.unlock()
        finished = false
    }
    func plan() -> TestPlan { lock.lock(); defer { lock.unlock() }; return selected }
    func update(_ text: String) { DispatchQueue.main.async { self.status = text } }
    func end(_ text: String) {
        DispatchQueue.main.async { self.status = text; self.finished = true }
    }
}

@main
struct ReprojectionTestApp: App {
    @StateObject private var control = TestControl()
    var body: some Scene {
        WindowGroup { TestHome(control: control) }
            .windowResizability(.contentSize)
        ImmersiveSpace(id: "comparison") {
            CompositorLayer(configuration: TestLayerConfiguration()) { layer in
                ReprojectionRenderer.start(layer, control: control)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.hidden)
    }
}

struct TestHome: View {
    @ObservedObject var control: TestControl
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var opened = false
    @State private var opening = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Appleの表示補正を比較").font(.title)
            Text("格子は空間に固定され、球は左右に動きます。\n案内に合わせて、ゆっくり見回す・頭を止めるを比較します。")
            Text("独自の映像補間は使いません。端末の表示周期に応じて実際の描画FPSは変わり、記録に残ります。")
                .font(.callout).foregroundStyle(.secondary)
            Button(TestPlan.automatic.title) { begin(.automatic) }.buttonStyle(.borderedProminent)
            HStack {
                ForEach([TestPlan.full, .half, .third], id: \.rawValue) { p in
                    Button(p.title) { begin(p) }
                }
            }
            Text(control.status).font(.callout).monospacedDigit()
            if opened { Button("比較を終える") { Task { await dismissImmersiveSpace(); opened = false } } }
            Text("各比較は1分で終了します。画面収録は不要です。\n記録はアプリ内に保存され、後から回収できます。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(30).frame(width: 660)
        .disabled(opening)
        .onChange(of: control.finished) { _, done in
            if done && opened { Task { await dismissImmersiveSpace(); opened = false } }
        }
    }
    private func begin(_ plan: TestPlan) {
        guard !opened && !opening else { return }
        control.select(plan); opening = true
        Task {
            let result = await openImmersiveSpace(id: "comparison")
            switch result {
            case .opened: opened = true
            case .userCancelled: control.status = "開始をキャンセルしました。"
            case .error: control.status = "比較画面を開けませんでした。"
            @unknown default: control.status = "比較画面を開けませんでした。"
            }
            opening = false
        }
    }
}

struct TestLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : (layouts.first ?? .layered)
        configuration.isFoveationEnabled = false
        let colors = capabilities.supportedColorFormats(options: [])
        if colors.contains(.bgra8Unorm_srgb) { configuration.colorFormat = .bgra8Unorm_srgb }
        if capabilities.supportedDepthFormats.contains(.depth32Float) { configuration.depthFormat = .depth32Float }
        // The device can reject a layer before the renderer starts if its near
        // plane is closer than the supported minimum. Use the returned limit.
        let near = max(0.1,capabilities.supportedMinimumNearPlaneDistance)
        configuration.defaultDepthRange = SIMD2<Float>(max(20,near+1),near)
        let diagnostic: [String: Any] = ["minimum_near_m":capabilities.supportedMinimumNearPlaneDistance,
            "near_m":near,"far_m":configuration.defaultDepthRange.x,
            "color":configuration.colorFormat.rawValue,"depth":configuration.depthFormat.rawValue,
            "supported_colors":colors.map { $0.rawValue },
            "supported_depths":capabilities.supportedDepthFormats.map { $0.rawValue },
            "layout":"\(configuration.layout)"]
        if let data = try? JSONSerialization.data(withJSONObject:diagnostic,options:.sortedKeys),
           let docs = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {
            try? data.write(to:docs.appendingPathComponent("reprojection-configuration.json"),options:.atomic)
        }
    }
}
