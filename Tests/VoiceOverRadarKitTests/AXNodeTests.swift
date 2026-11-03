import XCTest
@testable import VoiceOverRadarKit

final class AXNodeTests: XCTestCase {

    func testSnapshotRoundTripsThroughJSON() throws {
        let node = AXNode(
            id: "1", label: "Send", value: nil, hint: "Double tap to send",
            identifier: "send.button", traits: ["button"], isElement: true,
            isContainer: false, containerType: nil,
            frame: [10, 20, 100, 44], voiceOver: "Send, button, Double tap to send",
            customActions: ["Delete"], customContent: ["Amount: £10"],
            children: []
        )
        let snapshot = AXSnapshot(
            appName: "JazariOneDev", screenSize: [393, 852], roots: [node],
            modalPresented: true, modalLabel: "Send money"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AXSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.roots.first?.traits, ["button"])
    }
}
