import SwiftUI

struct RobotFaceView: View {
    @ObservedObject var vm: FaceTrackerViewModel
    @ObservedObject var wedo: WedoManager
    /// Dışarıdan (ContentView / BehaviorPlanner) kontrol edilir.
    var isHappy: Bool = false

    @Binding var showDebug: Bool
    @State private var blinkTimer: Timer? = nil
    @State private var isBlinking = false

    private var isCentered: Bool {
        abs(vm.turnSignal) < 0.08 && vm.hasTarget
    }

    var body: some View {
        ZStack {
            // Debug modda siyah arka plan gizlenir — kamera görünsün
            Color.black.ignoresSafeArea()
                .opacity(showDebug ? 0 : 1)

            // Debug modda gözler ve yanaklar gizlenir
            if !showDebug {
                VStack(spacing: 0) {
                    Spacer()

                    HStack(spacing: 64) {
                        FlameEyeView(
                            turnSignal: vm.turnSignal,
                            hasTarget: vm.hasTarget,
                            isBlinking: isBlinking,
                            isMotorActive: wedo.leftMotorPower != 0,
                            isCentered: isCentered
                        )
                        FlameEyeView(
                            turnSignal: vm.turnSignal,
                            hasTarget: vm.hasTarget,
                            isBlinking: isBlinking,
                            isMotorActive: wedo.leftMotorPower != 0,
                            isCentered: isCentered
                        )
                    }

                    // Yanaklar
                    HStack(spacing: 180) {
                        BlushCircle(visible: isCentered)
                        BlushCircle(visible: isCentered)
                    }
                    .padding(.top, 16)

                    Spacer()
                }
            }

            // Debug butonu — sağ üst
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3)) { showDebug.toggle() }
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.3))
                            )
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 16)
                }
                Spacer()
            }

            if showDebug {
                DebugPanel(vm: vm, wedo: wedo, onClose: { showDebug = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear { startBlinkTimer() }
        .onDisappear { blinkTimer?.invalidate() }
    }

    private func startBlinkTimer() {
        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 2.8...5.5),
            repeats: false
        ) { _ in
            withAnimation(.easeInOut(duration: 0.06)) { isBlinking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.easeInOut(duration: 0.07)) { isBlinking = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { startBlinkTimer() }
            }
        }
    }
}

// MARK: - Alev gözü
// Yatay oval/dikdörtgenimsi — çerçevesiz, saf glow

struct FlameEyeView: View {
    let turnSignal: Double
    let hasTarget: Bool
    let isBlinking: Bool
    let isMotorActive: Bool
    let isCentered: Bool

    // Pupil yatay kayma
    private var pupilX: CGFloat {
        CGFloat(turnSignal) * 28
    }

    // Iris renk gradyanı — alev
    private var irisGradient: RadialGradient {
        if !hasTarget {
            return RadialGradient(
                colors: [Color(white: 0.25), Color(white: 0.10)],
                center: .center, startRadius: 0, endRadius: 24
            )
        }
        if isMotorActive {
            return RadialGradient(
                colors: [Color(hex: "FFE033"), Color(hex: "FF6B00")],
                center: .center, startRadius: 0, endRadius: 24
            )
        }
        return RadialGradient(
            colors: [Color(hex: "FF9500"), Color(hex: "CC2200")],
            center: .center, startRadius: 0, endRadius: 24
        )
    }

    // Glow rengi
    private var glowColor: Color {
        if !hasTarget { return .clear }
        if isMotorActive { return Color(hex: "FFB800") }
        return Color(hex: "FF4400")
    }

    var body: some View {
        Group {
            if isBlinking {
                // Göz kırpma — yatay çizgi
                Capsule()
                    .fill(glowColor.opacity(0.6))
                    .frame(width: 90, height: 5)
                    .shadow(color: glowColor, radius: 6)
            } else {
                lensEye
            }
        }
        .frame(width: 130, height: 68)
    }

    private var lensEye: some View {
        ZStack {
            // Lens şekli: yatay dikdörtgen, köşeler orta yuvarlak
            // rx büyük = oval, rx küçük = dikdörtgen
            // Burada rx=18 kullanarak robot dikdörtgeni elde ediyoruz
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(white: 0.04))
                .frame(width: 130, height: 68)

            // Glow arka plan
            RoundedRectangle(cornerRadius: 18)
                .fill(glowColor.opacity(hasTarget ? 0.08 : 0))
                .frame(width: 130, height: 68)
                .blur(radius: 4)
                .animation(.easeInOut(duration: 0.4), value: hasTarget)

            // İris
            Circle()
                .fill(irisGradient)
                .frame(width: 48, height: 48)
                .offset(x: pupilX * 0.55)
                .shadow(color: glowColor.opacity(0.9), radius: isMotorActive ? 14 : 8)
                .animation(.spring(response: 0.36, dampingFraction: 0.66), value: pupilX)
                .animation(.easeInOut(duration: 0.3), value: isMotorActive)

            // Pupil — koyu merkez
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .offset(x: pupilX)
                .animation(.spring(response: 0.36, dampingFraction: 0.66), value: pupilX)

            // Speküler — sıcak beyaz nokta
            Circle()
                .fill(Color(hex: "FFF5E0").opacity(0.85))
                .frame(width: 7, height: 7)
                .offset(x: pupilX - 9, y: -9)
                .animation(.spring(response: 0.36, dampingFraction: 0.66), value: pupilX)

            // Motor aktifken tarama yayı
            if isMotorActive {
                FlameArcView()
                    .frame(width: 130, height: 68)
            }
        }
        // Dış glow — çerçeve değil, sadece ışık efekti
        .shadow(color: glowColor.opacity(hasTarget ? 0.55 : 0), radius: 16)
        .animation(.easeInOut(duration: 0.4), value: hasTarget)
        .animation(.easeInOut(duration: 0.3), value: isMotorActive)
        // Clip: gözün dışına taşan iris kesilsin
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Motor tarama yayı

struct FlameArcView: View {
    @State private var rotation: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .trim(from: 0, to: 0.2)
            .stroke(
                LinearGradient(
                    colors: [Color(hex: "FFE033").opacity(0.7), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Yanak

struct BlushCircle: View {
    let visible: Bool

    var body: some View {
        Ellipse()
            .fill(Color(hex: "FF3A00").opacity(visible ? 0.28 : 0))
            .frame(width: 48, height: 18)
            .blur(radius: 10)
            .animation(.easeInOut(duration: 0.5), value: visible)
    }
}

// MARK: - Debug paneli

struct DebugPanel: View {
    @ObservedObject var vm: FaceTrackerViewModel
    @ObservedObject var wedo: WedoManager
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("DEBUG")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: "FF6B00"))
                        .tracking(3)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 9) {
                    drow("WEDO",   wedo.statusText)
                    drow("STATUS", vm.status)
                    drow("TARGET", vm.hasTarget ? "ACQ" : "—",          hi: vm.hasTarget)
                    drow("TURN",   String(format: "%.3f", vm.turnSignal), hi: abs(vm.turnSignal) > 0.05)
                    drow("MOTOR",  "\(wedo.leftMotorPower)",              hi: wedo.leftMotorPower != 0)
                    if let b = vm.detectedFaceBounds {
                        drow("FACE X", String(format: "%.3f", b.midX))
                        drow("FACE Y", String(format: "%.3f", b.midY))
                        drow("SIZE",   String(format: "%.3f", b.width))
                    }
                }
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .frame(width: 250)
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }

    private func drow(_ label: String, _ value: String, hi: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.3))
                .frame(width: 60, alignment: .leading)
                .tracking(1)
            Text(value)
                .font(.system(size: 10, weight: hi ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(hi ? Color(hex: "FF9500") : Color.white.opacity(0.6))
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Color hex

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
