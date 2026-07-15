import Foundation

public enum ShortcutModifierState {
    public static func isExactMatch(
        activeRawValue: UInt,
        expectedRawValue: UInt,
        relevantMaskRawValue: UInt
    ) -> Bool {
        activeRawValue & relevantMaskRawValue
            == expectedRawValue & relevantMaskRawValue
    }

    public static func isNeutral(
        activeRawValue: UInt,
        relevantMaskRawValue: UInt
    ) -> Bool {
        activeRawValue & relevantMaskRawValue == 0
    }
}
