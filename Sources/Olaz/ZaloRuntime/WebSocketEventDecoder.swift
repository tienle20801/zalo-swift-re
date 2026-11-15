import Compression
import CryptoKit
import Foundation

/// Decoded event emitted passively from incoming Zalo WebSocket binary frames (`cmd` / `subCmd` + `decodeEventData`).
enum WebSocketDecodedEvent: Sendable, Equatable {
    case cipherKeyUpdated
    case typing(conversationId: String, senderId: String, isGroup: Bool)
    case uploadFileDone(fileId: String, fileUrl: String)
    case seenOrDelivered(conversationId: String, isGroup: Bool, isSeen: Bool)
    case messageUndo(conversationId: String, senderId: String, cliMsgId: String, isGroup: Bool)
    case incomingMessage(
        conversationId: String,
        msgId: String,
        senderId: String,
        senderName: String,
        textPreview: String,
        isGroup: Bool
    )
}

/// Passive, thread-safe binary decoder for Zalo realtime WebSocket frames (`[version u8][cmd u16 LE][subCmd u8][JSON]`).
///
/// Mirrors the wire decryption pipeline (`encrypt` modes `0..3`: plain JSON, zlib deflate, AES-256-GCM + zlib,
/// AES-256-GCM raw) without mutating or intercepting frames destined for the official renderer.
final class WebSocketEventDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var cipherKey: Data?

    var hasCipherKey: Bool {
        lock.withLock { cipherKey != nil }
    }

    func setCipherKey(_ key: Data?) {
        lock.withLock { cipherKey = key }
    }

    private func currentCipherKey() -> Data? {
        lock.withLock { cipherKey }
    }

    /// Decodes a single raw WebSocket binary frame into zero or more semantic events.
    func decode(frame: Data) -> [WebSocketDecodedEvent] {
        guard frame.count > 4 else { return [] }
        let header = [UInt8](frame.prefix(4))
        let version = Int(header[0])
        let cmd = Int(header[1]) | (Int(header[2]) << 8)
        let subCmd = Int(header[3])

        let payloadData = frame.dropFirst(4)
        guard !payloadData.isEmpty,
              let parsed = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else {
            return []
        }

        // Handshake key frame: version=1, cmd=1, subCmd=1 carries base64 `key`.
        if version == 1, cmd == 1, subCmd == 1,
           let keyString = parsed["key"] as? String,
           let keyData = Data(base64Encoded: keyString),
           !keyData.isEmpty
        {
            setCipherKey(keyData)
            return [.cipherKeyUpdated]
        }

        guard let outer = decodeEventData(parsed),
              let data = outer["data"] as? [String: Any]
        else {
            return []
        }

        // Typing events (cmd=602, subCmd=0)
        if cmd == 602, subCmd == 0 {
            return decodeTypingEvents(from: data)
        }

        // Control events (version=1, cmd=601, subCmd=0), including `file_done`
        if version == 1, cmd == 601, subCmd == 0 {
            return decodeControlEvents(from: data)
        }

        // 1:1 messages & undo (version=1, cmd=501|551, subCmd=0)
        if version == 1, (cmd == 501 || cmd == 551), subCmd == 0 {
            let msgs = data["msgs"] as? [[String: Any]] ?? []
            return decodeMessageEvents(msgs, isGroup: false)
        }

        // Group messages & undo (version=1, cmd=521, subCmd=0)
        if version == 1, cmd == 521, subCmd == 0 {
            let groupMsgs = data["groupMsgs"] as? [[String: Any]] ?? []
            return decodeMessageEvents(groupMsgs, isGroup: true)
        }

        // Delivered / Seen receipts (cmd=502 for 1:1, cmd=522 for Group)
        if (cmd == 502 || cmd == 522), subCmd == 0 {
            return decodeReceiptEvents(from: data, isGroup: cmd == 522)
        }

        return []
    }

    /// Decrypts and/or decompresses the `{ encrypt, data }` envelope produced by Zalo's realtime socket.
    func decodeEventData(_ parsed: [String: Any]) -> [String: Any]? {
        guard let encrypt = (parsed["encrypt"] as? NSNumber)?.intValue,
              let rawData = parsed["data"] as? String,
              (0...3).contains(encrypt)
        else {
            return nil
        }

        if encrypt == 0 {
            guard let jsonBytes = rawData.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: jsonBytes)) as? [String: Any]
        }

        let base64Input = encrypt == 1 ? rawData : (rawData.removingPercentEncoding ?? rawData)
        guard let decodedBuffer = Data(base64Encoded: base64Input) else { return nil }

        let plaintextBuffer: Data
        if encrypt == 1 {
            plaintextBuffer = decodedBuffer
        } else {
            guard decodedBuffer.count >= 48, let keyData = currentCipherKey() else { return nil }
            let iv = decodedBuffer.subdata(in: 0..<16)
            let aad = decodedBuffer.subdata(in: 16..<32)
            let ciphertextAndTag = decodedBuffer.subdata(in: 32..<decodedBuffer.count)
            guard ciphertextAndTag.count >= 16 else { return nil }
            let ciphertext = ciphertextAndTag.prefix(ciphertextAndTag.count - 16)
            let tag = ciphertextAndTag.suffix(16)

            do {
                let nonce = try AES.GCM.Nonce(data: iv)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                plaintextBuffer = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData), authenticating: aad)
            } catch {
                return nil
            }
        }

        let jsonPayload: Data
        if encrypt == 3 {
            jsonPayload = plaintextBuffer
        } else {
            guard let inflated = Self.inflateZlib(plaintextBuffer) else { return nil }
            jsonPayload = inflated
        }

        return (try? JSONSerialization.jsonObject(with: jsonPayload)) as? [String: Any]
    }

    // MARK: - Frame Event Extractors

    private func decodeTypingEvents(from data: [String: Any]) -> [WebSocketDecodedEvent] {
        guard let actions = data["actions"] as? [[String: Any]] else { return [] }
        var events: [WebSocketDecodedEvent] = []
        for action in actions {
            guard action["act_type"] as? String == "typing",
                  let rawActionData = action["data"] as? String
            else { continue }

            let trimmed = rawActionData.trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonText = trimmed.hasPrefix("{") ? trimmed : "{\(trimmed)}"
            guard let jsonBytes = jsonText.data(using: .utf8),
                  let info = (try? JSONSerialization.jsonObject(with: jsonBytes)) as? [String: Any]
            else { continue }

            let isGroup = action["act"] as? String == "gtyping"
            let senderId = Self.stringID(info["uid"]) ?? ""
            let groupId = Self.stringID(info["gid"])
            let convId = isGroup ? (groupId ?? senderId) : senderId
            guard !convId.isEmpty else { continue }
            events.append(.typing(conversationId: convId, senderId: senderId, isGroup: isGroup))
        }
        return events
    }

    private func decodeControlEvents(from data: [String: Any]) -> [WebSocketDecodedEvent] {
        guard let controls = data["controls"] as? [[String: Any]] else { return [] }
        var events: [WebSocketDecodedEvent] = []
        for control in controls {
            guard let content = control["content"] as? [String: Any],
                  content["act_type"] as? String == "file_done"
            else { continue }
            let fileId = Self.stringID(content["fileId"]) ?? ""
            let innerData = content["data"] as? [String: Any]
            let fileUrl = innerData?["url"] as? String ?? ""
            events.append(.uploadFileDone(fileId: fileId, fileUrl: fileUrl))
        }
        return events
    }

    private func decodeMessageEvents(_ items: [[String: Any]], isGroup: Bool) -> [WebSocketDecodedEvent] {
        var events: [WebSocketDecodedEvent] = []
        for msg in items {
            let uidFrom = Self.stringID(msg["uidFrom"]) ?? ""
            let idTo = Self.stringID(msg["idTo"]) ?? ""
            // Skip self-sent echoes (`uidFrom == "0"`).
            if uidFrom == "0" { continue }

            let convId = isGroup ? idTo : uidFrom
            guard !convId.isEmpty else { continue }

            if let contentDict = msg["content"] as? [String: Any],
               contentDict["deleteMsg"] != nil
            {
                let cliMsgId = Self.stringID(contentDict["cliMsgId"]) ?? Self.stringID(msg["cliMsgId"]) ?? ""
                events.append(.messageUndo(
                    conversationId: convId,
                    senderId: uidFrom,
                    cliMsgId: cliMsgId,
                    isGroup: isGroup
                ))
                continue
            }

            let msgId = Self.stringID(msg["msgId"]) ?? Self.stringID(msg["cliMsgId"]) ?? ""
            let senderName = msg["dName"] as? String ?? ""
            let preview: String
            if let text = msg["content"] as? String {
                preview = text
            } else if let contentDict = msg["content"] as? [String: Any] {
                preview = (contentDict["title"] as? String)
                    ?? (contentDict["description"] as? String)
                    ?? ""
            } else {
                preview = ""
            }

            events.append(.incomingMessage(
                conversationId: convId,
                msgId: msgId,
                senderId: uidFrom,
                senderName: senderName,
                textPreview: preview,
                isGroup: isGroup
            ))
        }
        return events
    }

    private func decodeReceiptEvents(from data: [String: Any], isGroup: Bool) -> [WebSocketDecodedEvent] {
        var events: [WebSocketDecodedEvent] = []
        let seenKey = isGroup ? "groupSeens" : "seens"
        for receipt in data[seenKey] as? [[String: Any]] ?? [] {
            if let convId = Self.stringID(receipt["idTo"]) ?? Self.stringID(receipt["uidFrom"]) ?? Self.stringID(receipt["gid"]),
               !convId.isEmpty
            {
                events.append(.seenOrDelivered(conversationId: convId, isGroup: isGroup, isSeen: true))
            }
        }
        for receipt in data["delivereds"] as? [[String: Any]] ?? [] {
            if let convId = Self.stringID(receipt["idTo"]) ?? Self.stringID(receipt["uidFrom"]) ?? Self.stringID(receipt["gid"]),
               !convId.isEmpty
            {
                events.append(.seenOrDelivered(conversationId: convId, isGroup: isGroup, isSeen: false))
            }
        }
        return events
    }

    // MARK: - Helpers

    private static func stringID(_ value: Any?) -> String? {
        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        return nil
    }

    /// Inflates zlib-wrapped (`0x78 ...`) or raw deflate payloads produced by `pako` / zlib.
    static func inflateZlib(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // Standard RFC 1950 zlib header: CMF lower nibble == 8 (deflate) and (CMF*256 + FLG) % 31 == 0.
        let hasZlibHeader = data.count > 6
            && (data[data.startIndex] & 0x0F) == 0x08
            && (((Int(data[data.startIndex]) << 8) | Int(data[data.index(after: data.startIndex)])) % 31 == 0)

        if hasZlibHeader, let result = decompressDeflate(data.dropFirst(2)) {
            return result
        }
        return decompressDeflate(data)
    }

    private static func decompressDeflate(_ rawDeflate: Data) -> Data? {
        guard !rawDeflate.isEmpty else { return nil }
        let maxBufferSize = 8 * 1024 * 1024
        var capacity = max(4096, rawDeflate.count * 6)

        while capacity <= maxBufferSize {
            var destination = Data(count: capacity)
            let decodedSize: Int = destination.withUnsafeMutableBytes { dstPtr in
                rawDeflate.withUnsafeBytes { srcPtr in
                    guard let dstBase = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else { return 0 }
                    return compression_decode_buffer(
                        dstBase,
                        capacity,
                        srcBase,
                        rawDeflate.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decodedSize == 0 {
                return nil
            }
            if decodedSize < capacity {
                destination.count = decodedSize
                return destination
            }
            capacity *= 2
        }
        return nil
    }
}
