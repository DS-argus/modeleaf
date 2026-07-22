import Step0ProbeSupport
import Testing

@Suite("Step 0 input policy")
struct InputPolicyTests {
    let global = ProbeActionDescriptor(id: "document.open", scope: .global)

    @Test(arguments: ["o", "go", "<C-o>", "<A-o>", "<S-o>"])
    func unsafePromptGlobalsAreRejected(_ source: String) {
        #expect(!ProbePromptSafeBindingPredicate.evaluate(action: global, sequence: ProbeKeySequence(source)).isValid)
    }

    @Test(arguments: ["<D-o>", "<D-q>", "<D-F12>"])
    func safeCommandGlobalsRemainValid(_ source: String) {
        #expect(ProbePromptSafeBindingPredicate.evaluate(action: global, sequence: ProbeKeySequence(source)).isValid)
    }

    @Test func everyReservationIsRejected() {
        for source in PromptNativeReservationV1.tokens.union(SystemKeyReservationV1.tokens) {
            #expect(!ProbePromptSafeBindingPredicate.evaluate(action: global, sequence: ProbeKeySequence(source)).isValid)
        }
    }
}

@Test("TOML qualification section passes")
func tomlQualificationPasses() {
    #expect(TOMLQualificationProbe.run().passed)
}
