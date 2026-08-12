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
    @StateObject private var levelMonitor = UprightLevelMonitor()
    @StateObject private var httpServer = CaptureHTTPServer()
    @State private var isCapturing = false
    @State private var bannerMessage: String?

    var body: some View {
        ZStack {
            if session.supportsLiDAR {
                cameraStack

                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        if let bannerMessage {
                            Text(bannerMessage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.55), in: Capsule())
                        }

                        Spacer(minLength: 0)

                        uprightIndicator
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

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

                        Text(httpServer.statusText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
            } else {
                unsupportedView
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            session.start()
            levelMonitor.start()
            if session.supportsLiDAR {
                httpServer.start(session: session)
            }
        }
        .onDisappear {
            httpServer.stop()
            session.stop()
            levelMonitor.stop()
        }
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
        .accessibilityLabel("Capture photo and depth TIFF")
    }

    private var uprightIndicator: some View {
        let isGreen = levelMonitor.isUpright
        let ringColor = isGreen ? Color.green : Color.white.opacity(0.85)
        let fillColor = isGreen ? Color.green : Color.orange
        let size: CGFloat = 54
        let bubbleTravel = size * 0.28

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .strokeBorder(ringColor, lineWidth: isGreen ? 3 : 2)
                    .frame(width: size, height: size)

                // Crosshairs for a repeatable level target.
                Rectangle()
                    .fill(ringColor.opacity(0.55))
                    .frame(width: size - 12, height: 1)
                Rectangle()
                    .fill(ringColor.opacity(0.55))
                    .frame(width: 1, height: size - 12)

                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 10, height: 10)

                Circle()
                    .fill(fillColor)
                    .frame(width: 12, height: 12)
                    .offset(
                        x: levelMonitor.bubbleOffset.x * bubbleTravel,
                        y: levelMonitor.bubbleOffset.y * bubbleTravel
                    )
                    .shadow(color: fillColor.opacity(0.7), radius: isGreen ? 4 : 0)
            }
            .animation(.easeOut(duration: 0.08), value: levelMonitor.bubbleOffset)
            .animation(.easeOut(duration: 0.12), value: isGreen)

            Text(isGreen ? "Level" : String(format: "%.2f°", levelMonitor.tiltDegrees))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(isGreen ? .green : .white)
                .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
        }
        .accessibilityLabel(
            isGreen
                ? "Phone is perfectly upright"
                : String(format: "Phone tilt %.2f degrees", levelMonitor.tiltDegrees)
        )
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
            _ = try await session.captureAndPersist()
            showBanner("Saved to camera roll")
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
