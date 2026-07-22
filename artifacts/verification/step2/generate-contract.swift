import Foundation
import PDFReaderCore

func scopeObject(_ scope: ActionScope) -> [String: Any] {
    switch scope {
    case .global:
        return ["kind": "global", "contexts": InputContext.allCases.map(\.rawValue).sorted()]
    case let .contexts(contexts):
        return ["kind": "contexts", "contexts": contexts.map(\.rawValue).sorted()]
    }
}

func fallbackObject(_ fallback: PrefixFallbackPolicy) -> [String: Any] {
    switch fallback {
    case .none:
        return ["kind": "none"]
    case let .transitionAndReplay(context, tokenClass):
        return [
            "kind": "transition-and-replay",
            "context": context.rawValue,
            "acceptedToken": tokenClass.rawValue,
        ]
    }
}

let registry = ActionRegistry.v1
let bindingReport = ActionBindingPolicy.evaluateEffective(BuiltInDefaults.keymap)
precondition(bindingReport.isValid, "built-in keymap must satisfy the frozen binding policy")
precondition(ActionSurfaceRegistry.validate().isEmpty, "all action surfaces must be registry-backed")

let actions: [[String: Any]] = registry.descriptors.map { descriptor in
    [
        "id": descriptor.id.rawValue,
        "title": descriptor.title,
        "scope": scopeObject(descriptor.scope),
        "repeatPolicy": descriptor.repeatPolicy.rawValue,
        "prefixFallback": fallbackObject(descriptor.prefixFallbackPolicy),
        "isPromptLifecycle": descriptor.isPromptLifecycle,
        "defaultBindings": BuiltInDefaults.keymap[descriptor.id, default: []].map(\.description),
    ]
}

let menus: [[String: Any]] = MenuEquivalentPolicy.makeDescriptors(
    evaluatedBindings: bindingReport.evaluatedBindings
).map { descriptor in
    [
        "identifier": descriptor.identifier,
        "title": descriptor.title,
        "action": descriptor.actionID.rawValue,
        "placement": descriptor.placement.rawValue,
        "keyEquivalent": descriptor.keyEquivalent?.description ?? NSNull(),
    ]
}

let themes: [[String: Any]] = BuiltInThemes.all.map { theme in
    let palette = Dictionary(uniqueKeysWithValues: ThemeToken.allCases.map { token in
        (token.rawValue, theme.palette[token].rawValue)
    })
    return [
        "id": theme.id.rawValue,
        "displayName": theme.displayName,
        "palette": palette,
    ]
}

let surfaceCounts = Dictionary(uniqueKeysWithValues: ActionSurfaceKind.allCases.map { kind in
    (kind.rawValue, ActionSurfaceRegistry.v1.count { $0.kind == kind })
})

let root: [String: Any] = [
    "schemaVersion": 1,
    "actions": actions,
    "inputContexts": InputContext.allCases.map(\.rawValue),
    "reservations": [
        "promptNative": PromptNativeReservationV1.shared.normalizedEntries,
        "system": SystemKeyReservationV1.shared.normalizedEntries,
    ],
    "defaults": [
        "navigation": [
            "smallScrollPoints": BuiltInDefaults.config.navigation.smallScrollPoints,
            "largeScrollViewportFraction": BuiltInDefaults.config.navigation.largeScrollViewportFraction,
            "zoomFactor": BuiltInDefaults.config.navigation.zoomFactor,
        ],
        "input": [
            "prefixTimeoutMilliseconds": BuiltInDefaults.config.input.prefixTimeoutMilliseconds,
        ],
        "theme": BuiltInDefaults.config.theme.builtIn.rawValue,
        "bounds": [
            "smallScrollPoints": [ConfigBounds.smallScrollPoints.lowerBound, ConfigBounds.smallScrollPoints.upperBound],
            "largeScrollViewportFraction": [ConfigBounds.largeScrollViewportFraction.lowerBound, ConfigBounds.largeScrollViewportFraction.upperBound],
            "zoomFactor": [ConfigBounds.zoomFactor.lowerBound, ConfigBounds.zoomFactor.upperBound],
            "prefixTimeoutMilliseconds": [ConfigBounds.prefixTimeoutMilliseconds.lowerBound, ConfigBounds.prefixTimeoutMilliseconds.upperBound],
        ],
    ],
    "menus": menus,
    "themes": themes,
    "surfaces": [
        "count": ActionSurfaceRegistry.v1.count,
        "byKind": surfaceCounts,
    ],
]

let data = try JSONSerialization.data(
    withJSONObject: root,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
