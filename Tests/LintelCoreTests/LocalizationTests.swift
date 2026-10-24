import Foundation
import Testing

/// Checks Resources/*.lproj, which the app loads from its bundle at run time.
struct LocalizationTests {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    func table(_ language: String, _ ext: String) throws -> [String: Any] {
        let url = Self.resources.appendingPathComponent("\(language).lproj/Localizable.\(ext)")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    func specifiers(_ format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(\\d\\$)?[0-9]*(@|lld)")
        return regex.matches(in: format, range: NSRange(format.startIndex..., in: format))
            .map { (format as NSString).substring(with: $0.range) }.sorted()
    }

    @Test(arguments: ["strings", "stringsdict"])
    func frenchHasTheEnglishKeys(ext: String) throws {
        #expect(Set(try table("en", ext).keys) == Set(try table("fr", ext).keys))
    }

    @Test func formatSpecifiersMatch() throws {
        let en = try table("en", "strings") as! [String: String]
        let fr = try table("fr", "strings") as! [String: String]
        for (key, value) in en {
            #expect(specifiers(value) == specifiers(fr[key] ?? ""), "\(key)")
        }
    }

    /// Every string value in a table, plural variants included.
    func values(_ entry: Any) -> [String] {
        switch entry {
        case let string as String: [string]
        case let dict as [String: Any]: dict.values.flatMap(values)
        default: []
        }
    }

    @Test(arguments: ["strings", "stringsdict"])
    func frenchUsesTypographicApostrophes(ext: String) throws {
        for value in values(try table("fr", ext)) {
            #expect(!value.contains("'"), "\(value)")
        }
    }

    @Test(arguments: ["en", "fr"])
    func pluralsHaveOneAndOther(language: String) throws {
        for (key, entry) in try table(language, "stringsdict") {
            let rule = (entry as? [String: Any])?["sessions"] as? [String: String]
            #expect(rule?["one"] != nil && rule?["other"] != nil, "\(key)")
        }
    }
}
