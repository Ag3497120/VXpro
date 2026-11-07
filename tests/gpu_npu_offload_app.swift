// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct VXOffloadBenchApp: App {
    @State private var status = "GPUとNeural Engineの分担を測定しています。ゲーム本体は変更しません。"
    @State private var started = false

    var body: some Scene {
        WindowGroup {
            Text(status)
                .padding(36)
                .frame(width: 580, height: 200)
                .task {
                    guard !started else { return }
                    started = true
                    let result = await Task.detached(priority: .userInitiated) {
                        vx_gpu_npu_offload_app() ?? "結果を取得できませんでした。"
                    }.value
                    status = result
                }
        }
    }
}
