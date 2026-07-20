//
//  SPOTApp.swift
//  SPOT
//
//  Created by Tania Krisanty on 01.08.25.
//

import SwiftUI

@main
struct SpotApp: App {
    @StateObject private var server = Server()
    
    var body: some Scene {
        WindowGroup {
            MapView()
                .tint(.orange)
                .environmentObject(server)
        }
    }
}
