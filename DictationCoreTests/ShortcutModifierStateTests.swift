import Testing
@testable import ClickyDictationCore

private let controlFlag: UInt = 1 << 0
private let optionFlag: UInt = 1 << 1
private let functionFlag: UInt = 1 << 2
private let shiftFlag: UInt = 1 << 3
private let capsLockFlag: UInt = 1 << 4
private let relevantMask = controlFlag | optionFlag | functionFlag | shiftFlag

@Test func exactShortcutMatchAllowsIrrelevantFlags() {
    #expect(ShortcutModifierState.isExactMatch(
        activeRawValue: controlFlag | functionFlag | capsLockFlag,
        expectedRawValue: controlFlag | functionFlag,
        relevantMaskRawValue: relevantMask
    ))
}

@Test func exactShortcutMatchRejectsExtraRelevantModifiers() {
    #expect(!ShortcutModifierState.isExactMatch(
        activeRawValue: controlFlag | optionFlag | functionFlag,
        expectedRawValue: controlFlag | functionFlag,
        relevantMaskRawValue: relevantMask
    ))
}

@Test func neutralStateRequiresEveryRelevantModifierToBeReleased() {
    #expect(!ShortcutModifierState.isNeutral(
        activeRawValue: controlFlag,
        relevantMaskRawValue: relevantMask
    ))
    #expect(ShortcutModifierState.isNeutral(
        activeRawValue: capsLockFlag,
        relevantMaskRawValue: relevantMask
    ))
}
