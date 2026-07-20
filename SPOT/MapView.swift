//
//  MapView.swift
//  SPOT
//
//  Created by Victor on 25.08.25.
//

import SwiftUI
import MapKit

struct SelectedPlace {
    let name: String
    let coord: CLLocationCoordinate2D
}

private enum MapSelection: Hashable {
    case user
}

struct MapView: View {
    @StateObject private var loc = LocationManager()

    @State private var camera: MapCameraPosition = .automatic

    @State private var selectedMarker: MapSelection? = nil
    @State private var isSheetPresented = false

    @State private var selectedPlace: SelectedPlace? = nil
    @State private var goNext = false
    @State private var shouldNavigateAfterDismiss = false

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera, selection: $selectedMarker) {
                    if let coordinate = loc.coordinate {
                        Marker(
                            "You",
                            systemImage: "person.circle.fill",
                            coordinate: coordinate
                        )
                        .tint(.blue)
                        .tag(MapSelection.user)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .ignoresSafeArea()
                .onAppear {
                    loc.request()
                }
                .onReceive(loc.$coordinate.compactMap { $0 }) { coordinate in
                    withAnimation(.easeInOut) {
                        camera = .region(
                            .init(
                                center: coordinate,
                                latitudinalMeters: 800,
                                longitudinalMeters: 800
                            )
                        )
                    }
                }
                .onChange(of: selectedMarker) {
                    if selectedMarker == .user {
                        shouldNavigateAfterDismiss = false
                        isSheetPresented = true
                    }
                }

                NavigationLink(
                    destination: Group {
                        if let place = selectedPlace {
                            ContentView(name: place.name)
                        } else {
                            Text("No coordinate")
                                .onAppear {
                                    goNext = false
                                }
                        }
                    },
                    isActive: $goNext,
                    label: {
                        EmptyView()
                    }
                )
                .hidden()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(
            isPresented: $isSheetPresented,
            onDismiss: {
                selectedMarker = nil

                if shouldNavigateAfterDismiss, selectedPlace != nil {
                    shouldNavigateAfterDismiss = false
                    DispatchQueue.main.async {
                        goNext = true
                    }
                }
            }
        ) {
            if selectedMarker == .user, let coordinate = loc.coordinate {
                VStack(spacing: 12) {
                    Text("You")
                        .font(.headline)

                    Text(
                        String(
                            format: "%.8f, %.8f",
                            coordinate.latitude,
                            coordinate.longitude
                        )
                    )
                    .font(.caption)
                    .monospacedDigit()

                    Button {
                        selectedPlace = SelectedPlace(
                            name: "You",
                            coord: coordinate
                        )
                        shouldNavigateAfterDismiss = true
                        isSheetPresented = false
                    } label: {
                        Label {
                            Text("Open Current Location")
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .truncationMode(.tail)
                        } icon: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Close") {
                        shouldNavigateAfterDismiss = false
                        isSheetPresented = false
                    }
                    .padding(.top, 4)
                }
                .padding()
                .presentationDetents([.height(220), .medium])
            }
        }
    }
}
