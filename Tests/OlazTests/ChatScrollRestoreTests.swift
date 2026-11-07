import Foundation
import Testing
@testable import Olaz

/// After an older page is prepended, the chat scrolls the row that was at the top back there. When that row was a day
/// separator replaced by older messages of the same day, its message is used instead of leaving the view at the top
/// (which used to load page after page on its own).
@Suite struct ChatScrollRestoreTests {
    private func rows(_ ids: [String]) -> [ChatRow] {
        ids.map { ChatRow(id: $0, kind: .day(Date(timeIntervalSince1970: 0))) }
    }

    @Test func keepsTheSavedRowWhenItStillExists() {
        let after = rows(["day-a1", "a1", "a2", "day-b1", "b1"])
        #expect(ChatRow.restoreTarget("day-b1", fallback: "b1", in: after) == "day-b1")
        #expect(ChatRow.restoreTarget("a2", fallback: "a1", in: after) == "a2")
    }

    @Test func daySeparatorReplacedBySameDayHistoryFallsBackToItsMessage() {
        // Before: [day-b1, b1, b2]; older messages of the same day (b0) arrive, so the separator becomes day-b0.
        let after = rows(["day-b0", "b0", "b1", "b2"])
        #expect(ChatRow.restoreTarget("day-b1", fallback: "b1", in: after) == "b1")
    }

    @Test func unknownOrMissingRowUsesTheFallback() {
        let after = rows(["day-x0", "x0", "x1"])
        #expect(ChatRow.restoreTarget(nil, fallback: "x1", in: after) == "x1")
        #expect(ChatRow.restoreTarget("gone", fallback: "x1", in: after) == "x1")
        #expect(ChatRow.restoreTarget("day-gone", fallback: "x1", in: after) == "x1")
    }

    @Test func rowCacheIncrementalStatusAndAppendUpdates() {
        let cache = RowCache()
        let baseDate = Date(timeIntervalSince1970: 1_760_000_000)
        func makeMsg(id: String, isMine: Bool, offset: TimeInterval, status: ChatMessage.Status = .sent) -> ChatMessage {
            ChatMessage(
                id: id, conversationId: "c1", senderId: isMine ? "me" : "u2",
                senderName: isMine ? "Tôi" : "An", senderAvatar: nil, isMine: isMine,
                kind: .text, text: "msg-\(id)", date: baseDate.addingTimeInterval(offset),
                status: status, quote: nil, reactions: [], isE2EE: false
            )
        }

        let m1 = makeMsg(id: "m1", isMine: true, offset: 0, status: .sending)
        let r1 = cache.rows(for: [m1])
        #expect(r1.map(\.id) == ["day-m1", "m1"])
        if case .message(let msg, let first, let last, let showStatus) = r1[1].kind {
            #expect(msg.status == .sending && first && last && showStatus)
        } else { Issue.record("expected message row") }

        // Status update on the tail message reuses cached day boundaries and updates the row.
        let m1Seen = makeMsg(id: "m1", isMine: true, offset: 0, status: .seen)
        let r2 = cache.rows(for: [m1Seen])
        if case .message(let msg, _, _, let showStatus) = r2[1].kind {
            #expect(msg.status == .seen && showStatus)
        } else { Issue.record("expected message row") }

        // Appending a second outgoing message within 5 minutes groups them and moves the status indicator to m2.
        let m2 = makeMsg(id: "m2", isMine: true, offset: 60, status: .delivered)
        let r3 = cache.rows(for: [m1Seen, m2])
        #expect(r3.map(\.id) == ["day-m1", "m1", "m2"])
        if case .message(_, let first1, let last1, let status1) = r3[1].kind,
           case .message(_, let first2, let last2, let status2) = r3[2].kind {
            #expect(first1 && !last1 && !status1)
            #expect(!first2 && last2 && status2)
        } else { Issue.record("expected grouped message rows") }
    }
}
