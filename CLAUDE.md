# CLAUDE.md

Bu dosya, MyLuna deposunda çalışan Claude (ve diğer kod asistanları) için yol göstericidir.
Ayrıntılı ürün gereksinimleri `MyLuna/Agents.md` içindedir; ancak o belge **tek motorlu ilk
prototipi** anlatır ve kodun bugünkü hâlinin gerisinde kalmıştır. Çelişki olduğunda bu dosya
ve kodun kendisi esas alınır.

## Proje özeti

MyLuna, iPhone ön kamerasıyla yüz algılayıp LEGO WeDo 2.0 hub'ına (BLE) bağlı motorlarla
yüzü takip eden bir robot prototipidir. Ekranda alev gözlü bir "robot yüzü" gösterilir,
yüz yakalandığında robot kısa bir selam söyler.

- Platform: iOS (SwiftUI + UIKit köprüsü), yalnızca yatay (landscape)
- Deployment target: iOS 26.0 · Swift 5 dil modu · Bundle ID: `edu.ates.MyLuna`
- Harici bağımlılık yok (SPM/CocoaPods yok); yalnızca AVFoundation, CoreBluetooth, SwiftUI
- Test hedefi yok

## Derleme ve çalıştırma

- `MyLuna.xcodeproj` dosyasını Xcode ile açın, `MyLuna` şemasını **fiziksel bir iPhone**'da
  çalıştırın. Simülatörde ön kamera ve BLE olmadığı için uygulama "Waiting for WeDo
  connection..." ekranında kalır.
- Komut satırından derleme kontrolü:
  `xcodebuild -project MyLuna.xcodeproj -scheme MyLuna -destination 'generic/platform=iOS' build`
- Kamera ve Bluetooth izin metinleri `project.pbxproj` içindeki `INFOPLIST_KEY_*`
  ayarlarındadır (ayrı bir Info.plist yok).
- Proje `fileSystemSynchronizedGroups` kullanır: `MyLuna/` klasörüne konan **her dosya
  otomatik olarak hedefe eklenir**. Yeni Swift dosyası eklemek için pbxproj düzenlemeye gerek
  yoktur; buna karşılık not/belge dosyalarını `MyLuna/` içine koymayın (uygulama paketine
  kopyalanırlar).

## Mimari

Veri akışı tek yönlüdür:

```
FaceTrackerViewModel ──(hasTarget, turnSignal, faceBounds)──▶ ContentView.tick()  [~350 ms]
        │                                                          │
        │                                   BehaviorPlanner.deriveObservation()
        │                                                          ▼
        │                                              RobotObservation (event + ham sinyal + geçmiş)
        │                                                          │
        │                                           BehaviorPlanner.plan()  ──▶ [RobotAction]
        │                                                          │
        ▼                                                ContentView.execute()
CameraPreviewView (debug)                     ├─ .tankDrive / .stopMotor ─▶ WedoManager (BLE)
                                              ├─ .speak ─────────────────▶ AVSpeechSynthesizer
                                              └─ .setEmotion ────────────▶ RobotFaceView (isHappy)
```

| Dosya | Katman | Sorumluluk |
|---|---|---|
| `MyLunaApp.swift`, `OrientationLock.swift` | Giriş | Uygulamayı başlatır, landscape kilidini `AppDelegate` üzerinden uygular |
| `ContentView.swift` | Orkestrasyon | WeDo `.ready` olunca kamerayı başlatır, 350 ms'lik tick döngüsü, action executor |
| `FaceTracker.swift` | Kamera/Görü | `AVCaptureSession` + `AVCaptureMetadataOutput` (.face); `turnSignal`, `driveSignal`, `detectedFaceBounds` yayınlar; `CameraPreviewView`/`PreviewUIView` yeşil yüz kutusunu çizer |
| `RobotEvent.swift` | Model | Ham sinyalden türetilen semantik olaylar (faceAcquired, faceLost, faceCentered, faceOffLeft/Right, ble*) |
| `RobotObservation.swift` | Model | Planner'a giden tek bağlam nesnesi; son 10 gözlemlik geçmiş taşır (ileride SLM/model tabanlı planner için) |
| `RobotAction.swift` | Model | Atomik davranışlar: `tankDrive`, `stopMotor`, `speak`, `setEmotion` |
| `BehaviorPlanner.swift` | Karar | Kural tabanlı event → action motoru; cooldown'lar, güç ve mesafe parametreleri |
| `WedoManager.swift` | BLE | Hub tarama/bağlanma, port bildirimlerinden motor atama, motor ve LED komutları |
| `RobotFaceView.swift` | UI | Alev gözler, göz kırpma, yanaklar, sağ üstteki debug butonu ve `DebugPanel` |

### Katman kuralları (bozmayın)

1. `FaceTrackerViewModel` asla robot komutu göndermez; yalnızca sinyal yayınlar.
2. `WedoManager` yüz dikdörtgenlerinden, UI'dan veya planner'dan habersizdir; sadece
   normalize güç (-1…1) alır.
3. `BehaviorPlanner` executor'ları bilmez; yalnızca `[RobotAction]` döndürür.
4. `ContentView` koordine eder; BLE baytı veya kamera iç detayı içermez.
5. Yeni bir davranış eklemek için: gerekirse `RobotEvent`'e case ekle →
   `deriveObservation` içinde türet → `plan(observation:)` içinde action'a çevir →
   gerekirse `RobotAction`'a case ekleyip `ContentView.execute` içinde yürüt.

## Başlatma sırası (deterministik kalmalı)

1. `ContentView.task` → `wedo.start()` (BLE taraması) ve tick döngüsü başlar.
2. `wedo.state == .ready` olunca `handleWeDoStateChange` → `vm.start()` (kamera izni,
   oturum yapılandırma, `startRunning`), 300 ms beklenir, sonra `cameraStarted = true`.
3. `tick()` `cameraStarted` false iken hiçbir şey yapmaz.
4. `.ready` dışındaki her duruma geçişte `bleDisconnected` gözlemi üretilir, motor durur ve
   kamera önizlemesi kaldırılır.

Kamera önizlemesi her zaman oluşturulur ama `showDebug` kapalıyken opaklığı 0'dır.

## Motor ve hareket modeli

- Mekanik düzen: iki motor birbirine **ters monte**. Bu yüzden
  - **aynı işaretli** güç (`left == right`) → robot **döner**,
  - **zıt işaretli** güç (`left == -right`) → robot **ileri/geri** gider.
  `RobotAction.tankDrive` doc yorumundaki "zıt işaret = dönüş" ifadesi bu düzen için yanlıştır;
  doğru kaynak `BehaviorPlanner` içindeki yorumlardır.
- Dönüş gücü yöne göre asimetriktir (`powerPositive = 0.28`, `powerNegative = 0.60`) — mekanik
  asimetriyi telafi eder, fiziksel testle ayarlanır.
- Merkezdeyken mesafe kontrolü: yüz genişliği `targetFaceWidth = 0.18` hedefine göre
  `drivePower = 0.30` ile ileri/geri (dead-zone `0.03`).
- Her `tankDrive` komutundan 280 ms sonra `ContentView` otomatik `stopAll()` çağırır (darbe
  tarzı hareket). Cooldown'lar: hareket 0.35 s, yön değişimi 0.3 s, selam 4 s.
- Yüz yok → dur. Yatay dead-zone `|turnSignal| < 0.08` → dönme.
- `WedoManager`: ilk gelen port bildirimi motor değilse bile geçici olarak "sol motor" kabul
  edilip `.ready` verilir; gerçek motor (deviceType == 1) gelince değiştirilir. İkinci motor
  sağ porta atanır. LED: mavi = tek/geçici port, yeşil = gerçek motor.
- BLE motor komutu: `[port, 0x01, 0x01, power]` (negatif güç `256 + power` ile kodlanır),
  output characteristic `0x1565`'e yazılır.

### Ayar noktaları (tuning)

| Parametre | Yer |
|---|---|
| `powerPositive`, `powerNegative`, `drivePower`, `targetFaceWidth`, `driveDeadZone`, cooldown'lar, `deadZoneThreshold` | `BehaviorPlanner.swift` |
| Dönüş kazancı (`horizontalError * 0.6`), yüz kabul filtresi (kenar %5, genişlik 0.02–0.8) | `FaceTracker.swift` → `updateSignals`, `handleDetectedFace` |
| Tick periyodu (350 ms), darbe süresi (280 ms), konuşma sesi/hızı | `ContentView.swift` |
| Gözlerdeki "centered" eşiği (0.08) | `RobotFaceView.swift` |

## Bilinen kırılgan alanlar ve tutarsızlıklar

- **Önizleme/overlay hizalaması** en kırılgan bölgedir: hem metadata bağlantısında hem
  önizleme katmanında `videoOrientation = .landscapeRight` ve `isVideoMirrored = true` sabit
  kodlanmıştır. Telefon ters (landscapeLeft) takılırsa hem kutu hem dönüş yönü ters döner.
  Yüz logu var ama yeşil kutu yoksa sebep büyük ihtimalle bu dönüşüm veya önizleme zamanlamasıdır.
- `videoOrientation` iOS 17'den beri deprecated (`videoRotationAngle` önerilir); değiştirmek
  hizalamayı etkileyeceği için ayrı ve test edilmiş bir iş olarak ele alın.
- Dead-zone `0.08` iki yerde tekrar ediyor (`BehaviorPlanner.deadZoneThreshold`,
  `RobotFaceView.isCentered`); birini değiştirirseniz diğerini de güncelleyin.
- `FaceTracker` kendi `targetFaceWidth = 0.22` değeriyle `driveSignal` hesaplar, ama
  planner `0.18` kullanır ve `driveSignal`'i okumaz. `throttleCommandOutput` logundaki
  sol/sağ formülü de gerçek motor düzenini yansıtmaz — yalnızca teşhis amaçlıdır.
- Kullanılmayan kod: `BehaviorPlanner.combinedActions`, `clamp`;
  `WedoManager.setSingleMotorTurn` (Agents.md'deki API sözleşmesinde geçiyor, ContentView artık
  `setTankDrive` kullanıyor); `FaceTrackerViewModel.stopTask/lastTurnDirection/lastMoveTime`.
  Silmeden önce Agents.md sözleşmesini de güncelleyin.
- `RobotObservation.faceVisibleDuration` tick süresini 0.35 s olarak varsayar; tick
  periyodu değişirse bunu da güncelleyin.

## Çalışma ilkeleri

1. Katmanları ayrı tutun; yukarıdaki katman kurallarını çiğneyen kısayol eklemeyin.
2. Çalışan BLE kodunu (`WedoManager`) gerekmedikçe yeniden yazmayın; değişiklikleri
   küçük ve geri alınabilir yapın.
3. Basit ve deterministik davranışı karmaşıklığa tercih edin.
4. Log yalnızca belirli bir hata ayıklama sorusunu yanıtlıyorsa eklenir ve zaman bazlı
   sınırlandırılır (mevcut `logFace`/`logNoFace` örüntüsü). Aşırı log, sürecin
   sonlandırılmasına yol açabiliyor.
5. Görsel hata ayıklama sırasında en az bir sabit debug overlay'i (yeşil kutu / DebugPanel)
   koruyun.
6. Kamera başlatma sırasını açık ve sabit tutun.
7. Motor yönü veya güç parametresi değiştiğinde bunun fiziksel robotta test edilmesi
   gerektiğini belirtin; derlenmesi doğru çalıştığı anlamına gelmez.
8. Kod yorumları Türkçe veya İngilizce olabilir; dokunduğunuz dosyanın mevcut diline uyun.
