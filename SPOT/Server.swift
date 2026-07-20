// Portions of the WebSocket server implementation are adapted from SwiftNIO
//
// SwiftNIO is licensed under the Apache License, Version 2.0
// See the project repository and LICENSE notices for attribution

import CoreLocation
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

@available(macOS 14, iOS 17, *)
class Server : NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager: CLLocationManager
    
    private let host: String
    private let port: Int
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    
    private var isRunning = false
    
    var csvFileURL: URL? { csvLogger.currentFileURL() }
    
    @Published private(set) var isLocationStable = false
    @Published private(set) var stableFixCount = 0

    @Published private(set) var isStreaming = false
    @Published private(set) var isLogging = false

    private let requiredStableFixes: Int = 5
    private let stableHorizontalAccuracyMeters: CLLocationAccuracy = 2.5
    private let stableMaxAgeSeconds: TimeInterval = 2.0
    
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastHeading: CLHeading?

    private var loggingStartTime: Date? = nil
    private var stableEventSent = false

    @Published private(set) var stableEventSentAt: Date? = nil
    
    private let csvLogger = CSVLogger()

    @Published private(set) var displayTag = false
        
    enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }
    
    init(host: String = "0.0.0.0", port: Int = 8888, eventLoopGroup: MultiThreadedEventLoopGroup = .singleton) {
        self.host = host
        self.port = port
        self.eventLoopGroup = eventLoopGroup
        
        self.locationManager = CLLocationManager()
        
        super.init()
        
        setupLocationServices()
    }
        
    private func setupLocationServices() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .other

        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    // MARK: - Public controls

    func startLogging() {
        guard isLogging == false else { return }

        do {
            loggingStartTime = Date()
            stableEventSent = false
            stableEventSentAt = nil
            
            try csvLogger.start(hz: 15.0)
            isLogging = true
            
            // If we're already stable at the moment logging starts, emit immediately (TTS = 0)
            if isLocationStable {
                stableEventSent = true
                stableEventSentAt = Date()
                csvLogger.update(pendingEvent: "LOCATION_STABLE", pendingTTS: 0.0)
            }
        } catch {
            // If opening/writing the file fails, keep logging disabled
            isLogging = false
            print("CSV logger failed to start: \(error)")
        }
    }

    func stopLogging() {
        guard isLogging else { return }
        csvLogger.stop()
        isLogging = false
        
        loggingStartTime = nil
        stableEventSent = false
        stableEventSentAt = nil

        if let url = csvLogger.currentFileURL() {
            print("CSV saved at: \(url)")
        }
    }
    
    func getServerURL() -> String {
        if let hotspotIP = getHotspotIPAddress() {
            return "Server running at ws://\(hotspotIP):\(port)"
        } else {
            return("Enable hotspot and try again")
        }
    }
    
    private func getHotspotIPAddress() -> String? {
        var address: String?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Look for IPv4 addresses on `bridge` interfaces (Personal Hotspot)
            if addrFamily == UInt8(AF_INET), name.hasPrefix("bridge") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(interface.ifa_addr.pointee.sa_len)

                let result = getnameinfo(
                    interface.ifa_addr,
                    saLen,
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                if result == 0 {
                    address = String(cString: hostname)
                    break
                }
            }
        }

        freeifaddrs(ifaddr)
        return address
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        DispatchQueue.main.async {
            self.lastLocation = loc
            self.csvLogger.update(location: self.lastLocation, heading: self.lastHeading)

            // --- Stabilization rule ---
            // 1) horizontalAccuracy must be valid and under a threshold
            // 2) fix must be fresh (timestamp age under threshold)
            // 3) must hold for N consecutive updates
            let age = Date().timeIntervalSince(loc.timestamp)
            let acc = loc.horizontalAccuracy

            let isStableNow = (acc >= 0) && (acc <= self.stableHorizontalAccuracyMeters) && (age <= self.stableMaxAgeSeconds)

            if isStableNow {
                self.stableFixCount += 1
            } else {
                self.stableFixCount = 0
                self.isLocationStable = false
                // We do NOT automatically stop streaming if it later becomes unstable
            }

            if self.stableFixCount >= self.requiredStableFixes {
                if self.isLocationStable == false {
                    // First time reaching stable: mark stable and auto-start streaming
                    self.isLocationStable = true
                    self.isStreaming = true
                    self.displayTag = true
                }
                
                // Emit LOCATION_STABLE once per logging session
                if self.isLogging && !self.stableEventSent {
                    self.stableEventSent = true
                    let now = Date()
                    self.stableEventSentAt = now

                    let tts = self.loggingStartTime.map { now.timeIntervalSince($0) }
                    self.csvLogger.update(pendingEvent: "LOCATION_STABLE", pendingTTS: tts)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.lastHeading = newHeading
            self.csvLogger.update(location: self.lastLocation, heading: self.lastHeading)
        }
    }
    
    func run() async throws {
        await MainActor.run {
            if isRunning { return }
            isRunning = true
        }
        
        let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(
            group: self.eventLoopGroup
        )
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(
            host: self.host,
            port: self.port
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                    shouldUpgrade: { (channel, head) in
                        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { (channel, _) in
                        channel.eventLoop.makeCompletedFuture {
                            let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                wrappingChannelSynchronously: channel
                            )
                            return UpgradeResult.websocket(asyncChannel)
                        }
                    }
                )

                let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let asyncChannel = try NIOAsyncChannel<
                                HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>
                            >(wrappingChannelSynchronously: channel)
                            return UpgradeResult.notUpgraded(asyncChannel)
                        }
                    }
                )

                let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                    configuration: .init(upgradeConfiguration: serverUpgradeConfiguration)
                )

                return negotiationResultFuture
            }
        }

        try await withThrowingDiscardingTaskGroup { group in
            try await channel.executeThenClose { inbound in
                for try await upgradeResult in inbound {
                    group.addTask {
                        await self.handleUpgradeResult(upgradeResult)
                    }
                }
            }
        }
    }

    private func handleUpgradeResult(_ upgradeResult: EventLoopFuture<UpgradeResult>) async {
        do {
            switch try await upgradeResult.get() {
            case .websocket(let websocketChannel):
                print("Handling websocket connection")
                try await self.handleWebsocketChannel(websocketChannel)
                print("Done handling websocket connection")
            case .notUpgraded(_):
                print("HTTP connection is not handled")
            }
        } catch {
            print("Hit error: \(error)")
        }
    }

    private func handleWebsocketChannel(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async throws {
        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in inbound {
                        switch frame.opcode {
                        case .ping:
                            print("Received ping")
                            var frameData = frame.data
                            let maskingKey = frame.maskKey

                            if let maskingKey = maskingKey {
                                frameData.webSocketUnmask(maskingKey)
                            }

                            let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
                            try await outbound.write(responseFrame)

                        case .connectionClose:
                            print("Received close")
                            var data = frame.unmaskedData
                            let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
                            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
                            try await outbound.write(closeFrame)
                            return
                                                       
                        case .binary, .continuation, .pong:
                            break
                        default:
                            return
                        }
                    }
                }

                group.addTask {
                    let int64Size = MemoryLayout<Int64>.size
                    let doubleSize = MemoryLayout<Double>.size

                    while true {
                        if self.isStreaming,
                           let location = self.lastLocation,
                           let heading = self.lastHeading {
                            
                            // 1 byte marker + 1 Int64 timestamp + 3 Doubles
                            var buffer = channel.channel.allocator.buffer(
                                capacity: 1 + (1 * int64Size) + (3 * doubleSize)
                            )

                            // Marker
                            buffer.writeInteger(UInt8(255))

                            // Timestamp as Int64 (ms since 1970)
                            let timestampMs = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
                            buffer.writeInteger(timestampMs, endianness: .little)

                            // Payload
                            self.writeDouble(location.coordinate.latitude, to: &buffer)
                            self.writeDouble(location.coordinate.longitude, to: &buffer)
                            self.writeDouble(heading.trueHeading, to: &buffer)
 
                            let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                            
                            print("Sending location")
                            try await outbound.write(frame)
                        }
                        
                        try await Task.sleep(for: .milliseconds(70))
                    }
                }

                try await group.next()
                group.cancelAll()
            }
        }
    }
        
    private func writeDouble(_ value: Double, to buffer: inout ByteBuffer) {
        var bitPattern = value.bitPattern.littleEndian
        _ = withUnsafeBytes(of: &bitPattern) { bytes in
            buffer.writeBytes(bytes)
        }
    }
}
