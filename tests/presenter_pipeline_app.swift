// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct VXPresenterPipelineApp: App {
    @State private var started = false
    @State private var status = "ゲーム側と同じ画像管理処理を検査しています。"
    var body: some Scene {
        WindowGroup {
            Text(status).padding(36).frame(width: 600, height: 220).task {
                guard !started else { return }
                started = true
                status = await Task.detached(priority: .userInitiated) { vx_presenter_pipeline_app() }.value
            }
        }
    }
}
