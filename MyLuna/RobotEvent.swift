import Foundation

/// Sistemde gerçekleşen anlamlı olayları temsil eder.
///
/// Ham sinyaller (turnSignal: Double, hasTarget: Bool) bu enum'a
/// dönüştürülür. Planner yalnızca bu olayları görür, ham değerleri değil.
enum RobotEvent: Equatable {

    // MARK: - Yüz takip olayları

    /// Kameraya ilk kez yüz girdi.
    case faceAcquired

    /// Yüz kadrajdan çıktı veya algılanamıyor.
    case faceLost

    /// Yüz ekranın merkezine yakın — dönüş sinyali dead-zone içinde.
    case faceCentered

    /// Yüz merkezden sola kaydı.
    /// - Parameter signal: Normalize edilmiş dönüş sinyali (0...1).
    case faceOffLeft(Double)

    /// Yüz merkezden sağa kaydı.
    /// - Parameter signal: Normalize edilmiş dönüş sinyali (0...1).
    case faceOffRight(Double)

    // MARK: - BLE bağlantı olayları

    /// WeDo hub bağlandı ve motora hazır.
    case bleConnected

    /// WeDo hub bağlantısı kesildi.
    case bleDisconnected
}
