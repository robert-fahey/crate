import Foundation

/// An error whose message is meant for the agent to read and act on.
public struct ToolError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One capability the agent can call. All of them are implemented in the app;
/// the sidecar only forwards calls.
public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments.
    public let inputSchema: JSON
    /// True when the tool changes nothing. Advertised to the agent as a hint.
    public let readOnly: Bool
    public let handler: @Sendable (JSON) async throws -> JSON

    public init(
        name: String, description: String, properties: [String: JSON] = [:], required: [String] = [],
        readOnly: Bool = false, handler: @escaping @Sendable (JSON) async throws -> JSON
    ) {
        self.name = name
        self.description = description
        self.inputSchema = [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSON.string)),
            "additionalProperties": false,
        ]
        self.readOnly = readOnly
        self.handler = handler
    }
}

public final class ToolRegistry: @unchecked Sendable {
    private var tools: [AgentTool] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ tool: AgentTool) {
        lock.lock()
        defer { lock.unlock() }
        tools.removeAll { $0.name == tool.name }
        tools.append(tool)
    }

    public var all: [AgentTool] {
        lock.lock()
        defer { lock.unlock() }
        return tools
    }

    /// The catalogue sent to the sidecar at session start.
    public func specs() -> JSON {
        .array(all.map {
            ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema,
             "readOnly": .bool($0.readOnly)]
        })
    }

    /// Runs a tool. Never throws: a failure comes back as `ok == false` with a message for the agent.
    public func call(name: String, args: JSON) async -> (ok: Bool, content: JSON) {
        guard let tool = all.first(where: { $0.name == name }) else {
            return (false, .string("There is no tool called \(name)."))
        }
        do {
            return (true, try await tool.handler(args))
        } catch {
            return (false, .string(error.localizedDescription))
        }
    }
}

// MARK: - Argument helpers

public extension JSON {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("Missing required text argument \"\(key)\".")
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = self[key], !value.isNull else { return nil }
        guard let number = value.doubleValue else { throw ToolError("\"\(key)\" must be a number.") }
        return number
    }

    func optionalInt(_ key: String) throws -> Int? {
        try optionalDouble(key).map { Int($0) }
    }
}

public enum Schema {
    public static func string(_ description: String) -> JSON { ["type": "string", "description": .string(description)] }
    public static func number(_ description: String) -> JSON { ["type": "number", "description": .string(description)] }
    public static func integer(_ description: String) -> JSON { ["type": "integer", "description": .string(description)] }
    public static func boolean(_ description: String) -> JSON { ["type": "boolean", "description": .string(description)] }
    public static func choice(_ description: String, _ values: [String]) -> JSON {
        ["type": "string", "description": .string(description), "enum": .array(values.map(JSON.string))]
    }
    /// Track references: library ids, or URIs from a service search.
    public static func trackRefs(_ description: String) -> JSON {
        [
            "type": "array",
            "description": .string(description + " Each item is a library track id (number) or a URI from a search result (text)."),
            "items": ["type": ["integer", "string"]],
        ]
    }
}
