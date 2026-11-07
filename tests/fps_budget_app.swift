// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct VXFPSBudgetApp: App {
    @State private var started = false
    @State private var status = "画質を変えない高速化候補を比較しています。"
    var body: some Scene {
        WindowGroup {
            Text(status).padding(36).frame(width: 680, height: 240).task {
                guard !started else { return }
                started = true
                status = await Task.detached(priority: .userInitiated) {
                    vx_velocity_demand_app() + "\n" + vx_warp_black_skip_app()
                }.value
            }
        }
    }
}
