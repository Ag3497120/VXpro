// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct VXMotionMaxApp: App {
    @State private var started = false
    @State private var status = "画像と深度の一致を確認し、GPU処理を比較しています。"
    var body: some Scene {
        WindowGroup {
            Text(status).padding(36).frame(width: 680, height: 240).task {
                guard !started else { return }
                started = true
                status = await Task.detached(priority: .userInitiated) { vx_motion_max_app() }.value
            }
        }
    }
}
