import Foundation

public struct ProbeCheck: Codable, Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public let detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct ProbeSection: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let checks: [ProbeCheck]

    public var passed: Bool { checks.allSatisfy(\.passed) }

    public init(id: String, title: String, checks: [ProbeCheck]) {
        self.id = id
        self.title = title
        self.checks = checks
    }
}

public struct Step0Report: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let platform: String
    public let sections: [ProbeSection]

    public var passed: Bool { sections.allSatisfy(\.passed) }

    public init(generatedAt: Date = Date(), platform: String, sections: [ProbeSection]) {
        self.generatedAt = generatedAt
        self.platform = platform
        self.sections = sections
    }
}

public enum ProbeFailure: Error, CustomStringConvertible {
    case failed([ProbeSection])
    case invariant(String)

    public var description: String {
        switch self {
        case let .failed(sections):
            let failures = sections.flatMap { section in
                section.checks.filter { !$0.passed }.map { "\(section.id).\($0.name): \($0.detail)" }
            }
            return failures.joined(separator: "\n")
        case let .invariant(message):
            return message
        }
    }
}

public func checked(_ name: String, _ condition: @autoclosure () -> Bool, detail: String) -> ProbeCheck {
    ProbeCheck(name: name, passed: condition(), detail: detail)
}
