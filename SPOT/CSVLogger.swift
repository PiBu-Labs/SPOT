//
//  CSVLogger.swift
//  SPOT
//
//  Created by Victor on 31.01.26.
//

import CoreLocation
import Foundation

@available(macOS 14, iOS 17, *)
final class CSVLogger {

    struct Snapshot {
        let location: CLLocation?
        let heading: CLHeading?
    }

    private var pendingEvent: String?
    private var pendingTTS: Double?
    
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var timer: DispatchSourceTimer?
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private var latest: Snapshot = .init(location: nil, heading: nil)
    private let lock = NSLock()
    
    func currentFileURL() -> URL? { fileURL }

    func update(location: CLLocation?, heading: CLHeading?) {
        lock.lock()
        latest = Snapshot(location: location, heading: heading)
        lock.unlock()
    }
    
    func update(pendingEvent: String?, pendingTTS: Double?) {
        lock.lock()
        self.pendingEvent = pendingEvent
        self.pendingTTS = pendingTTS
        lock.unlock()
    }

    func start(hz: Double = 1.0) throws {
        if fileHandle != nil { return }
        try openFileIfNeeded()
        startTimer(hz: hz)
    }

    func stop() {
        timer?.cancel()
        timer = nil

        do {
            try fileHandle?.close()
        } catch {
            // ignore
        }
        fileHandle = nil
    }

    // MARK: - Private

    private func openFileIfNeeded() throws {
        let fileManager = FileManager.default
        let docs = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!

        let now = Date()

        let folderFormatter = DateFormatter()
        folderFormatter.locale = Locale(identifier: "en_US_POSIX")
        folderFormatter.calendar = Calendar(identifier: .gregorian)
        folderFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        folderFormatter.dateFormat = "yyyyMMdd"

        let filenameFormatter = DateFormatter()
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.calendar = Calendar(identifier: .gregorian)
        filenameFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        filenameFormatter.dateFormat = "HHmmss"

        let folderURL = docs.appendingPathComponent(
            folderFormatter.string(from: now),
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )

        let baseName = "spot_log_\(filenameFormatter.string(from: now))"

        var url = folderURL.appendingPathComponent("\(baseName).csv")
        var suffix = 1

        while fileManager.fileExists(atPath: url.path) {
            url = folderURL.appendingPathComponent(
                "\(baseName)_\(suffix).csv"
            )
            suffix += 1
        }

        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: nil
        ) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }

        fileURL = url
        fileHandle = try FileHandle(forWritingTo: url)

        let header = [
            "utc_time",
            "lat_deg", "lon_deg",
            "alt_m",
            "hAcc_m", "vAcc_m",
            "trueHeading_deg", "magHeading_deg", "headingAcc_deg",
            "loc_age_s",
            "event", "tts_s"
        ].joined(separator: ",") + "\n"

        try fileHandle?.write(contentsOf: Data(header.utf8))
    }
    
    private func startTimer(hz: Double) {
        let interval = max(1.0 / hz, 0.05)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.writeRow() }
        t.resume()
        timer = t
    }

    private func writeRow() {
        guard let fh = fileHandle else { return }

        lock.lock()
        let snap = latest
        
        let consumedEvent = pendingEvent
        let consumedTTS   = pendingTTS
        pendingEvent = nil
        pendingTTS = nil
        lock.unlock()

        let now = Date()
        let timestamp = timeFormatter.string(from: now)

        let loc = snap.location
        let head = snap.heading

        let lat = loc.map { String(format: "%.8f", $0.coordinate.latitude) } ?? ""
        let lon = loc.map { String(format: "%.8f", $0.coordinate.longitude) } ?? ""
        let alt = loc.map { String(format: "%.3f", $0.altitude) } ?? ""
        let hAcc = loc.map { String(format: "%.3f", $0.horizontalAccuracy) } ?? ""
        let vAcc = loc.map { String(format: "%.3f", $0.verticalAccuracy) } ?? ""

        let headingTrue = head.map { String(format: "%.3f", $0.trueHeading) } ?? ""
        let headingMag  = head.map { String(format: "%.3f", $0.magneticHeading) } ?? ""
        let headingAcc  = head.map { String(format: "%.3f", $0.headingAccuracy) } ?? ""

        let locAge = loc.map { String(format: "%.3f", now.timeIntervalSince($0.timestamp)) } ?? ""
        
        let event = consumedEvent ?? ""
        let tts   = consumedTTS.map { String(format: "%.3f", $0) } ?? ""

        let row = [
            timestamp,
            lat, lon,
            alt,
            hAcc, vAcc,
            headingTrue, headingMag, headingAcc,
            locAge,
            event, tts
        ].joined(separator: ",") + "\n"

        do {
            try fh.write(contentsOf: Data(row.utf8))
        } catch {
        }
    }
}
