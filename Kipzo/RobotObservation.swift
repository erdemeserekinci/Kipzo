import Foundation
import CoreGraphics

/// Planner'a iletilen tek bağlam nesnesi.
///
/// Anlık event'in yanı sıra ham sinyal değerlerini,
/// zamansallığı ve geçmiş gözlem penceresini taşır.
///
/// Tasarım notu:
/// SLM veya fiziksel model entegrasyonunda modele geçilecek
/// nesne budur. `event` alanı kural tabanlı planner için,
/// diğer alanlar model tabanlı planner için kullanılır.
struct RobotObservation {

    // MARK: - Anlık durum

    /// Semantik olay — kural tabanlı karar için birincil girdi.
    let event: RobotEvent

    /// Ham yatay hata sinyali (-1...1).
    /// Negatif = sol, pozitif = sağ.
    let turnSignal: Double

    /// Normalize edilmiş yüz genişliği (0...1).
    /// Yakınlık/mesafe göstergesi olarak kullanılabilir.
    /// Yüz yoksa nil.
    let faceSize: Double?

    /// Normalize edilmiş yüz merkezi X koordinatı (0...1).
    /// Yüz yoksa nil.
    let faceMidX: Double?

    /// Bu gözlemin üretildiği zaman.
    let timestamp: Date

    // MARK: - Geçmiş penceresi

    /// Son N gözlemin kısa geçmişi — zaman sıralı, en yeni sonda.
    ///
    /// Varsayılan pencere büyüklüğü: 10 gözlem (~3.5 saniye).
    /// Model tabanlı planner bu pencereyi örüntü tespiti için kullanır.
    let recentHistory: [RobotObservation]

    // MARK: - Hesaplanan özellikler

    /// Yüz son kaç saniyedir görülüyor?
    /// Geçmişte yüz olan gözlem sayısından hesaplanır.
    var faceVisibleDuration: TimeInterval {
        var duration: TimeInterval = 0
        for obs in recentHistory.reversed() {
            guard obs.faceSize != nil else { break }
            duration += 0.35
        }
        return duration
    }

    /// Son N gözlemdeki ortalama dönüş sinyali.
    /// Titreşim filtresi veya trend tespiti için kullanılabilir.
    var averageTurnSignal: Double {
        let relevant = recentHistory.filter { $0.faceSize != nil }
        guard !relevant.isEmpty else { return turnSignal }
        return relevant.reduce(0.0) { $0 + $1.turnSignal } / Double(relevant.count)
    }
}

// MARK: - Fabrika

extension RobotObservation {

    /// Standart bir gözlem nesnesi üretir.
    ///
    /// - Parameters:
    ///   - event: Semantik olay.
    ///   - turnSignal: Ham yatay hata sinyali.
    ///   - faceBounds: Normalize edilmiş yüz dikdörtgeni. Yüz yoksa nil.
    ///   - history: Önceki gözlemler penceresi.
    static func make(
        event: RobotEvent,
        turnSignal: Double,
        faceBounds: CGRect?,
        history: [RobotObservation]
    ) -> RobotObservation {
        RobotObservation(
            event: event,
            turnSignal: turnSignal,
            faceSize: faceBounds.map { Double($0.width) },
            faceMidX: faceBounds.map { Double($0.midX) },
            timestamp: Date(),
            recentHistory: Array(history.suffix(10))
        )
    }
}
