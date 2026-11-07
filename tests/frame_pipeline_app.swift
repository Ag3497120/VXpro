// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct VXFramePipelineApp: App {
    @State private var started = false
    @State private var status = "映像の生成と表示を分ける仕組みを検査しています。"
    var body: some Scene {
        WindowGroup {
            Text(status).padding(36).frame(width: 600, height: 220).task {
                guard !started else { return }
                started = true
                status = await Task.detached(priority: .userInitiated) { vx_frame_pipeline_app() }.value
            }
        }
    }
}
