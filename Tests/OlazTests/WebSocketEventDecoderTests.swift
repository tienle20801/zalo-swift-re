import Compression
import CryptoKit
import Foundation
import Testing
@testable import Olaz

@Suite struct WebSocketEventDecoderTests {
    @Test func decodesHandshakeCipherKeyAndEncrypt0Typing() throws {
        let decoder = WebSocketEventDecoder()
        let keyData = Data(repeating: 0xAB, count: 32)
        let handshakeJSON = #"{"key":"\#(keyData.base64EncodedString())"}"#
        let handshakeFrame = makeFrame(version: 1, cmd: 1, subCmd: 1, json: handshakeJSON)

        let keyEvents = decoder.decode(frame: handshakeFrame)
        #expect(keyEvents == [.cipherKeyUpdated])
        #expect(decoder.hasCipherKey)

        let innerTyping = #"{"data":{"actions":[{"act_type":"typing","act":"gtyping","data":"\"uid\":\"12345\",\"gid\":\"g999\""}]}}"#
        let outerTyping = makeEnvelope(encrypt: 0, data: innerTyping)
        let typingFrame = makeFrame(version: 1, cmd: 602, subCmd: 0, jsonObject: outerTyping)

        let typingEvents = decoder.decode(frame: typingFrame)
        #expect(typingEvents == [.typing(conversationId: "g999", senderId: "12345", isGroup: true)])
    }

    @Test func decodesEncrypt1ZlibWrappedFileDoneControl() throws {
        let decoder = WebSocketEventDecoder()
        let inner = #"{"data":{"controls":[{"content":{"act_type":"file_done","fileId":987654,"data":{"url":"https://cdn.zalo.me/file.pdf"}}}]}}"#
        let zlibData = try zlibWrap(Data(inner.utf8))
        let outer = makeEnvelope(encrypt: 1, data: zlibData.base64EncodedString())
        let frame = makeFrame(version: 1, cmd: 601, subCmd: 0, jsonObject: outer)

        let events = decoder.decode(frame: frame)
        #expect(events == [.uploadFileDone(fileId: "987654", fileUrl: "https://cdn.zalo.me/file.pdf")])
    }

    @Test func decodesEncrypt2AesGcmZlibIncomingMessageAndUndo() throws {
        let decoder = WebSocketEventDecoder()
        let key = SymmetricKey(size: .bits256)
        decoder.setCipherKey(key.withUnsafeBytes { Data($0) })

        let msgJSON = #"{"data":{"msgs":[{"uidFrom":"4242","idTo":"0","msgId":"888001","dName":"Alice","content":"Xin chào Olaz"}]}}"#
        let deflated = try zlibWrap(Data(msgJSON.utf8))
        let encryptedB64 = try encryptGCM(plaintext: deflated, key: key)
        let encodedParam = encryptedB64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? encryptedB64
        let frame = makeFrame(version: 1, cmd: 501, subCmd: 0, jsonObject: makeEnvelope(encrypt: 2, data: encodedParam))

        let events = decoder.decode(frame: frame)
        #expect(events == [
            .incomingMessage(
                conversationId: "4242",
                msgId: "888001",
                senderId: "4242",
                senderName: "Alice",
                textPreview: "Xin chào Olaz",
                isGroup: false
            )
        ])

        let undoJSON = #"{"data":{"groupMsgs":[{"uidFrom":"777","idTo":"g100","cliMsgId":"555","content":{"deleteMsg":1,"cliMsgId":555}}]}}"#
        let encryptedUndo = try encryptGCM(plaintext: Data(undoJSON.utf8), key: key)
        let undoFrame = makeFrame(version: 1, cmd: 521, subCmd: 0, jsonObject: makeEnvelope(encrypt: 3, data: encryptedUndo))

        let undoEvents = decoder.decode(frame: undoFrame)
        #expect(undoEvents == [.messageUndo(conversationId: "g100", senderId: "777", cliMsgId: "555", isGroup: true)])
    }

    @Test func decodesEncrypt3AesGcmReceiptsWithoutCompression() throws {
        let decoder = WebSocketEventDecoder()
        let key = SymmetricKey(size: .bits256)
        decoder.setCipherKey(key.withUnsafeBytes { Data($0) })

        let receiptJSON = #"{"data":{"seens":[{"idTo":"u123"}],"delivereds":[{"idTo":"u456"}]}}"#
        let encryptedB64 = try encryptGCM(plaintext: Data(receiptJSON.utf8), key: key)
        let frame = makeFrame(version: 1, cmd: 502, subCmd: 0, jsonObject: makeEnvelope(encrypt: 3, data: encryptedB64))

        let events = decoder.decode(frame: frame)
        #expect(events == [
            .seenOrDelivered(conversationId: "u123", isGroup: false, isSeen: true),
            .seenOrDelivered(conversationId: "u456", isGroup: false, isSeen: false),
        ])
    }

    // MARK: - Helpers

    private func makeFrame(version: UInt8, cmd: UInt16, subCmd: UInt8, json: String) -> Data {
        var data = Data([version, UInt8(cmd & 0xFF), UInt8((cmd >> 8) & 0xFF), subCmd])
        data.append(Data(json.utf8))
        return data
    }

    private func makeFrame(version: UInt8, cmd: UInt16, subCmd: UInt8, jsonObject: [String: Any]) -> Data {
        let jsonData = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data()
        var data = Data([version, UInt8(cmd & 0xFF), UInt8((cmd >> 8) & 0xFF), subCmd])
        data.append(jsonData)
        return data
    }

    private func makeEnvelope(encrypt: Int, data: String) -> [String: Any] {
        ["encrypt": encrypt, "data": data]
    }

    private func encryptGCM(plaintext: Data, key: SymmetricKey) throws -> String {
        let iv = Data((0..<16).map { UInt8($0 + 1) })
        let aad = Data((0..<16).map { UInt8($0 + 17) })
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var combined = Data()
        combined.append(iv)
        combined.append(aad)
        combined.append(sealed.ciphertext)
        combined.append(sealed.tag)
        return combined.base64EncodedString()
    }

    private func zlibWrap(_ raw: Data) throws -> Data {
        let capacity = max(1024, raw.count * 2)
        var deflateBuf = Data(count: capacity)
        let encodedCount = deflateBuf.withUnsafeMutableBytes { dstPtr in
            raw.withUnsafeBytes { srcPtr in
                compression_encode_buffer(
                    dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    raw.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        #expect(encodedCount > 0)
        deflateBuf.count = encodedCount

        var wrapped = Data([0x78, 0x9C])
        wrapped.append(deflateBuf)
        // Minimal 4-byte placeholder trailer (Adler32) as pako.deflate produces.
        wrapped.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        return wrapped
    }
}
