import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct BrowserBookmarkTests {
    static func main() throws {
        let chrome = """
        {
          "roots": {
            "bookmark_bar": {
              "type": "folder", "name": "Bookmarks bar", "children": [
                {"type": "url", "name": "OpenAI", "url": "https://openai.com/"},
                {"type": "folder", "name": "Work", "children": [
                  {"type": "url", "name": "Docs", "url": "https://example.com/docs"},
                  {"type": "url", "name": "Unsafe", "url": "javascript:alert(1)"}
                ]}
              ]
            },
            "other": {
              "type": "folder", "name": "Other bookmarks", "children": [
                {"type": "url", "name": "Duplicate", "url": "https://openai.com/"},
                {"type": "url", "name": "", "url": "http://example.org/path"}
              ]
            }
          }
        }
        """
        let chromeBookmarks = try BrowserBookmarkLoader.parseChrome(Data(chrome.utf8), profile: "Default")
        require(chromeBookmarks.count == 3, "Chrome should import safe web URLs and remove exact duplicates")
        require(chromeBookmarks[0].title == "OpenAI", "Chrome should retain bookmark titles")
        require(chromeBookmarks[0].profile == "Default", "Chrome should retain the profile name")
        require(chromeBookmarks[1].folder == "Bookmarks bar / Work", "Chrome should retain nested folders")
        require(chromeBookmarks[2].title == "example.org", "Chrome should fall back to the URL host")
        require(chromeBookmarks.allSatisfy { ["http", "https"].contains($0.url.scheme) },
            "Chrome should reject non-web schemes")

        let safariObject: [String: Any] = [
            "Title": "Bookmarks",
            "Children": [
                ["Title": "Favorites", "Children": [
                    ["URLString": "https://apple.com/", "URIDictionary": ["title": "Apple"]],
                    ["URLString": "file:///tmp/private", "URIDictionary": ["title": "Private file"]]
                ]],
                ["Title": "Reading", "Children": [
                    ["URLString": "https://example.net/article", "URIDictionary": ["title": "Article"]]
                ]]
            ]
        ]
        let safariData = try PropertyListSerialization.data(fromPropertyList: safariObject,
            format: .binary, options: 0)
        let safariBookmarks = try BrowserBookmarkLoader.parseSafari(safariData)
        require(safariBookmarks.count == 2, "Safari should import only safe web URLs")
        require(safariBookmarks[0].folder == "Favorites", "Safari should hide the synthetic root folder")
        require(safariBookmarks[1].folder == "Reading", "Safari should retain user folders")
        require(safariBookmarks.allSatisfy { $0.profile == nil }, "Safari bookmarks should not invent profiles")

        do {
            _ = try BrowserBookmarkLoader.parseChrome(Data("not json".utf8))
            require(false, "Invalid Chrome data should throw")
        } catch BrowserBookmarkImportError.invalid(.chrome) {
        } catch {
            require(false, "Invalid Chrome data should report the Chrome format")
        }

        do {
            _ = try BrowserBookmarkLoader.parseSafari(Data("not a plist".utf8))
            require(false, "Invalid Safari data should throw")
        } catch BrowserBookmarkImportError.invalid(.safari) {
        } catch {
            require(false, "Invalid Safari data should report the Safari format")
        }

        print("BrowserBookmarkTests passed")
    }
}
