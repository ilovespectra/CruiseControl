import Foundation
import Testing
@testable import CruiseCore

struct TaskReviewSafetyTests {
    @Test func examinationHoldsOnlyTheReviewedTaskAndInputsAcrossRelaunch() throws {
        var engine = TaskEngineCache()
        for key in ["clicky:job", "vscode:session"] {
            engine.holdForReview(key, report: "verified response", definition: "Pass tests")
        }
        let restored = try JSONDecoder().decode(TaskEngineCache.self, from: JSONEncoder().encode(engine))
        for key in ["clicky:job", "vscode:session"] {
            #expect(restored.isReviewOnly(key, report: "verified response", definition: "Pass tests"))
            #expect(!restored.isReviewOnly(key, report: "new response", definition: "Pass tests"))
            #expect(!restored.isReviewOnly(key, report: "verified response", definition: "New goal"))
        }
        #expect(!restored.isReviewOnly("other", report: "verified response", definition: "Pass tests"))
    }

    @Test func identicalDeliveredBumpsCannotRepeatAfterRelaunch() throws {
        var engine = TaskEngineCache()
        engine.recordDelivery("clicky:job", definition: "Pass tests", message: "Verify the remaining test.")
        let restored = try JSONDecoder().decode(TaskEngineCache.self, from: JSONEncoder().encode(engine))
        #expect(restored.alreadyDelivered("clicky:job", definition: "Pass tests", message: "Verify the remaining test."))
        #expect(restored.alreadyDelivered("clicky:job", definition: " Pass tests ", message: "Verify the remaining test.\n"))
        #expect(!restored.alreadyDelivered("clicky:other", definition: "Pass tests", message: "Verify the remaining test."))
        #expect(!restored.alreadyDelivered("clicky:job", definition: "Ship release", message: "Verify the remaining test."))
        #expect(!restored.alreadyDelivered("clicky:job", definition: "Pass tests", message: "Fix the new regression."))
    }

    @Test func oldEngineCachesRemainReadable() throws {
        let restored = try JSONDecoder().decode(TaskEngineCache.self, from: Data("{}".utf8))
        #expect(restored.reviewOnlyInputs.isEmpty)
        #expect(restored.deliveredBumps.isEmpty)
    }
}
