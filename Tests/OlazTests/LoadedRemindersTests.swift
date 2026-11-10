import Testing
import Foundation
@testable import Olaz

@Suite struct LoadedRemindersTests {
    private func makeReminder(id: String, title: String, start: Date?, repeatLabel: String = "") -> ChatMessage {
        var card = ChatMessage.ECard()
        card.style = .reminder
        card.reminderTitle = title
        card.reminderStart = start
        card.reminderRepeat = repeatLabel
        return ChatMessage(
            id: id, conversationId: "c1", senderId: "u1", senderName: "User", senderAvatar: nil,
            isMine: false, kind: .ecard(card), text: "", date: Date(), status: .sent, quote: nil, reactions: [], isE2EE: false
        )
    }

    @Test func fallsBackToTitleOrDescriptionWhenReminderTitleEmpty() {
        var card = ChatMessage.ECard()
        card.style = .reminder
        card.title = "Tiêu đề card"
        card.description = "Mô tả card"
        card.reminderStart = Date().addingTimeInterval(600)
        let m = ChatMessage(
            id: "r_fallback", conversationId: "c1", senderId: "u1", senderName: "User", senderAvatar: nil,
            isMine: false, kind: .ecard(card), text: "", date: Date(), status: .sent, quote: nil, reactions: [], isE2EE: false
        )

        let loaded = LoadedReminders(messages: [m])
        #expect(loaded.reminders.count == 1)
        #expect(loaded.reminders[0].title == "Tiêu đề card")
    }

    @Test func extractsAndSortsReminders() {
        let base = Date()
        let t1 = base.addingTimeInterval(3600)
        let t2 = base.addingTimeInterval(7200)

        let m1 = makeReminder(id: "r1", title: "Họp sau", start: t2)
        let m2 = makeReminder(id: "r2", title: "Họp sớm", start: t1)
        let m3 = makeReminder(id: "r3", title: "Bị xóa", start: t1)

        let loaded = LoadedReminders(messages: [m1, m2, m3], deletedIds: ["r3"])
        #expect(loaded.reminders.count == 2)
        #expect(loaded.reminders[0].id == "r2")
        #expect(loaded.reminders[0].title == "Họp sớm")
        #expect(loaded.reminders[1].id == "r1")
        #expect(loaded.reminders[1].title == "Họp sau")
    }
}
