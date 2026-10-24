import SwiftUI
import AVFoundation

/// Uygulama ana ekranı — ince orkestrasyon katmanı.
///
/// Sorumlulukları:
/// 1. Sensör çıktılarından gözlem üret  (planner.deriveObservation)
/// 2. Gözlemi planner'a ilet            (planner.plan)
/// 3. Action'ları executor'a yönlendir  (execute)
struct ContentView: View {

    @StateObject private var vm   = FaceTrackerViewModel()
    @StateObject private var wedo = WedoManager()
    @State private var planner    = BehaviorPlanner()

    @State private var cameraStarted     = false
    @State private var isStartingCamera  = false
    @State private var previousHasTarget = false
    @State private var isHappy           = false
    @State private var showDebug          = false

    private let synth = AVSpeechSynthesizer()

    var body: some View {
        ZStack {
            if cameraStarted {
                CameraPreviewView(
                    session: vm.session,
                    detectedFaceBounds: vm.detectedFaceBounds
                )
                .ignoresSafeArea()
                .opacity(showDebug ? 1 : 0)
            }

            RobotFaceView(vm: vm, wedo: wedo, isHappy: isHappy, showDebug: $showDebug)
        }
        .task {
            vm.status = "Waiting for WeDo connection..."
            wedo.start()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                await MainActor.run { tick() }
            }
        }
        .onChange(of: wedo.state) { _, newState in
            handleWeDoStateChange(newState)
        }
    }

    // MARK: - Tick

    private func tick() {
        guard cameraStarted else { return }

        guard let observation = planner.deriveObservation(
            hasTarget: vm.hasTarget,
            turnSignal: vm.turnSignal,
            faceBounds: vm.detectedFaceBounds,
            previousHasTarget: previousHasTarget
        ) else {
            previousHasTarget = vm.hasTarget
            return
        }

        planner.plan(observation: observation).forEach { execute($0) }
        previousHasTarget = vm.hasTarget
    }

    // MARK: - Executor

    private func execute(_ action: RobotAction) {
        switch action {

        case .tankDrive(let left, let right):
            guard wedo.state == .ready else { return }
            wedo.setTankDrive(left: left, right: right)
            Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                await MainActor.run { wedo.stopAll() }
            }

        case .stopMotor:
            wedo.stopAll()

        case .speak(let text):
            guard !synth.isSpeaking else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.48
            utterance.pitchMultiplier = 1.4
            utterance.volume = 0.9
            synth.speak(utterance)

        case .setEmotion(let happy):
            withAnimation(.easeInOut(duration: 0.3)) { isHappy = happy }
        }
    }

    // MARK: - BLE

    private func handleWeDoStateChange(_ newState: WedoManager.ConnectionState) {
        if newState == .ready && !cameraStarted && !isStartingCamera {
            isStartingCamera = true
            print("[ContentView] WeDo ready, starting camera FIRST")
            Task {
                await vm.start()
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    cameraStarted = true
                    isStartingCamera = false
                    print("[ContentView] Camera preview is now shown")
                }
            }
            let obs = RobotObservation.make(
                event: .bleConnected,
                turnSignal: 0,
                faceBounds: nil,
                history: planner.observationHistory
            )
            planner.plan(observation: obs).forEach { execute($0) }
        }

        if newState != .ready {
            let obs = RobotObservation.make(
                event: .bleDisconnected,
                turnSignal: 0,
                faceBounds: nil,
                history: planner.observationHistory
            )
            planner.plan(observation: obs).forEach { execute($0) }
            cameraStarted = false
            isStartingCamera = false
        }
    }
}
