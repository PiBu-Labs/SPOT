//
//  ContentView.swift
//  SPOT
//
//  Created by Tania Krisanty on 01.08.25.
//

import SwiftUI
import UIKit
import CoreLocation

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var server: Server
    
    let name: String
    
    enum Field {
        case first
        case second
    }
    
    @FocusState private var focusedField: Field?
    
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    
    @State private var didAutoStartLogging = false
    
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    @State private var tagIdInput = "101"
    @State private var tagSizeInput = ""

    // 0-based indexing (0...2114)
    let minId = 0
    let maxId = 2114
    
    // Dimension in cm
    let minSize: Float = 0.5
    let maxSize: Float = 3.0
    
    private var parsedTagId: Int {
        if let id = Int(tagIdInput), (minId...maxId).contains(id) {
            return id
        }
        return minId
    }
    
    private var parsedTagSize: Float {
        if let size = parseLocalizedFloat(tagSizeInput), (minSize...maxSize).contains(size) {
            return size
        }
        return maxSize
    }
    
    private var buttonLabel: String {
        switch focusedField {
        case .first:
            return "Next"
        case .second:
            return "Done"
        default:
            return ""
        }
    }
    
    private func parseLocalizedFloat(_ s: String) -> Float? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        // 1) Try current locale (e.g., de_DE expects a comma)
        formatter.locale = .current
        if let n = formatter.number(from: trimmed) { return n.floatValue }

        // 2) Also accept dot-based input (e.g., copy/paste)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.number(from: trimmed)?.floatValue
    }
    
    private func formatLocalized(_ value: Float, fractionDigits: Int = 2) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = fractionDigits
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
    
    private func formatDuration(_ s: TimeInterval) -> String {
        let total = max(0, Int(s.rounded()))
        let m = total / 60
        let r = total % 60
        return String(format: "%02d:%02d", m, r)
    }
    
    var body: some View {
        VStack {
            TextField("Enter AprilTag ID (\(minId) - \(maxId))", text: $tagIdInput)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .first)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onChange(of: tagIdInput, { oldValue, newValue in
                    if let value = Int(newValue) {
                        if value < minId {
                            tagIdInput = "\(minId)"
                        } else if value > maxId {
                            tagIdInput = "\(maxId)"
                        }
                    } else {
                        tagIdInput = "\(minId)"
                    }
                })
            
            TextField("Enter AprilTag size (in cm) (\(minSize) - \(maxSize))", text: $tagSizeInput)
                .keyboardType(.decimalPad) // for decimal numbers
                .focused($focusedField, equals: .second)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            
            Text(server.getServerURL())
                .font(.headline)
                .padding()
            
            Text("Your location: \(String(format: "%.8f, %.8f", server.lastLocation?.coordinate.latitude ?? 0, server.lastLocation?.coordinate.longitude ?? 0))")
            Text("Your heading: \(server.lastHeading?.trueHeading ?? 0)\u{00B0}")
            
            if let image = apriltagImage(for: parsedTagId) {
                let points = fullTagPixelWidth(forInnerSizeCM: parsedTagSize) / UIScreen.main.scale

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: points, height: points)
                    .padding()
                    .opacity(server.displayTag ? 1 : 0)
            }
            
            Text("Logging")
                .font(.headline)
                .padding()
            
            if server.isLogging {
                if let t0 = server.stableEventSentAt {
                    Text("Stable for \(formatDuration(now.timeIntervalSince(t0)))")
                } else {
                    Text("Waiting for stable fix…")
                }
                
                Button("Stop log") { server.stopLogging() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else {
                if let url = server.csvFileURL {
                    Text(url.absoluteString)
                }
                
                Button("Start log") { server.startLogging() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(name)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button(buttonLabel) {
                    switch focusedField {
                    case .first:
                        focusedField = .second
                    case .second:
                        focusedField = nil
                        
                        if !tagSizeInput.isEmpty {
                            if let value = parseLocalizedFloat(tagSizeInput) {
                                if value < Float(minSize) {
                                    tagSizeInput = formatLocalized(minSize)
                                } else if value > Float(maxSize) {
                                    tagSizeInput = formatLocalized(maxSize)
                                }
                            } else {
                                tagSizeInput = formatLocalized(maxSize)
                            }
                        }
                        
                    case .none:
                        break
                    }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            
            if !didAutoStartLogging && !server.isLogging {
                didAutoStartLogging = true
                server.startLogging()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            
            if server.isLogging {
                server.stopLogging()
            }
        }
        .onReceive(ticker) { now = $0 }
        .task {
            try? await server.run()
        }
    }
    
    func deviceIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
    
    private static let ppiByDeviceIdentifier: [String: CGFloat] = [
        "iPhone18,5": 460, // iPhone 17e
        "iPhone18,4": 460, // iPhone Air
        "iPhone18,3": 460, // iPhone 17
        "iPhone18,2": 460, // iPhone 17 Pro Max
        "iPhone18,1": 460, // iPhone 17 Pro
        "iPhone17,5": 460, // iPhone 16e
        "iPhone17,4": 460, // iPhone 16 Plus
        "iPhone17,3": 460, // iPhone 16
        "iPhone17,2": 460, // iPhone 16 Pro Max
        "iPhone17,1": 460, // iPhone 16 Pro
        "iPhone16,2": 460, // iPhone 15 Pro Max
        "iPhone16,1": 460, // iPhone 15 Pro
        "iPhone15,5": 460, // iPhone 15 Plus
        "iPhone15,4": 460, // iPhone 15
        "iPhone15,3": 460, // iPhone 14 Pro Max
        "iPhone15,2": 460, // iPhone 14 Pro
        "iPhone14,8": 458, // iPhone 14 Plus
        "iPhone14,7": 460, // iPhone 14
        "iPhone14,6": 326, // iPhone SE 3rd Gen
        "iPhone14,5": 460, // iPhone 13
        "iPhone14,4": 476, // iPhone 13 Mini
        "iPhone14,3": 458, // iPhone 13 Pro Max
        "iPhone14,2": 460, // iPhone 13 Pro
        "iPhone13,4": 458, // iPhone 12 Pro Max
        "iPhone13,3": 460, // iPhone 12 Pro
        "iPhone13,2": 460, // iPhone 12
        "iPhone13,1": 476, // iPhone 12 Mini
        "iPhone12,8": 326, // iPhone SE 2nd Gen
        "iPhone12,5": 458, // iPhone 11 Pro Max
        "iPhone12,3": 458, // iPhone 11 Pro
        "iPhone12,1": 326, // iPhone 11
        "iPhone11,8": 326, // iPhone XR
        "iPhone11,6": 326, // iPhone XS Max Global
        "iPhone11,4": 458, // iPhone XS Max
        "iPhone11,2": 458, // iPhone XS
        "iPhone10,6": 458, // iPhone X GSM
    ]
    
    func ppiForDevice() -> CGFloat {
        let identifier = deviceIdentifier()

        if let ppi = Self.ppiByDeviceIdentifier[identifier] {
            return ppi
        }

        assertionFailure(
            "Unknown device identifier \(identifier); using 460 ppi fallback"
        )

        return 460
    }
    
    func fullTagPixelWidth(forInnerSizeCM cm: Float) -> CGFloat {
        let fullTagToInnerTagRatio: CGFloat = 9.0 / 5.0
        let inches = fullTagToInnerTagRatio * CGFloat(cm) / 2.54

        return inches * ppiForDevice()
    }
    
    func apriltagImage(for id: Int) -> UIImage? {
        guard let atlas = UIImage(named: "AprilTags")?.cgImage else { return nil }

        let columns = 45
        let tagSize = CGSize(width: 9, height: 9)
        let padding: CGFloat = 1

        let row = id / columns
        let col = id % columns

        let x = CGFloat(col) * (tagSize.width + padding)
        let y = CGFloat(row) * (tagSize.height + padding)
        let cropRect = CGRect(origin: CGPoint(x: x, y: y), size: tagSize)

        guard let cropped = atlas.cropping(to: cropRect) else { return nil }

        return UIImage(cgImage: cropped)
    }
}
