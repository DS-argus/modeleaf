import Foundation

/// Editable source values are retained independently of the effective keymap:
/// expanding <prefix> for validation must never destroy its source relationship.
public struct ShortcutSettingsDraft: Sendable {
    public private(set) var baseline: SparseAppConfig
    public private(set) var overrides: [String: [String]]
    public private(set) var prefix: String

    public init(source: SparseAppConfig) {
        baseline = source
        overrides = source.keymap ?? [:]
        prefix = source.input?.prefix ?? BuiltInDefaults.config.input.prefix
    }

    public var isDirty: Bool {
        overrides != (baseline.keymap ?? [:]) || prefix != baselinePrefix
    }

    public var baselinePrefix: String {
        baseline.input?.prefix ?? BuiltInDefaults.config.input.prefix
    }

    public var source: SparseAppConfig {
        SparseAppConfig(
            keymap: overrides,
            navigation: baseline.navigation,
            input: SparseInputConfiguration(
                prefixTimeoutMilliseconds: baseline.input?.prefixTimeoutMilliseconds,
                prefix: prefix
            ),
            links: baseline.links
        )
    }

    public var validation: ConfigValidationReport { ConfigValidator.validate(source) }

    public var hasValidPrefix: Bool {
        guard let token = try? KeySequenceParser.parseSingleToken(prefix) else { return false }
        return !token.isCompositionInput
    }

    public mutating func setPrefix(_ value: String) { prefix = value }

    public func aliases(for action: ActionID) -> [String] {
        let values = overrides[action.rawValue] ?? BuiltInDefaults.editableTemplatedKeymap[action, default: []]
        let fixed = Set(FoundationalBindings.sequences(for: action))
        return values.filter { value in
            guard let sequence = try? KeySequenceParser.parse(value.replacingOccurrences(of: "<prefix>", with: prefix)) else { return true }
            return !fixed.contains(sequence)
        }
    }

    public mutating func setAliases(_ values: [String], for action: ActionID) {
        guard ActionRegistry.v1.descriptor(for: action)?.isFixedBinding == false else { return }
        overrides[action.rawValue] = values
    }

    public mutating func reset(_ action: ActionID) {
        guard ActionRegistry.v1.descriptor(for: action)?.isFixedBinding == false else { return }
        overrides.removeValue(forKey: action.rawValue)
    }

    public mutating func discard() { self = Self(source: baseline) }

}
