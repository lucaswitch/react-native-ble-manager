import CoreBluetooth
import Foundation
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

@objc
public class SwiftBleManager: NSObject, CBCentralManagerDelegate,
    CBPeripheralDelegate
{
    static var shared: SwiftBleManager?
    static var sharedManager: CBCentralManager?

    private weak var bleManager: BleManager?
    private var manager: CBCentralManager?
    private var scanTimer: Timer?
    private var session: Any?

    private var peripherals: [String: Peripheral]
    private var connectCallbacks: [String: [RCTResponseSenderBlock]]
    private var readCallbacks: [String: [RCTResponseSenderBlock]]
    private var readRSSICallbacks: [String: [RCTResponseSenderBlock]]
    private var readDescriptorCallbacks: [String: [RCTResponseSenderBlock]]
    private var writeDescriptorCallbacks: [String: [RCTResponseSenderBlock]]
    private var retrieveServicesCallbacks: [String: [RCTResponseSenderBlock]]
    private var writeCallbacks: [String: [RCTResponseSenderBlock]]
    private var writeQueues: [String: [Data]]
    private var notificationCallbacks: [String: [RCTResponseSenderBlock]]
    private var stopNotificationCallbacks: [String: [RCTResponseSenderBlock]]
    private var bufferedCharacteristics: [String: NotifyBufferContainer]
    private var session: Any?
    private var connectedPeripherals: Set<String>

    private var retrieveServicesLatches: [String: Set<CBService>]
    private var characteristicsLatches: [String: Set<CBCharacteristic>]

    private let serialQueue = DispatchQueue(label: "BleManager.serialQueue")

    private var exactAdvertisingName: [String]

    static var verboseLogging = false

    @objc public init(bleManager: BleManager) {
        peripherals = [:]
        connectCallbacks = [:]
        readCallbacks = [:]
        readRSSICallbacks = [:]
        readDescriptorCallbacks = [:]
        writeDescriptorCallbacks = [:]
        retrieveServicesCallbacks = [:]
        writeCallbacks = [:]
        writeQueues = [:]
        notificationCallbacks = [:]
        stopNotificationCallbacks = [:]
        bufferedCharacteristics = [:]
        retrieveServicesLatches = [:]
        characteristicsLatches = [:]
        exactAdvertisingName = []
        connectedPeripherals = []
        self.bleManager = bleManager

        super.init()

        NSLog("BleManager created")

        SwiftBleManager.shared = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bridgeReloading),
            name: NSNotification.Name(
                rawValue: "RCTBridgeWillReloadNotification"
            ),
            object: nil
        )
    }


    @objc func bridgeReloading() {
        if let manager = manager {
            if let scanTimer = self.scanTimer {
                scanTimer.invalidate()
                self.scanTimer = nil
                manager.stopScan()
            }

            manager.delegate = nil
        }

        serialQueue.sync {
            for p in peripherals.values {
                p.instance.delegate = nil
            }
        }

        peripherals = [:]

        if #available(iOS 18.0, *) {
            serialQueue.sync {
                if let session = self.session as? ASAccessorySession {
                    session.invalidate()
                    self.session = nil
                }
            }
        }
    }

    // Helper method to find a peripheral by UUID
    func findPeripheral(byUUID uuid: String) -> Peripheral? {
        var foundPeripheral: Peripheral? = nil

        serialQueue.sync {
            if let peripheral = peripherals[uuid] {
                foundPeripheral = peripheral
            }
        }

        return foundPeripheral
    }

    // Helper method to insert callback in different queues
    func insertCallback(
        _ callback: @escaping RCTResponseSenderBlock,
        intoDictionary dictionary: inout [String: [RCTResponseSenderBlock]],
        withKey key: String
    ) {
        serialQueue.sync {
            var peripheralCallbacks =
                dictionary[key] ?? [RCTResponseSenderBlock]()
            peripheralCallbacks.append(callback)
            dictionary[key] = peripheralCallbacks
        }
    }

    // Helper method to call the callbacks for a specific peripheral and clear the queue
    func invokeAndClearDictionary(
        _ dictionary: inout [String: [RCTResponseSenderBlock]],
        withKey key: String,
        usingParameters parameters: [Any]
    ) {
        serialQueue.sync {
            invokeAndClearDictionary_THREAD_UNSAFE(
                &dictionary,
                withKey: key,
                usingParameters: parameters
            )
        }
    }

    private func enqueueSplitMessages(
        _ messages: [Data],
        forKey key: String
    ) -> (firstChunk: Data?, remainingCount: Int) {
        var chunkToSend: Data?
        var remainingCount = 0

        serialQueue.sync {
        }

        return (chunkToSend, remainingCount)
    }

    private func dequeueNextSplitMessage(forKey key: String) -> Data? {
        var nextMessage: Data?

        serialQueue.sync {
            if var queue = writeQueues[key], !queue.isEmpty {
                nextMessage = queue.removeFirst()
                writeQueues[key] = queue
            } else {
                writeQueues.removeValue(forKey: key)
            }
        }

        return nextMessage
    }

    func invokeAndClearDictionary_THREAD_UNSAFE(
        _ dictionary: inout [String: [RCTResponseSenderBlock]],
        withKey key: String,
        usingParameters parameters: [Any]
    ) {
        if let peripheralCallbacks = dictionary[key] {
            for callback in peripheralCallbacks {
                callback(parameters)
            }

            dictionary.removeValue(forKey: key)
        }
    }

    @objc func getContext(
        _ peripheralUUIDString: String,
        serviceUUIDString: String,
        characteristicUUIDString: String,
        prop: CBCharacteristicProperties,
        callback: @escaping RCTResponseSenderBlock
    ) -> BLECommandContext? {
        let serviceUUID = CBUUID(string: serviceUUIDString)
        let characteristicUUID = CBUUID(string: characteristicUUIDString)

        guard let peripheral = peripherals[peripheralUUIDString] else {
            let error = String(
                format: "Could not find peripheral with UUID %@",
                peripheralUUIDString
            )
            NSLog(error)
            callback([error])
            return nil
        }

        guard
            let service = Helper.findService(
                fromUUID: serviceUUID,
                peripheral: peripheral.instance
            )
        else {
            let error = String(
                format:
                    "Could not find service with UUID %@ on peripheral with UUID %@",
                serviceUUIDString,
                peripheral.instance.uuidAsString()
            )
            NSLog(error)
            callback([error])
            return nil
        }

        var characteristic = Helper.findCharacteristic(
            fromUUID: characteristicUUID,
            service: service,
            prop: prop
        )

        // Special handling for INDICATE. If characteristic with notify is not found, check for indicate.
        if prop == CBCharacteristicProperties.notify && characteristic == nil {
            characteristic = Helper.findCharacteristic(
                fromUUID: characteristicUUID,
                service: service,
                prop: CBCharacteristicProperties.indicate
            )
        }

        // As a last resort, try to find ANY characteristic with this UUID, even if it doesn't have the correct properties
        if characteristic == nil {
            characteristic = Helper.findCharacteristic(
                fromUUID: characteristicUUID,
                service: service
            )
        }

        guard let finalCharacteristic = characteristic else {
            let error = String(
                format:
                    "Could not find characteristic with UUID %@ on service with UUID %@ on peripheral with UUID %@",
                characteristicUUIDString,
                serviceUUIDString,
                peripheral.instance.uuidAsString()
            )
            NSLog(error)
            callback([error])
            return nil
        }

        let context = BLECommandContext()
        context.peripheral = peripheral
        context.service = service
        context.characteristic = finalCharacteristic
        return context
    }

    @objc public func start(
        _ options: NSDictionary,
        callback: RCTResponseSenderBlock
    ) {
        if SwiftBleManager.verboseLogging {
            NSLog("BleManager initialized")
        }
        if let bluetoothUsageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription"
        ) as? String {
            // NSBluetoothAlwaysUsageDescription is ok
        } else {
            let error =
                "NSBluetoothAlwaysUsageDescription is not set in the infoPlist"
            NSLog(error)
            callback([error])
            return
        }
        var initOptions = [String: Any]()

        if let showAlert = options["showAlert"] as? Bool {
            initOptions[CBCentralManagerOptionShowPowerAlertKey] = showAlert
        }

        if let verboseLogging = options["verboseLogging"] as? Bool {
            SwiftBleManager.verboseLogging = verboseLogging
        }

        var queue: DispatchQueue
        if let queueIdentifierKey = options["queueIdentifierKey"] as? String {
            queue = DispatchQueue(
                label: queueIdentifierKey,
                qos: DispatchQoS.background
            )
        } else {
            queue = DispatchQueue.main
        }

        if let restoreIdentifierKey = options["restoreIdentifierKey"] as? String
        {
            initOptions[CBCentralManagerOptionRestoreIdentifierKey] =
                restoreIdentifierKey

            if let sharedManager = SwiftBleManager.sharedManager {
                manager = sharedManager
                manager?.delegate = self
            } else {
                manager = CBCentralManager(
                    delegate: self,
                    queue: queue,
                    options: initOptions
                )
                SwiftBleManager.sharedManager = manager
            }
        } else {
            manager = CBCentralManager(
                delegate: self,
                queue: queue,
                options: initOptions
            )
            SwiftBleManager.sharedManager = manager
        }

        callback([])
    }

    @objc public func isStarted(_ callback: RCTResponseSenderBlock) {
        let started = manager != nil
        callback([NSNull(), started])
    }

    @objc public func scan(
        _ scanningOptions: NSDictionary,
        callback: RCTResponseSenderBlock
    ) {
        if Int(truncating: scanningOptions["seconds"] as? NSNumber ?? 0) > 0 {
            NSLog("scan with timeout \(scanningOptions["seconds"] ?? 0)")
        } else {
            NSLog("scan")
        }

        // Clear the peripherals before scanning again, otherwise cannot connect again after disconnection
        // Only clear peripherals that are not connected - otherwise connections fail silently (without any
        // onDisconnect* callback).
        serialQueue.sync {
            let disconnectedPeripherals = peripherals.filter({
                $0.value.instance.state != .connected
                    && $0.value.instance.state != .connecting
            })
            disconnectedPeripherals.forEach { (uuid, peripheral) in
                peripheral.instance.delegate = nil
                peripherals.removeValue(forKey: uuid)
            }
        }

        var serviceUUIDs = [CBUUID]()
        if let serviceUUIDStrings = scanningOptions["serviceUUIDStrings"]
            as? [String]
        {
            serviceUUIDs = serviceUUIDStrings.map { CBUUID(string: $0) }
        }

        var options: [String: Any]?
        let allowDuplicates =
            scanningOptions["allowDuplicates"] as? Bool ?? false
        if allowDuplicates {
            options = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        }

        exactAdvertisingName.removeAll()
        if let names = scanningOptions["exactAdvertisingName"] as? [String] {
            exactAdvertisingName.append(contentsOf: names)
        }

        manager?.scanForPeripherals(
            withServices: serviceUUIDs,
            options: options
        )

        let timeoutSeconds = scanningOptions["seconds"] as? Double ?? 0
        if timeoutSeconds > 0 {
            if let scanTimer = scanTimer {
                scanTimer.invalidate()
                self.scanTimer = nil
            }
            DispatchQueue.main.async {
                self.scanTimer = Timer.scheduledTimer(
                    timeInterval: timeoutSeconds,
                    target: self,
                    selector: #selector(self.stopTimer),
                    userInfo: nil,
                    repeats: false
                )
            }
        }

        callback([])
    }

    @objc func stopTimer() {
        NSLog("Stop scan")
        scanTimer = nil
        manager?.stopScan()
        bleManager?.emit(onStopScan: ["status": 10])
    }

    @objc public func stopScan(_ callback: @escaping RCTResponseSenderBlock) {
        if let scanTimer = self.scanTimer {
            scanTimer.invalidate()
            self.scanTimer = nil
        }

        manager?.stopScan()

        bleManager?.emit(onStopScan: ["status": 0])

        callback([])
    }

    @objc public func connect(
        _ peripheralUUID: String,
        options: NSDictionary,
        callback: @escaping RCTResponseSenderBlock
    ) {

        if let peripheral = peripherals[peripheralUUID] {
            // Found the peripheral, connect to it
            NSLog("Connecting to peripheral with UUID: \(peripheralUUID)")

            insertCallback(
                callback,
                intoDictionary: &connectCallbacks,
                withKey: peripheral.instance.uuidAsString()
            )
            manager?.connect(peripheral.instance)
        } else {
            // Try to retrieve the peripheral
            NSLog("Retrieving peripheral with UUID: \(peripheralUUID)")

            if let uuid = UUID(uuidString: peripheralUUID) {
                let peripheralArray = manager?.retrievePeripherals(
                    withIdentifiers: [uuid])
                if let retrievedPeripheral = peripheralArray?.first {
                    serialQueue.sync {
                        peripherals[retrievedPeripheral.uuidAsString()] =
                            Peripheral(peripheral: retrievedPeripheral)
                    }
                    NSLog(
                        "Successfully retrieved and connecting to peripheral with UUID: \(peripheralUUID)"
                    )

                    // Connect to the retrieved peripheral
                    insertCallback(
                        callback,
                        intoDictionary: &connectCallbacks,
                        withKey: retrievedPeripheral.uuidAsString()
                    )
                    manager?.connect(retrievedPeripheral, options: nil)
                } else {
                    let error = "Could not find peripheral \(peripheralUUID)."
                    NSLog(error)
                    callback([error, NSNull()])
                }
            } else {
                let error = "Wrong UUID format \(peripheralUUID)"
                callback([error, NSNull()])
            }
        }
    }

    @objc public func disconnect(
        _ peripheralUUID: String,
        force: Bool,
        callback: @escaping RCTResponseSenderBlock
    ) {
        if let peripheral = peripherals[peripheralUUID] {
            NSLog("Disconnecting from peripheral with UUID: \(peripheralUUID)")

            if let services = peripheral.instance.services {
                for service in services {
                    if let characteristics = service.characteristics {
                        for characteristic in characteristics {
                            if characteristic.isNotifying {
                                NSLog(
                                    "Remove notification from: \(characteristic.uuid)"
                                )
                                peripheral.instance.setNotifyValue(
                                    false,
                                    for: characteristic
                                )
                            }
                        }
                    }
                }
            }

            manager?.cancelPeripheralConnection(peripheral.instance)
            callback([])

        } else {
            let error = "Could not find peripheral \(peripheralUUID)."
            NSLog(error)
            callback([error])
        }
    }

    @objc public func retrieveServices(
        _ peripheralUUID: String,
        services: [String],
        callback: @escaping RCTResponseSenderBlock
    ) {
        NSLog("retrieveServices \(services)")

        if let peripheral = peripherals[peripheralUUID],
            peripheral.instance.state == .connected
        {
            insertCallback(
                callback,
                intoDictionary: &retrieveServicesCallbacks,
                withKey: peripheral.instance.uuidAsString()
            )

            var uuids: [CBUUID] = []
            for string in services {
                let uuid = CBUUID(string: string)
                uuids.append(uuid)
            }

            if !uuids.isEmpty {
                peripheral.instance.discoverServices(uuids)
            } else {
                peripheral.instance.discoverServices(nil)
            }

        } else {
            callback(["Peripheral not found or not connected"])
        }
    }

    @objc public func readRSSI(
        _ peripheralUUID: String,
        callback: @escaping RCTResponseSenderBlock
    ) {
        NSLog("readRSSI")

        if let peripheral = peripherals[peripheralUUID],
            peripheral.instance.state == .connected
        {
            insertCallback(
                callback,
                intoDictionary: &readRSSICallbacks,
                withKey: peripheral.instance.uuidAsString()
            )
            peripheral.instance.readRSSI()
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }

    @objc public func readDescriptor(
        _ peripheralUUID: String,
        serviceUUID: String,
        characteristicUUID: String,
        descriptorUUID: String,
        callback: @escaping RCTResponseSenderBlock
    ) {
        NSLog("readDescriptor")

        guard
            let context = getContext(
                peripheralUUID,
                serviceUUIDString: serviceUUID,
                characteristicUUIDString: characteristicUUID,
                prop: CBCharacteristicProperties.read,
                callback: callback
            )
        else {
            return
        }

        let peripheral = context.peripheral
        let characteristic = context.characteristic

        guard
            let descriptor = Helper.findDescriptor(
                fromUUID: CBUUID(string: descriptorUUID),
                characteristic: characteristic!
            )
        else {
            let error =
                "Could not find descriptor with UUID \(descriptorUUID) on characteristic with UUID \(String(describing: characteristic?.uuid.uuidString)) on peripheral with UUID \(peripheralUUID)"
            NSLog(error)
            callback([error])
            return
        }

        if let peripheral = peripheral?.instance {

        }

        peripheral?.instance.readValue(for: descriptor)
    }

                                      serviceUUID: String,
                                      characteristicUUID: String,
                                      descriptorUUID: String,
                                      message: [UInt8],
        NSLog("writeDescriptor")

            return
        }

        let peripheral = context.peripheral
        let characteristic = context.characteristic

            NSLog(error)
            callback([error])
            return
        }

        if let peripheral = peripheral?.instance {

        }

        let dataMessage = Data(message)
        peripheral?.instance.writeValue(dataMessage, for: descriptor)
    }

        NSLog("Get discovered peripherals")
        var discoveredPeripherals: [[String: Any]] = []

        serialQueue.sync {
            for (_, peripheral) in peripherals {
                discoveredPeripherals.append(peripheral.advertisingInfo())
            }
        }

        callback([NSNull(), discoveredPeripherals])
    }

        NSLog("Get connected peripherals")
        var serviceUUIDs: [CBUUID] = []

        for uuidString in serviceUUIDStrings {
            serviceUUIDs.append(CBUUID(string: uuidString))
        }

        var connectedPeripherals: [Peripheral] = []

        if serviceUUIDs.isEmpty {
            serialQueue.sync {
                    p.value
                })
            }
        } else {

            serialQueue.sync {
                for ph in connectedCBPeripherals {
                    if let peripheral = peripherals[ph.uuidAsString()] {
                        connectedPeripherals.append(peripheral)
                    } else {
                    }
                }
            }
        }

        var foundedPeripherals: [[String: Any]] = []

        for peripheral in connectedPeripherals {
            foundedPeripherals.append(peripheral.advertisingInfo())
        }

        callback([NSNull(), foundedPeripherals])
    }


        if let peripheral = peripherals[peripheralUUID] {
            callback([NSNull(), peripheral.instance.state == .connected])
        } else {
            callback(["Peripheral not found"])
        }
    }

    @objc public func isScanning(_ callback: @escaping RCTResponseSenderBlock) {
        if let manager = manager {
            callback([NSNull(), manager.isScanning])
        } else {
            callback(["CBCentralManager not found"])
        }
    }

    @objc public func checkState(_ callback: @escaping RCTResponseSenderBlock) {
        if let manager = manager {
            centralManagerDidUpdateState(manager)

            let stateName = Helper.centralManagerStateToString(manager.state)
            callback([stateName])
        }
    }

                            serviceUUID: String,
                            characteristicUUID: String,
                            message: [UInt8],
                            maxByteSize: Int,
        NSLog("write")

            return
        }

        let dataMessage = Data(message)


            if SwiftBleManager.verboseLogging {
            }

            if dataMessage.count > maxByteSize {
                var count = 0
                var offset = 0
                    count += maxByteSize
                    offset += maxByteSize
                }

                if count < dataMessage.count {
                }

                if SwiftBleManager.verboseLogging {
                }

                }
            } else {
            }
        }
    }

                                           serviceUUID: String,
                                           characteristicUUID: String,
                                           message: [UInt8],
                                           maxByteSize: Int,
                                           queueSleepTime: Int,
        NSLog("writeWithoutResponse")

            return
        }

        let dataMessage = Data(message)

        if SwiftBleManager.verboseLogging {
        }

        if dataMessage.count > maxByteSize {
            var offset = 0
            let peripheral = context.peripheral
            guard let characteristic = context.characteristic else { return }

            repeat {
                let thisChunkSize = min(maxByteSize, dataMessage.count - offset)

                offset += thisChunkSize

                let sleepTimeSeconds = TimeInterval(queueSleepTime) / 1000
                Thread.sleep(forTimeInterval: sleepTimeSeconds)
            } while offset < dataMessage.count

            callback([])
        } else {
            let peripheral = context.peripheral
            guard let characteristic = context.characteristic else { return }

            callback([])
        }
    }

                           serviceUUID: String,
                           characteristicUUID: String,
        NSLog("read")

            return
        }

        let peripheral = context.peripheral
        let characteristic = context.characteristic

        insertCallback(callback, intoDictionary: &readCallbacks, withKey: key)

        peripheral?.instance.readValue(for: characteristic!)  // callback sends value
    }

                                                  serviceUUID: String,
                                                  characteristicUUID: String,
                                                  bufferLength: NSNumber,
        NSLog("startNotificationWithBuffer")

            peripheralUUID,
            serviceUUIDString: serviceUUID,
            characteristicUUIDString: characteristicUUID,
            prop: CBCharacteristicProperties.notify,
            callback: callback
        guard let peripheral = context.peripheral else { return }
        guard let characteristic = context.characteristic else { return }



        peripheral.instance.setNotifyValue(true, for: characteristic)
    }

                                        serviceUUID: String,
                                        characteristicUUID: String,
        NSLog("startNotification")

            return
        }

        guard let peripheral = context.peripheral else { return }
        guard let characteristic = context.characteristic else { return }


        peripheral.instance.setNotifyValue(true, for: characteristic)
    }

                                       serviceUUID: String,
                                       characteristicUUID: String,
        NSLog("stopNotification")

            return
        }

        let peripheral = context.peripheral
        guard let characteristic = context.characteristic else { return }

        if characteristic.isNotifying {

            // Remove any buffered data if notification was started with buffer
            self.bufferedCharacteristics.removeValue(forKey: key)

            peripheral?.instance.setNotifyValue(false, for: characteristic)
            NSLog("Characteristic stopped notifying")
        } else {
            NSLog("Characteristic is not notifying")
            callback([])
        }
    }

        NSLog("getMaximumWriteValueLengthForWithoutResponse")

        guard let peripheral = peripherals[peripheralUUID] else {
            callback(["Peripheral not found or not connected"])
            return
        }

        if peripheral.instance.state == .connected {
            callback([NSNull(), max])
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }

        NSLog("getMaximumWriteValueLengthForWithResponse")

        guard let peripheral = peripherals[peripheralUUID] else {
            callback(["Peripheral not found or not connected"])
            return
        }

        if peripheral.instance.state == .connected {
            callback([NSNull(), max])
        } else {
            callback(["Peripheral not found or not connected"])
        }
    }

            serialQueue.sync {
                var data = [[String: Any]]()
                for peripheral in restoredPeripherals {
                    let p = Peripheral(peripheral:peripheral)
                    peripherals[peripheral.uuidAsString()] = p
                    data.append(p.advertisingInfo())
                    peripheral.delegate = self
                }
            }
        }
    }

        NSLog("Peripheral Connected: \(peripheral.uuidAsString() )")
        peripheral.delegate = self

        /*
         The state of the peripheral isn't necessarily updated until a small
         delay after didConnectPeripheral is called and in the meantime
         didFailToConnectPeripheral may be called
         */
        DispatchQueue.main.async {
                // didFailToConnectPeripheral should have been called already if not connected by now

                self.connectedPeripherals.insert(peripheral.uuidAsString())
            }
        }
    }

                               didFailToConnect peripheral: CBPeripheral,
        NSLog(errorStr)

    }

                               didDisconnectPeripheral peripheral:
        let peripheralUUIDString:String = peripheral.uuidAsString()
        NSLog("Peripheral Disconnected: \(peripheralUUIDString)")

        if let error = error {
            NSLog("Error: \(error)")
        }

        let errorStr = "Peripheral did disconnect: \(peripheralUUIDString)"


        for key in readCallbacks.keys {
            }
        }

        for key in writeCallbacks.keys {
            }
        }

        for key in notificationCallbacks.keys {
            }
        }

        for key in readDescriptorCallbacks.keys {
            }
        }

        for key in stopNotificationCallbacks.keys {
            }
        }

            if let keyString = key as String? {
                return keyString.hasPrefix(peripheralUUIDString)
            }
            return false
        }
        for key in bufferedCharacteristicsKeysToRemove {
            bufferedCharacteristics.removeValue(forKey: key)
        }

        connectedPeripherals.remove(peripheralUUIDString)
        if let e:Error = error {
        } else {
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateName = Helper.centralManagerStateToString(central.state)
        self.bleManager?.emit(onDidUpdateState: ["state": stateName])
        if stateName == "off" {
            for peripheralUUID in connectedPeripherals {
                if let peripheral = peripherals[peripheralUUID] {
                    if peripheral.instance.state == .disconnected {
                    }
                }
            }
        }
    }

                                    advertisementData: [String : Any],
        if SwiftBleManager.verboseLogging {
        }

        var cp: Peripheral? = nil
        serialQueue.sync {
            if let p = peripherals[peripheral.uuidAsString()] {
                cp = p
                cp?.setRSSI(rssi)
                cp?.setAdvertisementData(advertisementData)
            } else {
                peripherals[peripheral.uuidAsString()] = cp
            }
        }

        self.bleManager?.emit(onDiscoverPeripheral: cp?.advertisingInfo())
    }

                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String : Any],
        if exactAdvertisingName.count > 0 {
            if let peripheralName = peripheral.name {
                if exactAdvertisingName.contains(peripheralName) {
                } else {
                        if exactAdvertisingName.contains(localName) {
                        }
                    }
                }
            }
        } else {
        }

    }

        if let error = error {
            NSLog("Error: \(error)")
            return
        }
        if SwiftBleManager.verboseLogging {
            NSLog("Services Discover")
        }

        var servicesForPeripheral = Set<CBService>()
        servicesForPeripheral.formUnion(peripheral.services ?? [])

        if let services = peripheral.services {
            for service in services {
                if SwiftBleManager.verboseLogging {
                }
                peripheral.discoverIncludedServices(nil, for: service) // discover included services
                peripheral.discoverCharacteristics(nil, for: service) // discover characteristics for service
            }
        }
    }

                           didDiscoverIncludedServicesFor service: CBService,
        if let error = error {
            NSLog("Error: \(error)")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service) // discover characteristics for included service
    }

                           didDiscoverCharacteristicsFor service: CBService,
        if let error = error {
            NSLog("Error: \(error)")
            return
        }
        if SwiftBleManager.verboseLogging {
            NSLog("Characteristics For Service Discover")
        }

        var characteristicsForService = Set<CBCharacteristic>()
        characteristicsForService.formUnion(service.characteristics ?? [])

        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
    }

                           didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        if let error = error {
            NSLog("Error: \(error)")
            return
        }
        let peripheralUUIDString:String = peripheral.uuidAsString()

        if SwiftBleManager.verboseLogging {
        }


            characteristicsLatch.remove(characteristic)
            characteristicsLatches[serviceUUIDString] = characteristicsLatch

            if characteristicsLatch.isEmpty {
                // All characteristics for this service have been checked
                servicesLatch.remove(characteristic.service!)
                retrieveServicesLatches[peripheralUUIDString] = servicesLatch

                if servicesLatch.isEmpty {
                    // All characteristics and services have been checked
                    if let peripheral = peripherals[peripheral.uuidAsString()] {
                    }
                }
            }

        }
    }

                           didReadRSSI RSSI: NSNumber,
        if SwiftBleManager.verboseLogging {
            print("didReadRSSI \(RSSI)")
        }

        if let error = error {
        } else {
        }
    }

                           didUpdateValueFor descriptor: CBDescriptor,

        if let error = error {
            return
        }

        if let descriptorValue = descriptor.value as? Data {
        } else {
        }

        if readDescriptorCallbacks[key] != nil {
            // The most future proof way of doing this that I could find, other option would be running strcmp on CBUUID strings
            // https://developer.apple.com/documentation/corebluetooth/cbuuid/characteristic_descriptors
            if let descriptorValue = descriptor.value as? Data {
                    NSLog("Descriptor value is Data")
                }
            } else if let descriptorValue = descriptor.value as? NSNumber {
                    NSLog("Descriptor value is NSNumber")
                }
                var value = descriptorValue.uint64Value
            } else if let descriptorValue = descriptor.value as? String {
                    NSLog("Descriptor value is String")
                }
                if let byteData = descriptorValue.data(using: .utf8) {
                }
            } else {
                if let descriptorValue = descriptor.value as? Data {
                }
            }
        }
    }

                           didUpdateValueFor characteristic: CBCharacteristic,

        if let error = error {
            NSLog("Error \(characteristic.uuid) :\(error)")
            return
        }

        if SwiftBleManager.verboseLogging, let value = characteristic.value {
        }

        serialQueue.sync {
            if readCallbacks[key] != nil {
            } else {
                    // Standard notification
                    self.bleManager?.emitOnDidUpdateValue(forCharacteristic: [
                        "peripheral": peripheral.uuidAsString(),
                    ])
                    return
                }

                // Notification with buffer
                var valueToEmit: Data = characteristic.value!
                    let rest = bufferContainer.put(valueToEmit)
                    if bufferContainer.isBufferFull {
                            "peripheral": peripheral.uuidAsString(),
                        ])
                        bufferContainer.resetBuffer()
                    }

                    valueToEmit = rest
                }
            }
        }
    }

                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
        if let error = error {

            // Remove any buffered data if notification was started with buffer
            self.bufferedCharacteristics.removeValue(forKey: key)

            self.bleManager?.emitOnDidUpdateNotificationState(for: [
                "peripheral": peripheral.uuidAsString(),
                "characteristic": characteristic.uuid.uuidString.lowercased(),
                "isNotifying": false,
                "domain": error._domain,
            ])
        } else {
            self.bleManager?.emitOnDidUpdateNotificationState(for: [
                "peripheral": peripheral.uuidAsString(),
                "characteristic": characteristic.uuid.uuidString.lowercased(),
            ])
        }


        if let error = error {
            if notificationCallbacks[key] != nil {
            }
            if stopNotificationCallbacks[key] != nil {
            }
        } else {
            if characteristic.isNotifying {
                if SwiftBleManager.verboseLogging {
                    NSLog("Notification began on \(characteristic.uuid)")
                }
                if notificationCallbacks[key] != nil {
                }
            } else {
                // Notification has stopped
                if SwiftBleManager.verboseLogging {
                    NSLog("Notification ended on \(characteristic.uuid)")
                }
                if stopNotificationCallbacks[key] != nil {
                }
            }
        }
    }

                           didWriteValueFor descriptor: CBDescriptor,
        NSLog("didWrite descriptor")

        let callbacks = writeDescriptorCallbacks[key]
        if callbacks != nil {
            if let error = error {
                NSLog("\(error)")
            } else {
            }
        }
    }

                           didWriteValueFor characteristic: CBCharacteristic,
        NSLog("didWrite")

        let peripheralWriteCallbacks = writeCallbacks[key]

        if peripheralWriteCallbacks != nil {
            if let error = error {
                NSLog("\(error)")
                } else {
                    NSLog("Message to write \(message.hexadecimalString())")
                }
            }
        }
    }

    @objc public static func getCentralManager() -> CBCentralManager? {
        return sharedManager
    }

    @objc public static func getInstance() -> SwiftBleManager? {
        return shared
    }

        callback(["Not supported"])
    }

        callback(["Not supported"])
    }

                                 devicePin: String,
        callback(["Not supported"])
    }

        callback(["Not supported"])
    }

        callback(["Not supported"])
    }

                                 mtu: Int,
        callback(["Not supported"])
    }

                                                connectionPriority: Int,
        callback(["Not supported"])
    }

        callback(["Not supported"])
    }

    @objc public func setName(_ name: String) {
        // Not supported
    }

        callback(["Not supported"])
    }

        callback(["Not supported"])
    }

        callback([NSNull(), false])
    }

                                    option: NSDictionary,
        callback(["Not supported"])
    }

    @available(iOS 18.0, *)
    private func createJsAccessory(_ accessory: ASAccessory) -> [String: Any] {
        var jsAccessory: [String: Any] = [:]
        guard let serviceUUID = accessory.descriptor.bluetoothServiceUUID?.uuidString else {
            fatalError("Could not get accessory serviceUUID")
        }
        guard let id = accessory.bluetoothIdentifier?.uuidString else {
            fatalError("Could not get accessory id")
        }
        jsAccessory["id"] = id
        jsAccessory["name"] = accessory.displayName
        jsAccessory["state"] = NSNumber(value: accessory.state.rawValue)
        jsAccessory["serviceUUID"] = serviceUUID
        return jsAccessory
    }

    @objc public func accessoriesScan(_ displayItems: [[String: String]], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if #available(iOS 18.0, *) {
            self.stopAccessoriesScan(); // safely end previous session

            // Safely reject invalid configurations.
            if displayItems.isEmpty {
                reject("INVALID_DISPLAY_ITEMS", "You should provide at least one accessory scan display item.", nil);
                return;
            }
            if Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") == nil {
                reject("INCORRECT_ACCESSORY_KIT_SETUP", "NSAccessorySetupKitSupports not present in the app plist, please add it correctly.", nil);
                return;
            }
            guard let names = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothNames") as? [String] else {
                reject("INCORRECT_ACCESSORY_KIT_SETUP", "NSAccessorySetupBluetoothNames not present in the app plist, please add a accessory name into NSAccessorySetupBluetoothNames on plist.", nil);
                return;
            }

            var items: [ASPickerDisplayItem] = []
            if let pListServices = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothServices") as? [String] {
                for d in displayItems {
                    guard let name = d["name"], !name.isEmpty else {
                        reject("INVALID_DISPLAY_ITEM_NAME", "One of display items does not contain a valid \"name\"", nil)
                        return
                    }
                    if !names.contains(name) {
                        reject("INVALID_DISPLAY_ITEM_NAME", "\"\(name)\" should be present on plist NSAccessorySetupBluetoothNames array", nil)
                        return
                    }
                    guard let serviceUUID = d["serviceUUID"], !serviceUUID.isEmpty else {
                        reject("INVALID_SERVICE_UUID_SERVICE_UUID", "One of display items does not contain a valid \"serviceUUID\"", nil)
                        return
                    }
                    guard let productImage = d["productImage"], !serviceUUID.isEmpty else {
                        reject("INVALID_PRODUCT_IMAGE", "One of display items does not contain a valid \"productImage\"", nil)
                        return
                    }
                    if !pListServices.contains(serviceUUID) {
                        reject("INVALID_SERVICE_UUID_SERVICE_UUID", "service \"\(serviceUUID)\" should be present on plist NSAccessorySetupBluetoothServices", nil)
                        return
                    }
                    guard let productImage = UIImage(named: productImage) else {
                        reject("INVALID_PRODUCT_IMAGE", "Could not find an IOS productImage with the name \"\(productImage)\".", nil)
                        return
                    }

                    let descriptor = ASDiscoveryDescriptor()
                    descriptor.bluetoothServiceUUID = CBUUID(string: serviceUUID)
                    descriptor.bluetoothNameSubstring = name
                    items.append(
                        ASPickerDisplayItem(
                            name: name,
                            productImage: productImage,
                            descriptor: descriptor
                        )
                    )
                }
            } else {
                reject("INCORRECT_ACCESSORY_KIT_SETUP", "NSAccessorySetupBluetoothServices not present in the app plist, please add your desired bluetooth service to be searched in the app plist.", nil);
                return;
            }

            func toArray(_ map: [UUID: ASAccessory]) -> [[String: Any]] {
                return map.values.map { accessory in
                    return self.createJsAccessory(accessory)
                }
            }

            var map = [UUID : ASAccessory]()
            let session = ASAccessorySession()
            session.activate(on: DispatchQueue.main) { [weak self] event in
                guard let self else { return }

                switch event.eventType {
                    case .activated:
                        session.showPicker(for: items) { error in
                            if let error = error as NSError? {
                                let message = error.localizedDescription
                                reject("COULD_NOT_SHOW_PICKER", message, nil)
                                if !invalidated  {
                                    session.invalidate()
                                }
                            } else {
                                self.bleManager?.emit(onStartScanAccessories: [:])
                                resolve(session.accessories.map {
                                    accessory in self.createJsAccessory(accessory)
                                })
                            }
                        }

                    case .invalidated:
                        self.bleManager?.emit(onStopScanAccessories: [:])

                    case .accessoryAdded, .accessoryChanged:
                        if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                            map[uuid] = accessory
                            self.bleManager?.emit(onAccessoriesChanged: ["accessories": toArray(map)])
                        }

                    case .accessoryRemoved:
                        if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                            map.removeValue(forKey: uuid)
                            self.bleManager?.emit(onAccessoriesChanged: ["accessories": toArray(map)])
                        }

                    default:
                        self.bleManager?.emit(onAccessorySessionUpdateState: NSNumber(value: event.eventType.rawValue))
                }
            }
            self.session = session;
        } else {
            reject("NOT_SUPPORTED", "requires iOS 18.0 or newer.", nil)
        }
    }

    @objc public func getConnectedAccessories(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if #available(iOS 18.0, *){
            self.stopAccessoriesScan(); // safely end previous session

            let session = ASAccessorySession()
            resolve(
                session.accessories.map { accessory in
                    return self.createJsAccessory(accessory)
                }
            )
        } else {
            reject("NOT_SUPPORTED", "requires iOS 18.0 or newer.", nil)
        }
    }

    @objc public func stopAccessoriesScan() {
        if #available(iOS 18.0, *) {
            if let session = self.session as? ASAccessorySession {
                session.invalidate()
                self.session = nil
            }
        }
    }

    @objc public func getAccessoryKitSupported() -> Bool {
        #if canImport(AccessorySetupKit)
            return true
        #else
            return false
        #endif
    }
}
