import Foundation

/// Robotun sergileyebileceği atomik davranışları temsil eder.
///
/// Her action bir executor tarafından yerine getirilir.
/// Action'lar executor'ları (WedoManager, AVSpeech, UI) bilmez.
enum RobotAction {

    // MARK: - Motor

    /// Tank sürüş komutu — her iki motora bağımsız güç.
    /// - Parameters:
    ///   - left:  Sol motor gücü  (-1.0 ... 1.0). Negatif = geri.
    ///   - right: Sağ motor gücü  (-1.0 ... 1.0). Negatif = geri.
    ///
    /// Dönüş: left ve right zıt işaretli olursa tank dönüşü.
    /// İleri:  her ikisi de aynı işaret ve büyüklükte.
    case tankDrive(left: Double, right: Double)

    /// Her iki motoru durdur.
    case stopMotor

    // MARK: - Ses

    /// Metni konuşma sentezleyiciyle seslendir.
    case speak(String)

    // MARK: - Yüz ifadesi

    /// Robot yüz ifadesini güncelle.
    /// - Parameter happy: true = mutlu, false = nötr.
    case setEmotion(happy: Bool)
}
