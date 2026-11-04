// VX Mac Host (your bundle id): a macOS program (the Mac App Store Cyberpunk 2077, or the test program) run
// natively on Vision Pro: its Mach-O images prepared by VXMac/tools/macho_prepare.py (visionOS platform, our shims in
// place of AppKit and the other macOS-only libraries, the executable as a dylib), its main() on a thread of its own
// (host.m), its frames shown in the immersive space by the presenter shared with VX Runtime (VXMacImmersive.swift,
// ../../vr/xros_vr.m). The window is only the host: invisible in VR; with -present flat the program's layer is
// shown in it (a debug fallback). See docs/DESIGN.md.
import CompositorServices
import SwiftUI

@main
struct VXMacApp: App {
    @Environment(\.scenePhase) private var phase
    init() { vxmac_jlog("app_init", nil) }
    var body: some Scene {
        WindowGroup(id: "display") {
            VXMacDisplayView()
                .opacity(vxmac_present_vr() != 0 ? 0 : 1)
                .persistentSystemOverlays(vxmac_present_vr() != 0 ? .hidden : .automatic)
        }
        .windowStyle(.plain)
        .onChange(of: phase) { _, p in
            vxmac_jlog("scene_phase", "\"phase\":\"\(p)\",\"space_open\":\(vxmac_vr_space_open())")
            if p == .background { vxmac_set_foreground(0) } else if p == .active { vxmac_set_foreground(1) }
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: "vr") {
            CompositorLayer(configuration: VXMacLayerConfiguration()) { layerRenderer in
                VXMacImmersiveRenderer.start(layerRenderer)
            }
        }
        .upperLimbVisibility(getenv("VXMAC_PASSTHROUGH_HANDS").map { String(cString: $0) == "1" } == true ? .automatic : .hidden)
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

struct VXMacLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : (layouts.first ?? .dedicated)
        // (VXMAC_FOVEATE=1: CompositorServices' foveation (rasterization rate maps: the centre denser than without, the
        //  edges coarser); the warp and every eye pass draw through the maps (xros_vr.m eye_encoder, warp_core.m). Off
        //  by default until verified on the device)
        // (h60e: on by default again - the eyes' warp is a gather over 2 x 1888x1792 (5.5-6.5 ms on M2 beside the game,
        //  4-29 deadlines missed a 5 s in h60c); the rate maps shade the periphery coarser. h28/h31's 45 Hz with it had other
        //  causes then (the GPU share uncapped). VXMAC_FOVEATE=0: off)
        // (h60f: off again - with it the warp worked on the rate map's logical screen (4493x3604 for 1856x1792 physical,
        //  h60e) and its GPU time did not fall; the warp at a lower internal size instead (xros_vr.m, VXMAC_WARP_SCALE))
        let fov = getenv("VXMAC_FOVEATE").map { String(cString: $0) == "1" } ?? false
        configuration.isFoveationEnabled = fov && capabilities.supportsFoveation
        let colors = capabilities.supportedColorFormats(options: [])
        if colors.contains(.bgra8Unorm_srgb) { configuration.colorFormat = .bgra8Unorm_srgb }
        if capabilities.supportedDepthFormats.contains(.depth32Float) { configuration.depthFormat = .depth32Float }
    }
}

struct VXMacRootControllerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { vxmac_make_root_controller() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct VXMacDisplayView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var windowPhase
    @State private var opened = false

    private func open(_ why: String) async {
        guard vxmac_present_vr() != 0, vxmac_vr_space_open() == 0 else { return }
        let result = await openImmersiveSpace(id: "vr")
        let text: String
        switch result {
        case .opened: text = "opened"
        case .userCancelled: text = "cancelled"
        case .error: text = "error"
        @unknown default: text = "unknown"
        }
        vxmac_jlog("immersive_space", "\"result\":\"\(text)\",\"why\":\"\(why)\"")
        // (VR: the window goes once the space is open: its plate and window bar showed as a grey area below the view,
        // h10. Opening the app again brings it back, and it opens the space again)
        if result == .opened && vxmac_keep_window() == 0 {
            dismissWindow(id: "display")
            vxmac_jlog("window_dismissed", nil)
        }
    }

    var body: some View {
        Group {
            if vxmac_present_vr() != 0 {
                // (h53: the window (shown until the space opens, and when the app is opened again): a Quit button - the
                //  game's own quit path, its saves untouched)
                Button("Quit game") { vxmac_request_quit("window button") }
                    .padding(24)
            } else {
                VXMacRootControllerView().frame(width: 1280, height: 720)
            }
        }
        .onAppear { vxmac_jlog("display_view", "\"vr\":\(vxmac_present_vr())"); vxmac_boot() }
        .onChange(of: windowPhase) { _, p in
            vxmac_jlog("window_phase", "\"phase\":\"\(p)\"")
            if p == .active && opened { Task { await open("window active again") } }
        }
        .task {
            guard !opened else { return }
            opened = true
            await open("launch")
            // (the space again when it closed while the app is active: in h10 it closed 40 s into the game and the
            // program ran on with nothing shown; at most 3 times a minute, so a deliberate close is not fought)
            var tries: [Date] = []
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard vxmac_present_vr() != 0, vxmac_vr_space_open() == 0, windowPhase == .active else { continue }
                tries = tries.filter { $0.timeIntervalSinceNow > -60 }
                if tries.count >= 3 { continue }
                tries.append(Date())
                await open("space closed")
            }
        }
    }
}
