import Foundation
import Network

/// A minimal HTTP/1.1 server (no dependencies) that answers every request with
/// the JSON payload produced by `provider`. Intended for local development use.
///
/// Main-actor isolated: the listener and every connection deliver their
/// callbacks on the main queue, which is what lets `handler` read UIKit.
@MainActor
final class AXExportServer {

    private let listener: NWListener
    private let handler: @MainActor (String) -> Data

    /// `handler` receives the request target (path + query, e.g. "/action?…")
    /// and returns the JSON response body.
    init(port: UInt16, handler: @escaping @MainActor (String) -> Data) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "AXExporter", code: 1)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        // Read (and ignore) the request line/headers, then respond.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.respond(to: data, on: connection)
            }
        }
    }

    private func respond(to data: Data?, on connection: NWConnection) {
        let target = Self.requestTarget(from: data)
        let body = handler(target)
        var response = Data("""
        HTTP/1.1 200 OK\r
        Content-Type: application/json; charset=utf-8\r
        Access-Control-Allow-Origin: *\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Extracts the request target (2nd token of the request line).
    private nonisolated static func requestTarget(from data: Data?) -> String {
        guard let data, let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\r\n").first else { return "/" }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }
}
