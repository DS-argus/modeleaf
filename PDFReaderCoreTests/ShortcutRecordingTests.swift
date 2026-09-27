import PDFReaderCore
import Testing

@Suite("Shortcut recording")
struct ShortcutRecordingTests {
    private let escape = KeyToken(symbol: .named(.escape))
    private let enter = KeyToken(symbol: .named(.carriageReturn))
    private let prefix = KeyToken(symbol: .character("b"), modifiers: .control)

    @Test("Direct singles, chords, unequal pairs, Tab, and modified Enter finish on Enter", arguments: [
        "j", "<D-j>", "yy", "of", "<Tab>", "<S-Tab>", "<D-Enter>", "<C-Esc>"
    ])
    func direct(_ source: String) throws {
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        for token in try KeySequenceParser.parse(source).tokens {
            #expect(buffer.receive(token, physicalModifiers: token.modifiers) == .recorded)
        }
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed(source))
    }

    @Test("A physically shifted U is valid as a direct single")
    func physicalShiftUSingle() {
        let shiftedU = KeyToken(symbol: .character("u"), modifiers: [.shift])
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        #expect(buffer.receive(shiftedU, physicalModifiers: [.shift]) == .recorded)
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed("U"))
    }

    @Test("Escape cancels a non-empty action recording without committing it")
    func nonEmptyEscapeCancels() throws {
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        #expect(buffer.receive(KeyToken(symbol: .character("x")), physicalModifiers: []) == .recorded)
        #expect(buffer.receive(escape, physicalModifiers: []) == .cancelled)
        #expect(buffer.tokens.map(\.description) == ["x"])
    }

    @Test("Recorded shared prefix is saved symbolically when finished on Enter", arguments: ["r", "Y", "|", "<Tab>", "<Right>"])
    func detectPrefix(_ follower: String) throws {
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        #expect(buffer.receive(prefix, physicalModifiers: prefix.modifiers) == .recorded)
        let followerToken = try KeySequenceParser.parseSingleToken(follower)
        #expect(buffer.receive(followerToken, physicalModifiers: followerToken.modifiers) == .recorded)
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed("<prefix>" + follower))
    }

    @Test("Empty Enter unbinds an action but preserves a blank common prefix")
    func emptyEnter() {
        var action = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        #expect(action.receive(enter, physicalModifiers: []) == .completed(""))
        var common = ShortcutRecordingBuffer(target: .prefix)
        #expect(common.receive(enter, physicalModifiers: []) == .cancelled)
    }

    @Test("Common prefix records one chord and blank Enter cancels it")
    func commonPrefix() {
        var buffer = ShortcutRecordingBuffer(target: .prefix)
        #expect(buffer.receive(prefix, physicalModifiers: prefix.modifiers) == .recorded)
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed("<C-b>"))

        var blank = ShortcutRecordingBuffer(target: .prefix)
        #expect(blank.receive(enter, physicalModifiers: []) == .cancelled)
    }

    @Test("Prefix alone is invalid, while a modified follower is accepted")
    func invalidPrefix() throws {
        var alone = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        #expect(alone.receive(prefix, physicalModifiers: [.control]) == .recorded)
        guard case .invalid = alone.receive(enter, physicalModifiers: []) else {
            Issue.record("Prefix alone must not become a direct binding")
            return
        }

        var modified = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        let follower = try KeySequenceParser.parseSingleToken("<D-S-j>")
        #expect(modified.receive(prefix, physicalModifiers: [.control]) == .recorded)
        #expect(modified.receive(follower, physicalModifiers: [.command, .shift]) == .recorded)
        #expect(modified.receive(enter, physicalModifiers: []) == .completed("<prefix><D-S-j>"))
        #expect(try KeySequenceParser.parseSingleToken("<D-S-j>") == follower)
    }

    @Test("Invalid input stays old and Enter reports invalid instead of truncating", arguments: ["abc", "a<D-b>", "<D-a>b"])
    func invalidDirect(_ source: String) throws {
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        let tokens = try KeySequenceParser.parse(source).tokens
        var last: ShortcutRecordingBuffer.InputResult?
        for token in tokens { last = buffer.receive(token, physicalModifiers: token.modifiers) }
        #expect(last == .rejected)
        guard case let .invalid(message) = buffer.receive(enter, physicalModifiers: []) else {
            Issue.record("Invalid input must report invalid on Enter")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("Direct pairs require both physical inputs to be unmodified", arguments: [true, false])
    func shiftedDirectPairIsRejected(_ shiftFirst: Bool) {
        let shiftedU = KeyToken(symbol: .character("u"), modifiers: [.shift])
        let plain = KeyToken(symbol: .character("j"))
        let first = shiftFirst ? shiftedU : plain
        let second = shiftFirst ? plain : shiftedU
        let firstPhysical: KeyModifiers = shiftFirst ? [.shift] : []
        let secondPhysical: KeyModifiers = shiftFirst ? [] : [.shift]
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))

        #expect(buffer.receive(first, physicalModifiers: firstPhysical) == .recorded)
        #expect(buffer.receive(second, physicalModifiers: secondPhysical) == .rejected)
        guard case .invalid = buffer.receive(enter, physicalModifiers: []) else {
            Issue.record("A physically shifted direct pair must remain invalid on Enter")
            return
        }
    }

    @Test("Autorepeat does not manufacture a sequence or finish recording")
    func repeats() {
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        let y = KeyToken(symbol: .character("y"))
        #expect(buffer.receive(enter, physicalModifiers: [], isRepeat: true) == .ignoredRepeat)
        #expect(buffer.tokens.isEmpty)
        #expect(buffer.receive(y, physicalModifiers: y.modifiers) == .recorded)
        #expect(buffer.receive(y, physicalModifiers: y.modifiers, isRepeat: true) == .ignoredRepeat)
        #expect(buffer.receive(y, physicalModifiers: y.modifiers) == .recorded)
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed("yy"))
    }

    @Test("A plain-key common prefix takes precedence over a direct pair")
    func plainPrefix() {
        let x = KeyToken(symbol: .character("x"))
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: x))
        #expect(buffer.receive(x, physicalModifiers: []) == .recorded)
        #expect(buffer.receive(KeyToken(symbol: .character("y")), physicalModifiers: []) == .recorded)
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed("<prefix>y"))
    }

    @Test("Enter is a control key while modified Enter remains a valid captured chord")
    func enterControlAndModifiedLiteral() throws {
        var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
        let commandEnter = try KeySequenceParser.parseSingleToken("<D-Enter>")
        #expect(buffer.receive(commandEnter, physicalModifiers: commandEnter.modifiers) == .recorded)
        #expect(buffer.receive(enter, physicalModifiers: []) == .completed("<D-Enter>"))
    }

    @Test("Dead and composed input are rejected")
    func composition() {
        for token in [KeyToken.deadKey, .imeComposition] {
            var buffer = ShortcutRecordingBuffer(target: .binding(prefix: prefix))
            #expect(buffer.receive(token, physicalModifiers: token.modifiers) == .rejected)
            guard case .invalid = buffer.receive(enter, physicalModifiers: []) else {
                Issue.record("Invalid composed input must report invalid on Enter")
                continue
            }
        }
    }

    @Test("Canonical token normalization remains unchanged for physical Shift")
    func normalizedIdentity() {
        let shiftedU = KeyToken(symbol: .character("u"), modifiers: [.shift])
        #expect(shiftedU == KeyToken(symbol: .character("U")))
        #expect(shiftedU.description == "U")
    }
}
