import Foundation

/// Event → Action dönüşümünü yöneten kural motoru.
///
/// Giriş: `RobotObservation` — hem semantik event hem ham sinyal hem geçmiş.
/// Çıkış: `[RobotAction]` — executor'lara yönlendirilecek davranış listesi.
///
/// Tank sürüş formülü:
///   leftPower  = drive + turn
///   rightPower = drive - turn
///
/// Genişletme rehberi:
/// - Yeni kural: `plan(observation:)` içine yeni case ekle.
/// - Model tabanlı karar: imzayı koruyarak içini SLM/fiziksel modele bağla.
@MainActor
final class BehaviorPlanner {

    // MARK: - Gözlem geçmişi

    private(set) var observationHistory: [RobotObservation] = []

    // MARK: - Sürüş parametreleri

    /// Sağa dönüş gücü (pozitif sinyal).
    private let powerPositive: Double = 0.28
    /// Sola dönüş gücü (negatif sinyal).
    private let powerNegative: Double = 0.60

    // MARK: - Mesafe parametreleri

    /// Hedef yüz genişliği (normalize, 0...1).
    /// Küçük = uzak, büyük = yakın. 0.18 ≈ ~1m mesafe.
    private let targetFaceWidth: Double = 0.18
    /// Mesafe dead-zone — bu kadar sapma tolere edilir.
    private let driveDeadZone: Double = 0.03
    /// İleri/geri motor gücü.
    private let drivePower: Double = 0.30

    // MARK: - Zamanlama

    private var lastMoveTime: Date = .distantPast
    private var lastMoveDirection: Double = 0
    private var lastGreetTime: Date = .distantPast

    private let directionCooldown: TimeInterval = 0.3
    private let moveCooldown: TimeInterval       = 0.35
    private let greetCooldown: TimeInterval      = 4.0
    private let deadZoneThreshold                = 0.08

    // MARK: - Ana giriş noktası

    func plan(observation: RobotObservation) -> [RobotAction] {
        observationHistory.append(observation)
        if observationHistory.count > 20 { observationHistory.removeFirst() }

        switch observation.event {

        case .faceAcquired:
            var actions: [RobotAction] = [.setEmotion(happy: true)]
            if canGreet() {
                lastGreetTime = Date()
                actions.append(.speak(randomGreeting()))
            }
            return actions

        case .faceLost:
            lastMoveDirection = 0
            return [.stopMotor, .setEmotion(happy: false)]

        case .faceCentered:
            lastMoveDirection = 0
            let driveOnly = driveActions(faceSize: observation.faceSize)
            return driveOnly + [.setEmotion(happy: true)]

        case .faceOffLeft(let signal):
            return turnActions(signal: -signal) + [.setEmotion(happy: false)]

        case .faceOffRight(let signal):
            return turnActions(signal: signal) + [.setEmotion(happy: false)]

        case .bleConnected:
            return []

        case .bleDisconnected:
            lastMoveDirection = 0
            return [.stopMotor]
        }
    }

    // MARK: - Dönüş

    /// Motorların mekanik yapısı: biri sağa, biri sola bakıyor.
    /// Aynı sinyal → araç döner. Zıt sinyal → araç ileri/geri gider.
    /// Bu yüzden dönüş için ikisine de aynı değeri gönderiyoruz.
    ///
    /// - Parameter signal: Normalize dönüş. Pozitif = sağa, negatif = sola.
    private func turnActions(signal: Double) -> [RobotAction] {
        let now = Date()

        let direction: Double = signal > 0 ? 1.0 : -1.0
        if direction != lastMoveDirection && lastMoveDirection != 0 {
            guard now.timeIntervalSince(lastMoveTime) > directionCooldown else {
                return [.stopMotor]
            }
        }
        guard now.timeIntervalSince(lastMoveTime) > moveCooldown else { return [] }

        lastMoveTime = now
        lastMoveDirection = direction

        // Yöne göre sabit güç — mekanik asimetriyi kompanse eder
        // powerPositive / powerNegative değerlerini fiziksel teste göre ayarla
        let power = direction > 0 ? powerPositive : -powerNegative
        // İki motora aynı sinyal → araç döner
        return [.tankDrive(left: power, right: power)]
    }

    // MARK: - Mesafe

    /// Yüz boyutuna göre ileri/geri hareket kararı (sadece merkezdeyken).
    private func driveActions(faceSize: Double?) -> [RobotAction] {
        guard let size = faceSize else { return [] }
        let error = targetFaceWidth - size
        guard abs(error) > driveDeadZone else { return [] }
        let power = error > 0 ? -drivePower : drivePower
        return [.tankDrive(left: power, right: -power)]
    }

    /// Dönüş + mesafe sinyalini tek tankDrive komutuna birleştirir.
    /// Tank formülü: left = drive + turn, right = -(drive - turn)
    /// (Sağ motor ters montajlı — zıt yönde döner)
    private func combinedActions(turnSignal: Double, faceSize: Double?) -> [RobotAction] {
        let now = Date()
        let direction: Double = turnSignal > 0 ? 1.0 : -1.0

        if direction != lastMoveDirection && lastMoveDirection != 0 {
            guard now.timeIntervalSince(lastMoveTime) > directionCooldown else {
                return [.stopMotor]
            }
        }
        guard now.timeIntervalSince(lastMoveTime) > moveCooldown else { return [] }

        lastMoveTime = now
        lastMoveDirection = direction

        let turnPower = direction > 0 ? powerPositive : -powerNegative

        // Mesafe bileşeni
        var drivePowerValue: Double = 0
        if let size = faceSize {
            let error = targetFaceWidth - size
            if abs(error) > driveDeadZone {
                drivePowerValue = error > 0 ? -drivePower : drivePower
            }
        }

        // Tank formülü: aynı yönde dönüş, zıt yönde ileri/geri
        let left  = turnPower + drivePowerValue
        let right = turnPower - drivePowerValue
        return [.tankDrive(left: left, right: right)]
    }

    // MARK: - Yardımcılar

    private func clamp(_ v: Double, limit: Double = 1.0) -> Double {
        max(-limit, min(limit, v))
    }

    private func canGreet() -> Bool {
        Date().timeIntervalSince(lastGreetTime) > greetCooldown
    }

    private func randomGreeting() -> String {
        ["hi", "hey", "hello", "yo", "hiya"].randomElement() ?? "hi"
    }
}

// MARK: - Event türetici

extension BehaviorPlanner {

    func deriveObservation(
        hasTarget: Bool,
        turnSignal: Double,
        faceBounds: CGRect?,
        previousHasTarget: Bool
    ) -> RobotObservation? {

        let event: RobotEvent

        if hasTarget && !previousHasTarget {
            event = .faceAcquired
        } else if !hasTarget && previousHasTarget {
            event = .faceLost
        } else if !hasTarget {
            return nil
        } else if abs(turnSignal) < deadZoneThreshold {
            event = .faceCentered
        } else if turnSignal < 0 {
            event = .faceOffLeft(abs(turnSignal))
        } else {
            event = .faceOffRight(abs(turnSignal))
        }

        return .make(
            event: event,
            turnSignal: turnSignal,
            faceBounds: faceBounds,
            history: observationHistory
        )
    }
}
