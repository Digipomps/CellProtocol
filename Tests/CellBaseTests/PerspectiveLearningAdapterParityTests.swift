// Shared probe compiled against full CellBase and the standalone test bindings.
import Foundation
#if !STANDALONE_PARITY
import XCTest
@testable import CellBase
#endif
func perspectiveLearningParityData() async throws -> Data {
 let e = RelationalLearningEngine()
 let pref = RelationalExplicitPreferenceEvent(eventId: "parity-pref", timestamp: 100, purposeId: "purpose://parity", relationType: .purposeInterest, targetNode: RelationalNode(type: .interest, id: "interest://home"), preferenceWeight: 0.9)
 _ = try await e.applyEnvelopeTransaction(.from(pref))
 let result = RelationalPurposeLifecycleEvent(eventId: "parity-result", timestamp: 100 + 120 * 86400, status: .failed, purposeId: "purpose://parity", activeInterestRefs: ["interest://home"], contextConfidence: 1)
 let envelope = try RelationalLearningEventEnvelope.from(result)
 _ = try await e.applyEnvelopeTransaction(envelope)
 let duplicate = try await e.applyEnvelopeTransaction(envelope)
 let snapshot = RelationalContextSnapshot(activeInterestRefs: ["interest://home"])
 let journal = await e.journalSnapshot()
 let restore = RelationalLearningEngine(); try await restore.restore(from: journal)
 struct Probe: Encodable {
  var edges: [RelationalEdge];var scores:[RelationalPurposeScore];var restored:[RelationalPurposeScore];var duplicateApplied:Bool;var journal:RelationalLearningPersistedJournal;var sha256ABC:String
 }
 let probe=Probe(edges:await e.edges(),scores:await e.scorePurposes(contextSnapshot:snapshot,at:100+120*86400),restored:await restore.scorePurposes(contextSnapshot:snapshot,at:100+120*86400),duplicateApplied:duplicate.applied,journal:journal,sha256ABC:FlowHasher.sha256Hex(Data("abc".utf8)))
 let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(probe)
}
#if !STANDALONE_PARITY
final class PerspectiveLearningAdapterParityTests: XCTestCase {
 func testFullRuntimeExportsStandaloneParityVector() async throws {
  let data=try await perspectiveLearningParityData()
  let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
  XCTAssertEqual(object["duplicateApplied"] as? Bool,false)
  XCTAssertEqual(object["sha256ABC"] as? String,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  let path=ProcessInfo.processInfo.environment["PERSPECTIVE_PARITY_OUTPUT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("perspective-learning-full-runtime-parity.json").path
  try data.write(to:URL(fileURLWithPath:path),options:.atomic)
  print("PERSPECTIVE_PARITY_OUTPUT=\(path)")
 }
}
#endif
