//
//  CaptureHTTPServer.swift
//  lidar
//

import Foundation
import Network
import UIKit

/// Bonjour-advertised HTTP server. `GET /capture` triggers a LiDAR capture and
/// returns a ZIP (JPEG + depth TIFF) while also saving to the camera roll.
@MainActor
final class CaptureHTTPServer: ObservableObject {
    static let port: NWEndpoint.Port = 8080
    static let bonjourType = "_http._tcp"

    @Published private(set) var isListening = false
    @Published private(set) var statusText = "Server starting…"

    private var listener: NWListener?
    private weak var session: LiDARDistanceSession?
    private var connections: [ObjectIdentifier: ConnectionHandler] = [:]

    var curlExample: String {
        let host = Self.localHostname
        return "curl http://\(host):\(Self.port.rawValue)/capture -o capture.zip"
    }

    /// mDNS hostname derived from the device name (spaces → hyphens).
    static var localHostname: String {
        let raw = UIDevice.current.name
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: " ", with: "-")
        return "\(raw).local"
    }

    func start(session: LiDARDistanceSession) {
        self.session = session
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: Self.port)
            listener.service = NWListener.Service(
                name: UIDevice.current.name,
                type: Self.bonjourType
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            statusText = curlExample
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            statusText = "Server failed: \(error.localizedDescription)"
            isListening = false
        }
    }

    func stop() {
        for handler in connections.values {
            handler.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isListening = false
        statusText = "Server stopped"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            statusText = curlExample
        case .failed(let error):
            isListening = false
            statusText = "Server failed: \(error.localizedDescription)"
        case .cancelled:
            isListening = false
            statusText = "Server stopped"
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let handler = ConnectionHandler(connection: connection) { [weak self] handler in
            self?.connections.removeValue(forKey: ObjectIdentifier(handler))
        } onCapture: { [weak self] in
            guard let self, let session = self.session else {
                throw CaptureError.noSession
            }
            return try await session.capturePersistAndZip()
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    enum CaptureError: LocalizedError, Equatable {
        case noSession
        case busy

        var errorDescription: String? {
            switch self {
            case .noSession:
                return "Capture session unavailable."
            case .busy:
                return "A capture is already in progress."
            }
        }
    }
}

// MARK: - Per-connection HTTP handler

@MainActor
private final class ConnectionHandler {
    private let connection: NWConnection
    private let onFinished: (ConnectionHandler) -> Void
    private let onCapture: () async throws -> CaptureZipResult
    private var buffer = Data()
    private var didRespond = false

    init(
        connection: NWConnection,
        onFinished: @escaping (ConnectionHandler) -> Void,
        onCapture: @escaping () async throws -> CaptureZipResult
    ) {
        self.connection = connection
        self.onFinished = onFinished
        self.onCapture = onCapture
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receiveMore()
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.didRespond else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    if let request = HTTPRequest.parse(from: self.buffer) {
                        await self.handle(request)
                        return
                    }
                }
                if error != nil || isComplete {
                    self.finish()
                    return
                }
                self.receiveMore()
            }
        }
    }

    private func handle(_ request: HTTPRequest) async {
        guard !didRespond else { return }

        if request.method == "GET", request.path == "/capture" {
            do {
                let result = try await onCapture()
                respond(
                    status: 200,
                    reason: "OK",
                    headers: [
                        "Content-Type": "application/zip",
                        "Content-Disposition": "attachment; filename=\"\(result.zipFilename)\"",
                        "Content-Length": "\(result.zipData.count)",
                    ],
                    body: result.zipData
                )
            } catch {
                let message = error.localizedDescription + "\n"
                let body = Data(message.utf8)
                let isBusy = (error as? LiDARDistanceSession.CaptureError) == .busy
                    || (error as? CaptureHTTPServer.CaptureError) == .busy
                let code = isBusy ? 503 : 500
                respond(
                    status: code,
                    reason: isBusy ? "Busy" : "Error",
                    headers: [
                        "Content-Type": "text/plain; charset=utf-8",
                        "Content-Length": "\(body.count)",
                    ],
                    body: body
                )
            }
            return
        }

        if request.method == "GET", request.path == "/" || request.path == "/health" {
            let body = Data("ok\n".utf8)
            respond(
                status: 200,
                reason: "OK",
                headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Length": "\(body.count)",
                ],
                body: body
            )
            return
        }

        let body = Data("Not Found\n".utf8)
        respond(
            status: 404,
            reason: "Not Found",
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
            ],
            body: body
        )
    }

    private func respond(status: Int, reason: String, headers: [String: String], body: Data) {
        didRespond = true
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Connection: close\r\n"
        for (key, value) in headers {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.connection.cancel()
                self?.finish()
            }
        })
    }

    private func finish() {
        onFinished(self)
    }
}

// MARK: - Minimal HTTP request parse

private struct HTTPRequest {
    let method: String
    let path: String

    static func parse(from data: Data) -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? Substring(target))
        return HTTPRequest(method: method, path: path)
    }
}

struct CaptureZipResult {
    let zipData: Data
    let zipFilename: String
}
