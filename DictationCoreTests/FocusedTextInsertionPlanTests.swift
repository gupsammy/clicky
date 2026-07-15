import Foundation
import Testing
@testable import ClickyDictationCore

@Test func insertsAtTheCurrentUTF16Caret() throws {
    let plan = try FocusedTextInsertionPlan(
        currentValue: "Hello world",
        selectedUTF16Range: NSRange(location: 5, length: 0),
        replacementText: ", brave"
    )

    #expect(plan.updatedValue == "Hello, brave world")
    #expect(plan.updatedSelectionRange == NSRange(location: 12, length: 0))
}

@Test func replacesTheSelectedUTF16Range() throws {
    let plan = try FocusedTextInsertionPlan(
        currentValue: "ship the old draft",
        selectedUTF16Range: NSRange(location: 9, length: 9),
        replacementText: "new version"
    )

    #expect(plan.updatedValue == "ship the new version")
    #expect(plan.updatedSelectionRange == NSRange(location: 20, length: 0))
}

@Test func addsWordBoundarySpacingAtAnOrdinaryCaret() throws {
    let plan = try FocusedTextInsertionPlan(
        currentValue: "hellothere",
        selectedUTF16Range: NSRange(location: 5, length: 0),
        replacementText: "world"
    )

    #expect(plan.replacementText == " world ")
    #expect(plan.updatedValue == "hello world there")
    #expect(plan.updatedSelectionRange == NSRange(location: 12, length: 0))
}

@Test func preservesUnicodeOutsideTheSelection() throws {
    let currentValue = "🚀 old"
    let oldWordRange = (currentValue as NSString).range(of: "old")
    let plan = try FocusedTextInsertionPlan(
        currentValue: currentValue,
        selectedUTF16Range: oldWordRange,
        replacementText: "ready"
    )

    #expect(plan.updatedValue == "🚀 ready")
}

@Test func rejectsAStaleSelectionRange() {
    #expect(throws: FocusedTextInsertionPlanError.self) {
        try FocusedTextInsertionPlan(
            currentValue: "short",
            selectedUTF16Range: NSRange(location: 20, length: 0),
            replacementText: "unsafe"
        )
    }
}
