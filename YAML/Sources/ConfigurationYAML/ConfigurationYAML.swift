import Foundation
import Yams
import CYaml

/// A statically linked parser; the installed app needs no external interpreter.
public enum ConfigurationYAML {
    private static let configureParser: Void = { yaml_set_max_nest_level(40) }()

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        _ = configureParser
        // Keep JSONEncoder's round-trippable floating-point spellings. Yams'
        // default Double representer rounds to 15 significant digits.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        guard let root = try Parser(yaml: json).singleRoot() else { throw Failure("Cannot encode configuration.") }
        func block(_ node: Node) -> Node {
            switch node {
            case .mapping(let mapping):
                return .mapping(.init(mapping.map { (block($0.key), block($0.value)) }, .implicit, .block))
            case .sequence(let sequence):
                return .sequence(.init(sequence.map(block), .implicit, .block))
            case .scalar(var scalar):
                scalar.tag = node.tag
                scalar.style = .any
                return .scalar(scalar)
            case .alias: return node
            }
        }
        return try Yams.serialize(node: block(root))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard text.utf8.count <= 1_048_576 else { throw Failure("Configuration is larger than 1 MB.") }
        _ = configureParser
        // Configs are data only,
        // with a single document and unique keys; never execute YAML tags.
        let parser = try Parser(yaml: text)
        guard let root = try parser.singleRoot() else { throw Failure("Paste a YAML configuration first.") }
        var nodes = 0
        func check(_ node: Node, depth: Int) throws {
            nodes += 1
            guard depth < 40, nodes < 20_000 else { throw Failure("Configuration is too deeply nested or too large.") }
            guard node.anchor == nil else { throw Failure("YAML anchors and aliases are not supported in configurations.") }
            switch node {
            case .mapping(let mapping):
                var keys = Set<String>()
                for pair in mapping {
                    guard let key = pair.key.string, keys.insert(key).inserted else {
                        throw Failure("Duplicate or invalid YAML mapping key.")
                    }
                    try check(pair.value, depth: depth + 1)
                }
            case .sequence(let sequence):
                for child in sequence { try check(child, depth: depth + 1) }
            case .scalar: break
            case .alias: throw Failure("YAML aliases are not supported in configurations.")
            }
        }
        try check(root, depth: 0)
        return try YAMLDecoder().decode(type, from: root)
    }

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
}
