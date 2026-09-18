import AppKit
import ImageIO

private actor Fixture {
    var requests: [URL] = []
    let responses: [URL: Data]
    init(_ responses: [URL: Data]) { self.responses = responses }
    func fetch(_ url: URL, _ limit: Int) async -> FaviconResponse? {
        requests.append(url)
        try? await Task.sleep(for: .milliseconds(10))
        guard let data = responses[url], data.count <= limit else { return nil }
        return FaviconResponse(data: data, url: url)
    }
}

@main struct FaviconTests {
    static func main() async {
        let origin = URL(string: "https://example.com/")!
        let privateURL = URL(string: "https://example.com:443/private?token=secret#fragment")!
        precondition(FaviconDiscovery.origin(for: privateURL) == origin)
        precondition(FaviconDiscovery.origin(for: URL(string: "file:///tmp/icon.png")!) == nil)
        precondition(FaviconDiscovery.origin(for: URL(string: "https://user:pass@example.com/")!) == nil)
        let html = Data("""
            <link href='/icon.png?a=1&amp;b=2' REL='shortcut ICON'>
            <link rel=apple-touch-icon href="//cdn.example.com/apple.png">
            <link rel=icon href='http://example.com/insecure.png'>
            <link rel=icon href='data:image/png;base64,invalid'>
            <link rel=icon href='javascript:alert(1)'>
            <link rel=icon href='/icon.svg'>
            <link rel=icon href='/icon.png?a=1&amp;b=2'>
            <link rel=stylesheet href='/style.css'>
            """.utf8)
        let candidates = FaviconDiscovery.candidates(html: html, pageURL: origin)
        precondition(candidates.map(\.absoluteString) == ["https://example.com/icon.png?a=1&b=2", "https://cdn.example.com/apple.png"])
        precondition(FaviconDiscovery.candidates(html: Data(repeating: 65, count: FaviconDiscovery.maximumHTMLBytes + 1), pageURL: origin).isEmpty)
        let many = (0..<10).map { "<link rel=icon href='/\($0).png'>" }.joined()
        precondition(FaviconDiscovery.candidates(html: Data(many.utf8), pageURL: origin).count == 4)

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let color = NSColor(deviceRed: 0.1, green: 0.7, blue: 0.7, alpha: 1)
        for y in 0..<128 { for x in 0..<128 { bitmap.setColor(color, atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let thumbnail = FaviconDiscovery.thumbnail(png)!
        let decoded = NSBitmapImageRep(data: thumbnail)!
        precondition(decoded.pixelsWide == 64 && decoded.pixelsHigh == 64)
        precondition(FaviconDiscovery.thumbnail(Data("not an image".utf8)) == nil)
        precondition(FaviconDiscovery.thumbnail(Data(repeating: 0, count: FaviconDiscovery.maximumImageBytes + 1)) == nil)

        let fixture = Fixture([origin: html, candidates[0]: png])
        let service = FaviconService(fetch: { await fixture.fetch($0, $1) })
        async let first = service.icon(for: privateURL)
        async let second = service.icon(for: origin.appendingPathComponent("another-private-page"))
        let pair = await (first, second)
        precondition(pair.0 == thumbnail && pair.1 == thumbnail)
        let cached = await service.icon(for: origin)
        precondition(cached == thumbnail)
        let requests = await fixture.requests
        precondition(requests == [origin, candidates[0]], "Concurrent requests should coalesce and cache by origin, without private paths")

        let fallbackURL = origin.appendingPathComponent("favicon.ico")
        let fallback = Fixture([fallbackURL: png])
        let fallbackService = FaviconService(fetch: { await fallback.fetch($0, $1) })
        let fallbackIcon = await fallbackService.icon(for: privateURL)
        precondition(fallbackIcon == thumbnail)
        let fallbackRequests = await fallback.requests
        precondition(fallbackRequests == [origin, fallbackURL])

        let missing = Fixture([:])
        let missingService = FaviconService(fetch: { await missing.fetch($0, $1) })
        let missingFirst = await missingService.icon(for: origin)
        let missingSecond = await missingService.icon(for: privateURL)
        precondition(missingFirst == nil && missingSecond == nil)
        let missingRequests = await missing.requests
        precondition(missingRequests.count == 3, "Missing icons should also be cached")
        print("Favicon discovery, image bounds, privacy, fallback, cache and concurrent-request tests passed.")
    }
}
