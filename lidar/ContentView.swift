//
//  ContentView.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import SwiftUI

// This app exports the lidar distance from the camera. Each pixel in the lidar (TIFF) result is a 32 bit value in meters.
struct ContentView: View {
    @StateObject private var session = LiDARDistanceSession()
    @State private var isCapturing = false
    @State private var bannerMessage: String?
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

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

                    VStack(spacing: 10) {
                        rangeSlider(
                            title: "Near",
                            valueText: DistanceFormatting.millimeters(session.minRangeMeters),
                            value: Binding(
                                get: { Double(session.minRangeMeters) },
                                set: { session.setMinRange(Float($0)) }
                            ),
                            range: 0.05...4.9
                        )

                        rangeSlider(
                            title: "Far",
                            valueText: DistanceFormatting.millimeters(session.maxRangeMeters),
                            value: Binding(
                                get: { Double(session.maxRangeMeters) },
                                set: { session.setMaxRange(Float($0)) }
                            ),
                            range: 0.1...5.0
                        )
                    }
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
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
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
        .accessibilityLabel("Capture photo and depth TIFF")
    }

    private func rangeSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
            }

            Slider(value: value, in: range)
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
            let export = try await session.captureExport()
            try await PhotoLibrarySaver.save(export.photo)
            shareItems = [export.depthTIFFURL]
            showShareSheet = true
            showBanner("Photo saved · share/save the depth TIFF")
        } catch {
            showBanner(error.localizedDescription)
        }
    }

    private func showBanner(_ message: String) {
        withAnimation(.snappy) { bannerMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
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
