// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct VXMotionMeanApp: App {
    @State private var started = false
    @State private var status = "集計値の一致とGPU処理時間を検査しています。"
    var body: some Scene {
        WindowGroup {
            Text(status).padding(36).frame(width: 600, height: 220).task {
                guard !started else { return }
                started = true
                status = await Task.detached(priority: .userInitiated) { vx_velocity_mean_app() }.value
            }
        }
    }
}
