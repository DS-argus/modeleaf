import Foundation
import PDFReaderCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func token(_ source: String) -> KeyToken {
    do {
        return try KeySequenceParser.parseSingleToken(source)
    } catch {
        fatalError("invalid trace token \(source): \(error)")
    }
}

func sequence(_ source: String) -> KeySequence {
    do {
        return try KeySequenceParser.parse(source)
    } catch {
        fatalError("invalid trace sequence \(source): \(error)")
    }
}

func makeEngine(context: InputContext = .navigation) -> KeySequenceEngine {
    let bindingReport = ActionBindingPolicy.evaluateEffective(BuiltInDefaults.keymap)
    guard let keymap = bindingReport.validatedKeymap else {
        fatalError("built-in binding policy failed: \(bindingReport.diagnostics)")
    }
    let trieReport = KeySequenceTrie.build(from: keymap)
    guard let trie = trieReport.trie else {
        fatalError("built-in trie policy failed: \(trieReport.diagnostics)")
    }
    return KeySequenceEngine(
        trie: trie,
        context: context,
        prefixTimeoutMilliseconds: BuiltInDefaults.config.input.prefixTimeoutMilliseconds
    )
}

var trace: [[String: Any]] = []
var engine = makeEngine()

let gOutcome = engine.handle(token("g"))
guard case let .pending(gPending) = gOutcome else { fatalError("g was not pending") }
trace.append([
    "input": "g",
    "outcome": "pending",
    "epoch": gPending.epoch.rawValue,
    "exactAction": gPending.exactAction?.rawValue ?? NSNull(),
    "hasLongerMatches": gPending.hasLongerMatches,
    "timeoutMilliseconds": gPending.timeoutMilliseconds,
])

let firstDigit = token("1")
let replayOutcome = engine.handle(firstDigit)
guard case let .dispatch(replayDispatch) = replayOutcome,
      replayDispatch.actionID == .pagePrompt,
      replayDispatch.transitionedContext == .pagePrompt,
      let replay = replayDispatch.semanticReplay,
      replay.token == firstDigit,
      replay.tokenClass == .decimalDigit,
      replay.targetContext == .pagePrompt
else {
    fatalError("g1 did not produce the semantic page replay")
}
trace.append([
    "input": "1",
    "outcome": "dispatch-and-semantic-replay",
    "action": replayDispatch.actionID.rawValue,
    "transition": replay.targetContext.rawValue,
    "token": replay.token.description,
    "tokenClass": replay.tokenClass.rawValue,
])

var pageBuffer = PageNumberInputBuffer()
require(pageBuffer.append(replay), "first digit did not append")
let secondDigit = token("2")
require(engine.handle(secondDigit) == .native(secondDigit), "second page digit was not native")
require(pageBuffer.append(secondDigit), "second digit did not append")
require(pageBuffer.resolve(maximumPageCount: 300) == .success(12), "g12 did not resolve to page 12")
trace.append([
    "input": "2",
    "outcome": "native-page-digit",
    "buffer": pageBuffer.digits,
    "resolvedPage": 12,
])

let staleOutcome = engine.timeout(epoch: gPending.epoch)
require(staleOutcome == .ignored(.staleTimeout(gPending.epoch)), "stale g epoch dispatched")
trace.append([
    "input": "timeout:\(gPending.epoch.rawValue)",
    "outcome": "ignored-stale-timeout",
])

for (source, expectedAction) in [
    ("gg", ActionID.pageFirst),
    ("gt", .tabNext),
    ("gT", .tabPrevious),
] {
    var sequenceEngine = makeEngine()
    let characters = source.map(String.init)
    guard case .pending = sequenceEngine.handle(token(characters[0])) else {
        fatalError("\(source) did not enter pending state")
    }
    guard case let .dispatch(dispatch) = sequenceEngine.handle(token(characters[1])),
          dispatch.actionID == expectedAction,
          dispatch.semanticReplay == nil
    else {
        fatalError("\(source) did not dispatch \(expectedAction.rawValue)")
    }
    trace.append([
        "input": source,
        "outcome": "dispatch",
        "action": expectedAction.rawValue,
    ])
}

var repeatEngine = makeEngine()
require(
    repeatEngine.handle(token("j"), eventIsRepeat: true)
        == .dispatch(KeyActionDispatch(actionID: .scrollDown)),
    "repeatable scroll was suppressed"
)
require(
    repeatEngine.handle(token("G"), eventIsRepeat: true)
        == .ignored(.repeatSuppressed(.pageLast)),
    "non-repeatable page-last action repeated"
)
trace.append([
    "input": "repeat:j / repeat:G",
    "outcome": "scroll-dispatched-page-last-suppressed",
])

var promptEngine = makeEngine(context: .searchPrompt)
let literal = token("j")
require(promptEngine.handle(literal) == .native(literal), "search literal left the native path")
require(
    promptEngine.handle(token("<D-o>"))
        == .dispatch(KeyActionDispatch(actionID: .documentOpen)),
    "prompt-safe global did not dispatch"
)
trace.append([
    "input": "searchPrompt:j / searchPrompt:<D-o>",
    "outcome": "literal-native-global-dispatched",
])

var countEngine = makeEngine()
require(countEngine.handle(token("1")) == .ignored(.noBinding), "implicit count grammar was enabled")
trace.append([
    "input": "1",
    "outcome": "ignored-no-count-grammar",
])

var invalidPrefixBindings = BuiltInDefaults.keymap
invalidPrefixBindings[.pageLast] = [sequence("q")]
invalidPrefixBindings[.pageFirst] = [sequence("qq")]
let invalidBindingReport = ActionBindingPolicy.evaluateEffective(invalidPrefixBindings)
guard let invalidPrefixKeymap = invalidBindingReport.validatedKeymap else {
    fatalError("exact-prefix fixture failed exact-binding validation")
}
let invalidPrefixReport = KeySequenceTrie.build(from: invalidPrefixKeymap)
require(!invalidPrefixReport.isValid, "unsafe exact-prefix fixture was accepted")
require(invalidPrefixReport.diagnostics.count == 1, "unexpected exact-prefix diagnostic count")

let output: [String: Any] = [
    "status": "passed",
    "trace": trace,
    "checks": [
        "g12ResolvedPage": 12,
        "staleEpochBlocked": true,
        "defaultLongerSequences": ["gg", "gt", "gT"],
        "repeatPolicyApplied": true,
        "promptNativePrecedence": true,
        "implicitCountGrammar": false,
        "unsafeExactPrefixRejected": true,
    ],
]

let data = try JSONSerialization.data(
    withJSONObject: output,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
