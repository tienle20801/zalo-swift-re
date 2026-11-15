import Foundation

enum GroupMemberRole: String, Codable, Sendable {
    case owner
    case admin
    case member

    var label: String? {
        switch self {
        case .owner: "Trưởng nhóm"
        case .admin: "Phó nhóm"
        case .member: nil
        }
    }

    var sortPriority: Int {
        switch self {
        case .owner: 0
        case .admin: 1
        case .member: 2
        }
    }
}

struct GroupMemberItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let avatar: URL?
    let role: GroupMemberRole
}

struct GroupAdminState: Equatable, Sendable {
    let groupId: String
    let creatorId: String
    let adminIds: Set<String>
    var inviteLink: String?
    var lockSendMsg: Bool
    var lockUpdateInfo: Bool
    var joinAppr: Bool
    var ttl: Int
    var members: [GroupMemberItem]

    func role(for userId: String?) -> GroupMemberRole {
        guard let userId, !userId.isEmpty else { return .member }
        if userId == creatorId { return .owner }
        if adminIds.contains(userId) { return .admin }
        return .member
    }

    func canManage(userId: String?) -> Bool {
        let myRole = role(for: userId)
        return myRole == .owner || myRole == .admin
    }
}

struct GroupNoteItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let createdAt: Date?
    let isPinned: Bool
}

struct QuickMessageTemplate: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var shortcut: String
    var title: String
    var content: String
}

struct AddGroupMembersResult: Equatable, Sendable {
    let ok: Bool
    let addedCount: Int
    let errorMessage: String?
}

extension ZaloEngine {
    func loadGroupAdminState(for groupId: String) async -> GroupAdminState? {
        guard let dict = await evaluateGroupAdmin("getGroupAdminInfo", [groupId]) as? [String: Any] else {
            return nil
        }
        let resolvedGroupId = dict["groupId"] as? String ?? groupId
        let creatorId = dict["creatorId"] as? String ?? ""
        let adminIds = Set((dict["adminIds"] as? [Any] ?? []).compactMap { $0 as? String })
        let inviteLinkRaw = dict["inviteLink"] as? String ?? ""
        let inviteLink = inviteLinkRaw.isEmpty ? nil : inviteLinkRaw
        let lockSendMsg = (dict["lockSendMsg"] as? NSNumber)?.boolValue ?? false
        let lockUpdateInfo = (dict["lockUpdateInfo"] as? NSNumber)?.boolValue ?? false
        let joinAppr = (dict["joinAppr"] as? NSNumber)?.boolValue ?? false
        let ttl = (dict["ttl"] as? NSNumber)?.intValue ?? 0

        let rawMembers = dict["members"] as? [[String: Any]] ?? []
        let members: [GroupMemberItem] = rawMembers.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Thành viên"
            let avatar = (m["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let role = GroupMemberRole(rawValue: m["role"] as? String ?? "") ?? .member
            return GroupMemberItem(id: id, name: name, avatar: avatar, role: role)
        }.sorted { lhs, rhs in
            if lhs.role.sortPriority != rhs.role.sortPriority {
                return lhs.role.sortPriority < rhs.role.sortPriority
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return GroupAdminState(
            groupId: resolvedGroupId,
            creatorId: creatorId,
            adminIds: adminIds,
            inviteLink: inviteLink,
            lockSendMsg: lockSendMsg,
            lockUpdateInfo: lockUpdateInfo,
            joinAppr: joinAppr,
            ttl: ttl,
            members: members
        )
    }

    func setGroupDeputy(in groupId: String, memberId: String, isAdmin: Bool) async -> Bool {
        let res = await evaluateGroupAdmin("setDeputy", [groupId, memberId, isAdmin]) as? [String: Any]
        return (res?["ok"] as? NSNumber)?.boolValue ?? false
    }

    func kickGroupMember(in groupId: String, memberId: String, block: Bool = false) async -> Bool {
        let res = await evaluateGroupAdmin("removeMember", [groupId, memberId, block]) as? [String: Any]
        return (res?["ok"] as? NSNumber)?.boolValue ?? false
    }

    func addGroupMembers(in groupId: String, memberIds: [String]) async -> AddGroupMembersResult {
        let clean = memberIds.filter { !$0.isEmpty }
        guard !clean.isEmpty else {
            return AddGroupMembersResult(ok: false, addedCount: 0, errorMessage: "Chưa chọn thành viên")
        }
        let res = await evaluateGroupAdmin("addMembers", [groupId, clean]) as? [String: Any]
        let ok = (res?["ok"] as? NSNumber)?.boolValue ?? false
        let added = (res?["addedCount"] as? NSNumber)?.intValue ?? (ok ? clean.count : 0)
        let err = (res?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AddGroupMembersResult(ok: ok, addedCount: added, errorMessage: err)
    }

    func updateGroupSettings(in groupId: String, lockSendMsg: Bool, lockUpdateInfo: Bool, joinAppr: Bool) async -> Bool {
        let payload: [String: Any] = [
            "lockSendMsg": lockSendMsg,
            "lockUpdateInfo": lockUpdateInfo,
            "joinAppr": joinAppr,
        ]
        let res = await evaluateGroupAdmin("updateSettings", [groupId, payload]) as? [String: Any]
        return (res?["ok"] as? NSNumber)?.boolValue ?? false
    }

    func fetchGroupInviteLink(for groupId: String) async -> String? {
        let res = await evaluateGroupAdmin("getOrToggleGroupLink", [groupId, "get"]) as? [String: Any]
        let link = res?["link"] as? String ?? ""
        return link.isEmpty ? nil : link
    }

    func toggleGroupInviteLink(for groupId: String, enable: Bool) async -> String? {
        let action = enable ? "enable" : "disable"
        let res = await evaluateGroupAdmin("getOrToggleGroupLink", [groupId, action]) as? [String: Any]
        let link = res?["link"] as? String ?? ""
        return link.isEmpty ? nil : link
    }

    func loadGroupNotes(for groupId: String) async -> [GroupNoteItem] {
        guard let list = await evaluateGroupAdmin("getGroupNotes", [groupId]) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let title = item["title"] as? String ?? "Ghi chú"
            let ts = (item["createdTime"] as? NSNumber)?.doubleValue ?? 0
            let createdAt = ts > 0 ? Date(timeIntervalSince1970: ts > 10_000_000_000 ? ts / 1000 : ts) : nil
            let isPinned = (item["isPinned"] as? NSNumber)?.boolValue ?? false
            return GroupNoteItem(id: id, title: title, createdAt: createdAt, isPinned: isPinned)
        }
    }

    func createGroupNote(in groupId: String, title: String, pin: Bool = true) async -> Bool {
        let res = await evaluateGroupAdmin("createGroupNote", [groupId, title, pin]) as? [String: Any]
        return (res?["ok"] as? NSNumber)?.boolValue ?? false
    }

    func loadAutoDeleteTTL(for convId: String) async -> Int {
        let val = await evaluateGroupAdmin("getAutoDeleteTTL", [convId]) as? NSNumber
        return val?.intValue ?? 0
    }

    func updateAutoDeleteTTL(for convId: String, ttlSeconds: Int) async -> Bool {
        let res = await evaluateGroupAdmin("setAutoDeleteTTL", [convId, ttlSeconds]) as? [String: Any]
        return (res?["ok"] as? NSNumber)?.boolValue ?? false
    }

    func loadQuickMessages() async -> [QuickMessageTemplate] {
        parseQuickMessages(await evaluateGroupAdmin("getQuickMessages", []))
    }

    func saveQuickMessage(shortcut: String, title: String, content: String) async -> [QuickMessageTemplate] {
        let payload: [String: Any] = [
            "shortcut": shortcut,
            "title": title,
            "content": content,
        ]
        return parseQuickMessages(await evaluateGroupAdmin("saveQuickMessage", [payload]))
    }

    func deleteQuickMessage(id: String) async -> [QuickMessageTemplate] {
        parseQuickMessages(await evaluateGroupAdmin("deleteQuickMessage", [id]))
    }

    private func parseQuickMessages(_ raw: Any?) -> [QuickMessageTemplate] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String,
                  let shortcut = item["shortcut"] as? String,
                  let content = item["content"] as? String,
                  !shortcut.isEmpty, !content.isEmpty
            else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? shortcut
            return QuickMessageTemplate(id: id, shortcut: shortcut, title: title, content: content)
        }
    }

    private func evaluateGroupAdmin(_ method: String, _ args: [Any]) async -> Any? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8),
              let host
        else { return nil }
        return await host.evaluate(
            "const ga = window.__zaloGroupAdmin; if (!ga || !ga.\(method)) return null; return await ga.\(method)(...\(json));"
        )
    }
}
