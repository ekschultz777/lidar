//
//  ContentView.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var session = LiDARDistanceSession()
    @State private var isCapturing = false
    @State private var bannerMessage: String?

    var body: some View {
        ZStack {
            if session.supportsLiDAR {
                cameraStack

                VStack(spacing: 0) {
                    if let bannerMessage {
                        Text(bannerMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.top, 12)
                    }

                    Spacer()

                    HStack {
                        Spacer()
                        captureButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                    farSlider
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
            } else {
                unsupportedView
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            session.syncViewMetrics()
        }
    }

    private var cameraStack: some View {
        GeometryReader { geo in
            ZStack {
                ARViewContainer(session: session)
                if let overlay = session.overlayImage {
                    Image(uiImage: overlay)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { session.syncViewMetrics() }
            .onChange(of: geo.size) { _, _ in
                session.syncViewMetrics()
            }
        }
        .ignoresSafeArea()
    }

    private var captureButton: some View {
        Button {
            Task { await captureAndSave() }
        } label: {
            Group {
                if isCapturing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                }
            }
            .frame(width: 56, height: 56)
            .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(isCapturing || session.overlayImage == nil)
        .accessibilityLabel("Capture distance overlay")
    }

    private var farSlider: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Far")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
                Spacer()
                Text(DistanceFormatting.millimeters(session.maxRangeMeters))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
            }

            Slider(
                value: Binding(
                    get: { Double(session.maxRangeMeters) },
                    set: { session.maxRangeMeters = Float($0) }
                ),
                in: 0.2...5.0
            )
            .tint(.white)
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lidar.rangefinder.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("LiDAR Required")
                .font(.title2.bold())

            Text("This app needs an iPhone or iPad with a LiDAR scanner, such as iPhone 16 Pro.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }

    @MainActor
    private func captureAndSave() async {
        isCapturing = true
        defer { isCapturing = false }

        do {
            let pair = try await session.captureImages()
            try await PhotoLibrarySaver.save([pair.plain, pair.annotated])
            showBanner("Saved 2 photos (plain + numbers)")
        } catch {
            showBanner(error.localizedDescription)
        }
    }

    private func showBanner(_ message: String) {
        withAnimation(.snappy) { bannerMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation(.snappy) {
                    if bannerMessage == message {
                        bannerMessage = nil
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
