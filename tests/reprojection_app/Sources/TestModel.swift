// SPDX-License-Identifier: MIT
import Foundation

enum TestPlan: String, CaseIterable {
    case automatic, full, half, third
    var repeats: Int32 {
        switch self { case .half: return 1; case .third: return 2; default: return 0 }
    }
    var nominalFPS: Int { 90 / (Int(repeats) + 1) }
    var title: String {
        self == .automatic ? "自動比較（約1分）" : "\(nominalFPS) FPS相当"
    }
    func phase(at elapsed: Double) -> TestPhase {
        let order: [TestPlan] = [.full, .half, .third, .full]
        let index = self == .automatic ? min(3, max(0, Int(elapsed / 15))) : 0
        let local = self == .automatic ? elapsed - Double(index) * 15 : elapsed.truncatingRemainder(dividingBy: 15)
        return TestPhase(index: index, mode: self == .automatic ? order[index] : self,
                         lookAround: local < 7.5, finished: elapsed >= 60)
    }
}

struct TestPhase {
    let index: Int
    let mode: TestPlan
    let lookAround: Bool
    let finished: Bool
    var key: String { "\(index)-\(mode.rawValue)" }
    var instruction: String { lookAround ? "格子を見ながら、頭をゆっくり左右に" : "頭を止めて、左右に動く球を見る" }
}

// These are requested presentation slots, never physical scanout receipts.
// An explicit repeat accounts for an unsubmitted slot but is not a new scene image.
struct CadenceMeter {
    private(set) var firstTime = 0.0, lastTime = 0.0
    private(set) var firstIndex: UInt64 = 0, lastIndex: UInt64 = 0
    private(set) var count = 0, indexSteps: UInt64 = 0, unsubmittedSlots: UInt64 = 0
    private(set) var invalidPairs = 0
    mutating func add(time: Double, index: UInt64) {
        guard time.isFinite else { invalidPairs += 1; return }
        if count == 0 { firstTime = time; firstIndex = index }
        else {
            guard time > lastTime, index > lastIndex else { invalidPairs += 1; return }
            let step = index - lastIndex
            indexSteps += step
            unsubmittedSlots += step - 1
        }
        lastTime = time; lastIndex = index; count += 1
    }
    var duration: Double { lastTime - firstTime }
    var submissionHz: Double { count > 1 && duration > 0 ? Double(count - 1) / duration : 0 }
    var scheduledDisplayHz: Double { count > 1 && duration > 0 ? Double(indexSteps) / duration : 0 }
}
