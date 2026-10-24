import Foundation
import CoreBluetooth
import Combine

/// Prints a standardized Bluetooth log line for WeDo-related debugging.
///
/// - Parameter items: Arbitrary values to be stringified and printed.
func btlog(_ items: Any...) {
    let text = items.map { String(describing: $0) }.joined(separator: " ")
    print("[WeDo]", text)
}

/// Manages BLE communication with a LEGO WeDo / LPF2 Smart Hub.
///
/// Responsibilities:
/// - scan for compatible hubs
/// - connect to the selected hub
/// - discover services and characteristics
/// - initialize the motor port
/// - expose user-facing connection state
/// - convert normalized turn values into motor power commands
///
/// Current design assumptions:
/// - the app currently uses a single motor in active control mode
/// - the left motor slot is treated as the primary controllable motor
/// - the BLE layer should remain independent from camera and UI logic
@MainActor
final class WedoManager: NSObject, ObservableObject {
    /// Represents the high-level BLE lifecycle state of the WeDo connection.
    enum ConnectionState: String {
        /// No active scan or connection is currently in progress.
        case idle = "Idle"

        /// Bluetooth is unavailable, disabled, or not ready yet.
        case bluetoothOff = "Bluetooth Off"

        /// The manager is currently scanning for peripherals.
        case scanning = "Scanning"

        /// The manager found a target and is attempting to connect.
        case connecting = "Connecting"

        /// The BLE connection has been established, but setup may not be finished yet.
        case connected = "Connected"

        /// The hub is ready to receive motor commands.
        case ready = "Ready"

        /// The connection attempt failed.
        case failed = "Failed"
    }

    /// The current BLE connection state.
    @Published var state: ConnectionState = .idle

    /// A user-facing status text suitable for UI display.
    @Published var statusText: String = "WeDo not started"

    /// The last commanded power value for the left motor.
    @Published var leftMotorPower: Int = 0

    /// The last commanded power value for the right motor.
    ///
    /// Note:
    /// In the current single-motor version, this is mostly diagnostic.
    @Published var rightMotorPower: Int = 0

    private var centralManager: CBCentralManager!
    private var hubPeripheral: CBPeripheral?
    private var outputCharacteristic: CBCharacteristic?
    private var inputCharacteristic: CBCharacteristic?
    private var portTypeCharacteristic: CBCharacteristic?

    private var leftMotorPort: UInt8?
    private var rightMotorPort: UInt8?
    /// leftMotorPort gerçek motor mu (deviceType==1), yoksa geçici sensör portu mu?
    private var leftMotorIsReal: Bool = false

    /// A list of name fragments used to identify candidate LEGO hubs.
    ///
    /// Matching is intentionally permissive because BLE advertising names
    /// are not always perfectly stable across environments and firmware versions.
    private let targetNameCandidates = [
        "LEGO WEDO 2.0 HUB",
        "WEDO",
        "LPF2",
        "SMART HUB",
        "HUB"
    ]

    /// The primary LEGO BLE service UUID used by the hub.
    private let serviceUUID = CBUUID(string: "00001523-1212-EFDE-1523-785FEABCD123")

    /// The characteristic used to send motor or LED output commands.
    private let outputCommandUUID = CBUUID(string: "00001565-1212-EFDE-1523-785FEABCD123")

    /// The characteristic used for input-side initialization commands such as motor-port setup.
    private let inputCommandUUID  = CBUUID(string: "00001563-1212-EFDE-1523-785FEABCD123")

    /// The characteristic used to receive port-type notifications.
    private let portTypeUUID      = CBUUID(string: "00001527-1212-EFDE-1523-785FEABCD123")

    /// The characteristic used to receive sensor values.
    ///
    /// This is not actively used yet in the current face-following prototype,
    /// but it is kept for future extension.
    private let sensorValueUUID   = CBUUID(string: "00001560-1212-EFDE-1523-785FEABCD123")

    /// Creates the BLE manager and immediately initializes `CBCentralManager`.
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    /// Starts the BLE workflow.
    ///
    /// Behavior:
    /// - if Bluetooth is already powered on, scanning starts immediately
    /// - otherwise the manager waits for `centralManagerDidUpdateState`
    func start() {
        btlog("start() called, bluetooth state =", centralManager.state.rawValue)

        if centralManager.state == .poweredOn {
            startScanning()
        } else {
            state = .bluetoothOff
            statusText = "Bluetooth hazırlanıyor..."
            btlog("Bluetooth not ready yet, waiting for callback")
        }
    }

    /// Disconnects from the currently connected hub, if any.
    func disconnect() {
        guard let hubPeripheral else { return }
        btlog("Disconnect requested")
        centralManager.cancelPeripheralConnection(hubPeripheral)
    }

    /// Sets tank-style drive values for left and right motors.
    ///
    /// - Parameters:
    ///   - left: A normalized left motor value in the range `-1.0 ... 1.0`.
    ///   - right: A normalized right motor value in the range `-1.0 ... 1.0`.
    ///
    /// Note:
    /// The current project does not actively use dual-motor tank control,
    /// but this method is preserved for future expansion.
    func setTankDrive(left: Double, right: Double) {
        let l = Self.scalePower(left)
        let r = Self.scalePower(right)

        leftMotorPower = l
        rightMotorPower = r

        btlog("setTankDrive", "left=", l, "right=", r)

        if let leftMotorPort {
            sendMotorPower(port: leftMotorPort, power: l)
        }
        if let rightMotorPort {
            sendMotorPower(port: rightMotorPort, power: r)
        }
    }

    /// Stops all active motor output.
    ///
    /// In the current implementation this resets both left and right drive channels to zero.
    func stopAll() {
        btlog("stopAll()")
        setTankDrive(left: 0, right: 0)
    }

    /// Drives the currently assigned single motor using a normalized turn value.
    ///
    /// - Parameter turn:
    ///   A normalized value in the range `-1.0 ... 1.0`.
    ///
    /// Interpretation:
    /// - negative: rotate one direction
    /// - positive: rotate the opposite direction
    ///
    /// Note:
    /// In the current prototype, the first detected motor is assigned to the left slot
    /// and used as the single active motor.
    func setSingleMotorTurn(turn: Double) {
        let clipped = max(-0.25, min(0.25, turn))
        // Minimum güç: çok küçük sinyaller motoru hareket ettiremiyor
        let p = Self.scalePower(clipped)
        let finalPower = p == 0 ? 0 : (p > 0 ? max(p, 10) : min(p, -10))
        leftMotorPower = finalPower
        rightMotorPower = 0

        btlog("setSingleMotorTurn", "turn=", turn, "power=", finalPower)

        if let leftMotorPort {
            sendMotorPower(port: leftMotorPort, power: finalPower)
        }
    }

    /// Starts BLE scanning for candidate peripherals.
    private func startScanning() {
        state = .scanning
        statusText = "WeDo aranıyor..."
        btlog("Scanning started...")
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Connects to a specific discovered peripheral.
    ///
    /// - Parameter peripheral: The candidate BLE peripheral.
    private func connect(to peripheral: CBPeripheral) {
        btlog("Connecting to", peripheral.name ?? "<no name>", peripheral.identifier.uuidString)
        state = .connecting
        statusText = "WeDo bağlanıyor..."
        hubPeripheral = peripheral
        peripheral.delegate = self
        centralManager.stopScan()
        centralManager.connect(peripheral, options: nil)
    }

    /// Requests service discovery from the connected hub.
    private func discoverHubServices() {
        btlog("Discovering services...")
        hubPeripheral?.discoverServices(nil)
    }

    /// Requests characteristic discovery for a given service.
    ///
    /// - Parameter service: The service whose characteristics should be discovered.
    private func discoverCharacteristics(for service: CBService) {
        btlog("Discovering characteristics for service", service.uuid.uuidString)
        hubPeripheral?.discoverCharacteristics(
            [outputCommandUUID, inputCommandUUID, portTypeUUID, sensorValueUUID],
            for: service
        )
    }

    /// Enables notifications for characteristics that require streaming updates.
    ///
    /// - Parameter characteristic: The characteristic to configure.
    private func setupNotificationsIfNeeded(_ characteristic: CBCharacteristic) {
        guard let peripheral = hubPeripheral else { return }
        if characteristic.uuid == portTypeUUID {
            btlog("Enabling notifications for portTypeUUID")
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Sends a motor-port initialization command to the hub.
    ///
    /// - Parameters:
    ///   - port: The target motor port identifier.
    ///   - connectedDevice: The connected device type, defaulting to motor.
    ///   - mode: The initialization mode.
    ///   - valueFormat: The value format expected by the hub.
    ///
    /// This mirrors the initialization pattern used in the Python prototype.
    private func initializeMotorPort(_ port: UInt8,
                                     connectedDevice: UInt8 = 1,
                                     mode: UInt8 = 0x02,
                                     valueFormat: UInt8 = 0x00) {
        guard let peripheral = hubPeripheral, let inputCharacteristic else {
            btlog("initializeMotorPort skipped, missing peripheral/inputCharacteristic")
            return
        }

        let command = Data([0x01, 0x02, port, connectedDevice, mode, 0x01, 0x00, 0x00, 0x00, valueFormat, 0x01])
        btlog("Initializing motor port", port, "bytes=", command.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(command, for: inputCharacteristic, type: .withResponse)
    }

    /// Sends a raw motor power command to a specific port.
    ///
    /// - Parameters:
    ///   - port: The motor port identifier.
    ///   - power: A signed power value in the range `-100 ... 100`.
    private func sendMotorPower(port: UInt8, power: Int) {
        guard let peripheral = hubPeripheral, let outputCharacteristic else {
            btlog("sendMotorPower skipped, missing peripheral/outputCharacteristic")
            return
        }

        let value = encodeMotorPower(power)
        let command = Data([port, 0x01, 0x01, value])
        btlog("Motor cmd", "port=", port, "power=", power, "encoded=", value,
              "bytes=", command.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(command, for: outputCharacteristic, type: .withResponse)
    }

    /// Sets the hub LED color.
    ///
    /// - Parameters:
    ///   - red: Red channel intensity.
    ///   - green: Green channel intensity.
    ///   - blue: Blue channel intensity.
    func setLED(red: UInt8, green: UInt8, blue: UInt8) {
        guard let peripheral = hubPeripheral, let outputCharacteristic else {
            btlog("setLED skipped, missing peripheral/outputCharacteristic")
            return
        }

        let command = Data([0x06, 0x04, 0x03, red, green, blue])
        btlog("LED cmd", "r=", red, "g=", green, "b=", blue,
              "bytes=", command.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        peripheral.writeValue(command, for: outputCharacteristic, type: .withoutResponse)
    }

    /// Assigns the first usable motor port as the active single-motor control port.
    ///
    /// - Parameter port: The detected motor port identifier.
    private func assignMotorPort(_ port: UInt8) {
        if leftMotorPort == nil {
            leftMotorPort = port
            leftMotorIsReal = false
            btlog("Assigned MOTOR port =", port)
            // initializeMotorPort(port)  ← bu satırı sil veya yorum satırı yap
            state = .ready
            statusText = "Motor portu hazır: \(port)"
            btlog("WeDo READY (single motor)")
            setLED(red: 0, green: 0, blue: 255)
        }
    }

    /// Parses a port-type notification and reacts to detected motor connections.
    ///
    /// - Parameter data: The raw BLE notification payload.
    private func handlePortNotification(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            btlog("Port notify too short:", bytes)
            return
        }

        let portID = bytes[0]
        let isConnected = bytes[1]
        let deviceType = bytes[3]

        btlog("Port notify:", "port=", portID, "connected=", isConnected, "deviceType=", deviceType)

        if isConnected == 1 {
            if deviceType == 1 {
                // Gerçek motor.
                if !leftMotorIsReal && leftMotorPort != nil {
                    // leftMotorPort geçici sensör portuydu — gerçek motorla değiştir
                    btlog("Replacing temp port \(String(describing: leftMotorPort)) with real motor port \(portID)")
                    leftMotorPort = portID
                    leftMotorIsReal = true
                    btlog("Left motor (real) assigned to port \(portID)")
                } else if leftMotorPort == nil {
                    leftMotorPort = portID
                    leftMotorIsReal = true
                    btlog("Left motor assigned to port \(portID)")
                } else if rightMotorPort == nil && portID != leftMotorPort {
                    rightMotorPort = portID
                    btlog("Right motor assigned to port \(portID)")
                } else {
                    btlog("Motor port \(portID) ignored (already have both)")
                }

                if state != .ready {
                    state = .ready
                    statusText = "Motorlar hazır"
                    btlog("WeDo READY (dual motor)")
                    setLED(red: 0, green: 255, blue: 0)
                }
            } else if leftMotorPort == nil && rightMotorPort == nil {
                btlog("No motor yet, temporarily accepting port \(portID) (deviceType=\(deviceType))")
                assignMotorPort(portID)
            }
        }
    }
    
    /// Converts a normalized control value to a signed motor power integer.
    ///
    /// - Parameter value: A normalized value in the range `-1.0 ... 1.0`.
    /// - Returns: A rounded integer in the range `-100 ... 100`.
    private static func scalePower(_ value: Double) -> Int {
        let clipped = max(-1.0, min(1.0, value))
        return Int((clipped * 100.0).rounded())
    }

    /// Encodes a signed motor power value into the hub-specific byte representation.
    ///
    /// Encoding rules:
    /// - positive values are encoded directly
    /// - negative values are encoded using `256 + power`
    /// - zero is encoded as `0`
    ///
    /// - Parameter power: A signed motor power in the range `-100 ... 100`.
    /// - Returns: The encoded byte value.
    private func encodeMotorPower(_ power: Int) -> UInt8 {
        let clipped = max(-100, min(100, power))
        if clipped > 0 { return UInt8(clipped) }
        if clipped < 0 { return UInt8(256 + clipped) }
        return 0
    }
}

// MARK: - CBCentralManagerDelegate
extension WedoManager: CBCentralManagerDelegate {

    /// Called whenever the Bluetooth central manager changes state.
    ///
    /// - Parameters:
    ///   - central: The central manager whose state changed.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        btlog("centralManagerDidUpdateState =", central.state.rawValue)

        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.state = .idle
                self.statusText = "Bluetooth hazır"
                btlog("Bluetooth is powered on")

                // If Bluetooth became ready later, begin scanning here.
                if self.hubPeripheral == nil {
                    self.startScanning()
                }

            default:
                self.state = .bluetoothOff
                self.statusText = "Bluetooth kapalı veya izin yok"
                btlog("Bluetooth not available:", central.state.rawValue)
            }
        }
    }

    /// Called when a BLE peripheral is discovered during scanning.
    ///
    /// - Parameters:
    ///   - central: The scanning central manager.
    ///   - peripheral: The discovered peripheral.
    ///   - advertisementData: The advertisement payload.
    ///   - RSSI: The signal strength.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any],
                                    rssi RSSI: NSNumber) {
        let peripheralName = peripheral.name ?? ""
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let mergedName = peripheralName.isEmpty ? advName : peripheralName

        let upper = mergedName.uppercased()
        let matched =
            targetNameCandidates.contains(where: { upper.contains($0) }) ||
            upper.contains("LEGO") ||
            upper.contains("WEDO") ||
            upper.contains("LPF2") ||
            upper.contains("SMART HUB") ||
            upper.contains("HUB")

        // Only log matched candidates — ignore everything else silently
        guard matched else { return }

        btlog("Matched candidate:", mergedName.isEmpty ? "<no name>" : mergedName,
              "rssi=\(RSSI)")

        Task { @MainActor in
            if self.hubPeripheral == nil {
                self.connect(to: peripheral)
            } else {
                btlog("Already have a peripheral, skipping connect")
            }
        }
    }

    /// Called after a successful BLE connection.
    ///
    /// - Parameters:
    ///   - central: The central manager.
    ///   - peripheral: The connected peripheral.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        btlog("CONNECTED:", peripheral.name ?? "<no name>", peripheral.identifier.uuidString)

        Task { @MainActor in
            self.state = .connected
            self.statusText = "WeDo bağlandı"
            self.discoverHubServices()
        }
    }

    /// Called when a BLE connection attempt fails.
    ///
    /// - Parameters:
    ///   - central: The central manager.
    ///   - peripheral: The peripheral that failed to connect.
    ///   - error: The connection error, if any.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        btlog("FAILED TO CONNECT:", peripheral.name ?? "<no name>", error?.localizedDescription ?? "unknown")

        Task { @MainActor in
            self.state = .failed
            self.statusText = "Bağlantı başarısız: \(error?.localizedDescription ?? "unknown")"
        }
    }

    /// Called when the peripheral disconnects.
    ///
    /// - Parameters:
    ///   - central: The central manager.
    ///   - peripheral: The disconnected peripheral.
    ///   - error: The disconnect error, if any.
    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        btlog("DISCONNECTED:", peripheral.name ?? "<no name>", error?.localizedDescription ?? "no error")

        Task { @MainActor in
            self.hubPeripheral = nil
            self.outputCharacteristic = nil
            self.inputCharacteristic = nil
            self.portTypeCharacteristic = nil
            self.leftMotorPort = nil
            self.rightMotorPort = nil
            self.leftMotorIsReal = false
            self.state = .idle
            self.statusText = "WeDo bağlantısı koptu"
        }
    }
}

// MARK: - CBPeripheralDelegate
extension WedoManager: CBPeripheralDelegate {
    /// Called after service discovery completes.
    ///
    /// - Parameters:
    ///   - peripheral: The connected peripheral.
    ///   - error: A discovery error, if any.
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        if let error {
            btlog("didDiscoverServices ERROR:", error.localizedDescription)
            return
        }

        guard let services = peripheral.services else {
            btlog("didDiscoverServices: no services")
            return
        }

        for service in services {
            btlog("SERVICE:", service.uuid.uuidString)
        }

        for service in services {
            Task { @MainActor in
                btlog("Discovering characteristics on service", service.uuid.uuidString)
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    /// Called after characteristic discovery completes for a service.
    ///
    /// - Parameters:
    ///   - peripheral: The connected peripheral.
    ///   - service: The service whose characteristics were discovered.
    ///   - error: A discovery error, if any.
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        if let error {
            btlog("didDiscoverCharacteristics ERROR:", error.localizedDescription)
            return
        }

        guard let characteristics = service.characteristics else {
            btlog("No characteristics found for service", service.uuid.uuidString)
            return
        }

        btlog("Characteristics for service", service.uuid.uuidString)

        Task { @MainActor in
            for characteristic in characteristics {
                btlog("CHAR:", characteristic.uuid.uuidString,
                      "props=", characteristic.properties.rawValue)

                if characteristic.uuid.uuidString.uppercased() == outputCommandUUID.uuidString.uppercased() {
                    self.outputCharacteristic = characteristic
                    btlog("Output characteristic ready")
                } else if characteristic.uuid.uuidString.uppercased() == inputCommandUUID.uuidString.uppercased() {
                    self.inputCharacteristic = characteristic
                    btlog("Input characteristic ready")
                } else if characteristic.uuid.uuidString.uppercased() == portTypeUUID.uuidString.uppercased() {
                    self.portTypeCharacteristic = characteristic
                    btlog("Port type characteristic ready, enabling notify")
                    self.setupNotificationsIfNeeded(characteristic)
                }
            }

            if self.outputCharacteristic != nil && self.inputCharacteristic != nil {
                self.statusText = "WeDo komut kanalı hazır"
                btlog("Command channel ready")
            }
        }
    }

    /// Called when the peripheral updates the value of a characteristic.
    ///
    /// - Parameters:
    ///   - peripheral: The connected peripheral.
    ///   - characteristic: The characteristic whose value changed.
    ///   - error: An update error, if any.
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            btlog("didUpdateValueFor ERROR:", error.localizedDescription)
            return
        }

        guard let data = characteristic.value else {
            btlog("didUpdateValueFor empty data")
            return
        }

        btlog("NOTIFY from",
              characteristic.uuid.uuidString,
              "bytes=",
              data.map { String(format: "0x%02X", $0) }.joined(separator: " "))

        Task { @MainActor in
            if characteristic.uuid == self.portTypeUUID {
                self.handlePortNotification(data)
            }
        }
    }
}
