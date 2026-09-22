import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct FaviconResponse: Sendable {
    let data: Data
    let url: URL
}

enum FaviconDiscovery {
    static let maximumHTMLBytes = 512 * 1024
    static let maximumImageBytes = 1024 * 1024

    static func origin(for url: URL) -> URL? {
        guard AppExplorerFavorite.webURL(url.absoluteString) != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.url
    }

    static func candidates(html: Data, pageURL: URL) -> [URL] {
        guard html.count <= maximumHTMLBytes,
              let text = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1),
              let tags = try? NSRegularExpression(pattern: "<link\\b[^>]{0,8192}>", options: .caseInsensitive) else { return [] }
        let source = text as NSString
        var result: [URL] = []
        var seen = Set<String>()
        for match in tags.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let attributes = attributes(in: source.substring(with: match.range))
            let rel = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  let href = attributes["href"], let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  AppExplorerFavorite.webURL(url.absoluteString) != nil,
                  pageURL.scheme != "https" || url.scheme == "https",
                  url.pathExtension.lowercased() != "svg",
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
            if result.count == 4 { break }
        }
        return result
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([a-zA-Z][a-zA-Z0-9:_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let source = tag as NSString
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: NSRange(location: 0, length: source.length)) {
            let key = source.substring(with: match.range(at: 1)).lowercased()
            if let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                result[key] = source.substring(with: range).replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            }
        }
        return result
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private final class FaviconRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let redirects = Int(task.taskDescription ?? "0") ?? 0
        guard redirects < 5, let url = request.url, AppExplorerFavorite.webURL(url.absoluteString) != nil,
              response.url?.scheme != "https" || url.scheme == "https" else { completionHandler(nil); return }
        task.taskDescription = String(redirects + 1)
        var clean = request
        clean.httpShouldHandleCookies = false
        for field in ["Cookie", "Authorization", "Referer"] { clean.setValue(nil, forHTTPHeaderField: field) }
        completionHandler(clean)
    }
}

enum FaviconNetwork {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: FaviconRedirectPolicy(), delegateQueue: nil)
    }()

    static func fetch(_ url: URL, limit: Int) async -> FaviconResponse? {
        guard AppExplorerFavorite.webURL(url.absoluteString) != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Rotagivan-Favicon/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  response.expectedContentLength <= limit, let finalURL = response.url,
                  AppExplorerFavorite.webURL(finalURL.absoluteString) != nil else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            return FaviconResponse(data: data, url: finalURL)
        } catch { return nil }
    }
}

actor FaviconService {
    typealias Fetch = @Sendable (URL, Int) async -> FaviconResponse?
    static let shared = FaviconService()
    private struct Entry { let data: Data?; let expires: Date }
    private var cache: [URL: Entry] = [:]
    private var pending: [URL: Task<Data?, Never>] = [:]
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { await FaviconNetwork.fetch($0, limit: $1) }) { self.fetch = fetch }

    func icon(for url: URL) async -> Data? {
        guard let origin = FaviconDiscovery.origin(for: url) else { return nil }
        if let cached = cache[origin], cached.expires > Date() { return cached.data }
        if let task = pending[origin] { return await task.value }
        let fetch = self.fetch
        let task = Task { await Self.load(origin: origin, fetch: fetch) }
        pending[origin] = task
        let data = await task.value
        pending[origin] = nil
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache[oldest] = nil }
        cache[origin] = Entry(data: data, expires: Date().addingTimeInterval(data == nil ? 900 : 86400))
        return data
    }

    private static func load(origin: URL, fetch: Fetch) async -> Data? {
        var candidates: [URL] = []
        if let page = await fetch(origin, FaviconDiscovery.maximumHTMLBytes) {
            candidates = FaviconDiscovery.candidates(html: page.data, pageURL: page.url)
        }
        candidates += [origin.appendingPathComponent("favicon.ico"), origin.appendingPathComponent("apple-touch-icon.png")]
        var attempted = Set<URL>()
        for url in candidates where attempted.insert(url).inserted {
            if let response = await fetch(url, FaviconDiscovery.maximumImageBytes),
               let data = FaviconDiscovery.thumbnail(response.data) { return data }
        }
        return nil
    }
}

struct WebsiteFavicon: View {
    let url: URL?
    let size: CGFloat
    var symbolName: String? = nil
    var service: FaviconService = .shared
    @State private var icon: NSImage?

    private var taskID: String {
        (symbolName ?? "automatic") + "|" + (url.flatMap(FaviconDiscovery.origin)?.absoluteString ?? "")
    }

    var body: some View {
        Group {
            if let symbolName {
                Image(systemName: symbolName).resizable().scaledToFit().foregroundStyle(.teal)
            } else if let icon {
                Image(nsImage: icon).resizable().renderingMode(.original).scaledToFit()
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.teal)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: taskID) {
                icon = nil
                guard symbolName == nil, let url else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                let data = await service.icon(for: url)
                guard !Task.isCancelled else { return }
                icon = data.flatMap(NSImage.init(data:))
            }
    }
}
