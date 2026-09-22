//
//  HotspotRequester.swift
//  ConduitCore
//
//  Asks nearby paired phones, over Bluetooth LE, to turn their hotspot on —
//  Shared/Protocol/README.md §8a.
//
//  This Mac only scans while it is asking, and only for Conduit's service. It
//  cannot tell from the advert which phone is which, so it connects to each
//  Conduit phone it finds and writes one signed request per paired phone; a
//  phone ignores any request not addressed to it or not signed by a Mac it
//  paired with.
//

import ConduitMedia
import CoreBluetooth
import Foundation

@MainActor
final class HotspotRequester: NSObject {

    enum Outcome: Equatable {
        /// This many phones took a request.
        case asked(Int)
        case noPhoneNearby
        case bluetoothOff
        case bluetoothDenied
        case failed(String)
    }

    private static let service = CBUUID(string: HotspotRequest.serviceUUID)
    private static let characteristic = CBUUID(string: HotspotRequest.characteristicUUID)
    private static let scanSeconds: Double = 15

    private var central: CBCentralManager?
    private var requests: [Data] = []
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pendingWrites: [UUID: Int] = [:]
    private var answered: Set<UUID> = []
    private var completion: ((Outcome) -> Void)?
    private var deadline: DispatchWorkItem?

    var isAsking: Bool { completion != nil }

    /// Ask with one pre-signed request per paired phone. Calls back once.
    func ask(_ requests: [Data], completion: @escaping (Outcome) -> Void) {
        guard !isAsking, !requests.isEmpty else { return }
        self.requests = requests
        self.completion = completion
        answered = []

        // Creating the manager is what asks for Bluetooth permission, so it
        // waits until the first real request.
        if let central {
            startScanningIfReady(central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }

        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            finish(answered.isEmpty ? .noPhoneNearby : .asked(answered.count))
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanSeconds, execute: deadline)
    }

    private func startScanningIfReady(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [Self.service], options: nil)
        case .poweredOff:
            finish(.bluetoothOff)
        case .unauthorized:
            finish(.bluetoothDenied)
        case .unsupported:
            finish(.failed("This Mac has no Bluetooth LE."))
        default:
            break // Resetting or unknown: the manager reports again shortly.
        }
    }

    private func finish(_ outcome: Outcome) {
        deadline?.cancel()
        deadline = nil
        central?.stopScan()
        for peripheral in peripherals.values { central?.cancelPeripheralConnection(peripheral) }
        peripherals.removeAll()
        pendingWrites.removeAll()
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }
}

// CoreBluetooth calls back on the main queue given to the manager.
extension HotspotRequester: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard isAsking else { return }
            startScanningIfReady(central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard isAsking, peripherals[peripheral.identifier] == nil else { return }
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard isAsking else { return }
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            CoreLog.engine.notice("could not connect to a nearby phone over Bluetooth")
            peripherals[peripheral.identifier] = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard isAsking, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
            peripheral.discoverCharacteristics([Self.characteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard isAsking,
                  let target = service.characteristics?.first(where: { $0.uuid == Self.characteristic })
            else { return }
            pendingWrites[peripheral.identifier] = requests.count
            for request in requests {
                peripheral.writeValue(request, for: target, type: .withResponse)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard isAsking else { return }
            if error == nil { answered.insert(peripheral.identifier) }
            let remaining = (pendingWrites[peripheral.identifier] ?? 1) - 1
            pendingWrites[peripheral.identifier] = remaining
            if remaining <= 0 {
                central?.cancelPeripheralConnection(peripheral)
                // One phone that took the request is enough to stop looking.
                if !answered.isEmpty { finish(.asked(answered.count)) }
            }
        }
    }
}
