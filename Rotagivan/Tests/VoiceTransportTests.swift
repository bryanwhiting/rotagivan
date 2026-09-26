import Foundation

/// All URLs are intercepted, including unexpected hosts; no socket is opened.
private final class VoiceFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var held: VoiceFixtureProtocol?
    private static var stops = 0
    private static var holdNumber: Int?
    static func reset(hold: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        requests = []; held = nil; stops = 0; holdNumber = hold
    }
    static func snapshot() -> ([URLRequest], Int) {
        lock.lock(); defer { lock.unlock() }; return (requests, stops)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "openrouter.ai", "Unexpected destination intercepted")
        let payload: [String: Any]
        do { payload = try Self.payload(request) }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        var recorded = request
        recorded.httpBody = try! JSONSerialization.data(withJSONObject: payload)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-fixture-not-a-credential")
        precondition(request.httpMethod == "POST")
        Self.lock.lock()
        Self.requests.append(recorded)
        let hold = Self.requests.count == Self.holdNumber
        if hold { Self.held = self }
        Self.lock.unlock()
        if hold { return }
        do {
            let body: Data
            if request.url!.path.hasSuffix("transcriptions") {
                precondition(payload["model"] as? String == "x-ai/grok-stt-1.0")
                let audio = payload["input_audio"] as! [String: Any]
                precondition(audio["format"] as? String == "wav")
                precondition(Data(base64Encoded: audio["data"] as! String) != nil)
                precondition(payload["response_format"] as? String == "json")
                body = Data(#"{"text":"fixture command"}"#.utf8)
            } else {
                let questions = payload["questions"] as! [String: Any]
                let question = questions["action"] as! [String: Any]
                let criteria = question["criteria"] as! [String: Any]
                precondition(payload["model"] as? String == "typesafe/jev-1.13")
                precondition(criteria.count <= 255 && criteria["none"] != nil)
                let winner = criteria.keys.filter { $0 != "none" }.sorted().first!
                let probabilities = Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, $0 == winner ? 1.0 : 0.0) })
                body = try JSONSerialization.data(withJSONObject: ["answers": ["action": ["type": "choice", "choice": winner,
                    "confidence": 1.0, "probabilities": probabilities]]])
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        Self.lock.lock(); Self.stops += 1
        if Self.held === self { Self.held = nil }
        Self.lock.unlock()
    }
    static func payload(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; collected.append(contentsOf: buffer.prefix(count))
            }
            data = collected
        } else { preconditionFailure("Missing request body") }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private func transportEventually(_ condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    preconditionFailure("Offline transport fixture did not reach expected state")
}

@main struct VoiceTransportTests {
    static func cloud() -> OpenRouterVoiceCloud {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceFixtureProtocol.self]
        return OpenRouterVoiceCloud(key: "offline-fixture-not-a-credential", configuration: configuration)
    }
    static func main() async throws {
        VoiceFixtureProtocol.reset(hold: 1)
        let client = cloud()
        let first = Task { try await client.transcribe(Data([1, 2])) }
        await transportEventually { VoiceFixtureProtocol.snapshot().0.count == 1 }
        do { _ = try await client.transcribe(Data([9])); preconditionFailure("Overlapping transport admitted") }
        catch { precondition((error as? VoiceError)?.errorDescription?.contains("still stopping") == true) }
        precondition(VoiceFixtureProtocol.snapshot().0.count == 1)
        client.cancelRequests()
        do { _ = try await first.value; preconditionFailure("Cancelled request succeeded") } catch {}
        precondition(VoiceFixtureProtocol.snapshot().1 >= 1,
            "Admitted call completion must follow URLProtocol cancellation acknowledgement")
        let finalText = try await client.transcribe(Data([3, 4]))
        precondition(finalText == "fixture command", "Cancel must preserve session for final upload")
        let countBeforeClose = VoiceFixtureProtocol.snapshot().0.count
        client.close()
        do { _ = try await client.transcribe(Data()); preconditionFailure("Closed client accepted work") } catch {}
        precondition(VoiceFixtureProtocol.snapshot().0.count == countBeforeClose)

        let catalog = (0..<300).map { index in
            VoiceRegisteredAction(action: .openApp(bundleID: "fixture.app.\(index)", name: "Fixture \(index)"), detail: "Offline fixture")
        }
        VoiceFixtureProtocol.reset()
        let batches = cloud()
        let result = try await batches.classify("fixture", catalog: catalog)
        precondition(result.shortlisted)
        let requests = VoiceFixtureProtocol.snapshot().0
        precondition(requests.count == 3, "Two batches plus one finalists decision expected")
        var seen = Set<String>()
        for request in requests.prefix(2) {
            let payload = try VoiceFixtureProtocol.payload(request)
            let question = (payload["questions"] as! [String: Any])["action"] as! [String: Any]
            let criteria = question["criteria"] as! [String: Any]
            seen.formUnion(criteria.keys.filter { $0 != "none" })
        }
        precondition(seen == Set(catalog.map(\.id)), "Every registered ID must participate")
        batches.close()

        VoiceFixtureProtocol.reset(hold: 2)
        let cancelledBatches = cloud()
        let classification = Task { try await cancelledBatches.classify("fixture", catalog: catalog) }
        await transportEventually { VoiceFixtureProtocol.snapshot().0.count == 2 }
        let stopsBeforeCancellation = VoiceFixtureProtocol.snapshot().1
        classification.cancel()
        do { _ = try await classification.value; preconditionFailure("Cancelled batches succeeded") } catch {}
        precondition(VoiceFixtureProtocol.snapshot().1 > stopsBeforeCancellation,
            "Held second batch must acknowledge cancellation, not merely a prior completed request")
        precondition(VoiceFixtureProtocol.snapshot().0.count == 2, "Cancellation must suppress finalists request")
        cancelledBatches.close()
        print("Offline actual URLSession cancellation/drain, reuse, close, and Jev batching: PASS")
    }
}
