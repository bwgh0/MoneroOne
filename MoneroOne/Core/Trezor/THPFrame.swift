import Foundation
import zlib

// MARK: - THP Control Byte

/// THP L2 control byte encoding.
///
/// Bit layout for data messages (handshake/encrypted):
///   `[7] continuation | [6:5] 00 | [4] seq_bit | [3] ack_seq_bit | [2:0] message_type`
///
/// Fixed control bytes for special messages:
///   `0x20` / `0x28` = ACK (bit 3 = ack seq bit)
///   `0x40` = Channel allocation request
///   `0x41` = Channel allocation response
///   `0x80` = Continuation packet
struct THPControlByte {
    /// Data message types (bits [2:0])
    enum DataType: UInt8 {
        case handshakeInitReq  = 0x00
        case handshakeInitResp = 0x01
        case handshakeCompReq  = 0x02
        case handshakeCompResp = 0x03
        case encrypted         = 0x04
    }

    /// Fixed control byte values (no bit fields)
    static let channelAllocReq: UInt8  = 0x40
    static let channelAllocResp: UInt8 = 0x41
    static let continuation: UInt8     = 0x80

    let rawValue: UInt8

    /// Is this a continuation packet?
    var isContinuation: Bool { (rawValue & 0x80) != 0 }

    /// Is this an ACK message? Pattern: 0010X000
    var isACK: Bool { (rawValue & 0xF7) == 0x20 }

    /// Is this a data message (handshake or encrypted)? Top 3 bits = 000
    var isDataMessage: Bool { (rawValue & 0xE0) == 0x00 }

    /// Data message type (bits [2:0]), only valid for data messages
    var dataType: UInt8 { rawValue & 0x07 }

    /// Sequence bit (bit 4) — for data messages
    var seqBit: Bool { (rawValue & 0x10) != 0 }

    /// ACK sequence bit (bit 3) — for data messages or ACK messages
    var ackSeqBit: Bool { (rawValue & 0x08) != 0 }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Build a data message control byte (handshake or encrypted)
    init(dataType: DataType, seq: Bool, ackSeq: Bool) {
        var byte = dataType.rawValue
        if seq { byte |= 0x10 }
        if ackSeq { byte |= 0x08 }
        self.rawValue = byte
    }

    /// Build an ACK control byte
    static func ack(seqBit: Bool) -> THPControlByte {
        THPControlByte(rawValue: seqBit ? 0x28 : 0x20)
    }
}

// MARK: - THP Frame

/// THP L2 frame encoding/decoding.
///
/// Init packet:  `[ctrl(1)][CID(2 BE)][length(2 BE)][payload(N)][CRC32(4)][padding]`
/// Cont packet:  `[0x80(1)][CID(2 BE)][payload(N)][padding]`
///
/// `length` = transport_payload_size + 4 (includes CRC, excludes header & padding)
enum THPFrame {

    /// Broadcast channel ID used for channel allocation
    static let broadcastCID: UInt16 = 0xFFFF

    /// BLE packet size (fixed)
    static let chunkSize = 244

    /// Init packet header: control(1) + CID(2) + length(2) = 5
    static let headerSize = 5

    /// CRC32 size
    static let crcSize = 4

    /// Continuation header: control(1) + CID(2) = 3
    static let continuationHeaderSize = 3

    /// Max payload in first BLE packet (after header)
    static let firstChunkPayloadCapacity = chunkSize - headerSize  // 239

    /// Max payload in continuation BLE packet (after header)
    static let contChunkPayloadCapacity = chunkSize - continuationHeaderSize  // 241

    // MARK: - Encoding

    /// Build a complete THP frame with CRC32 and split into BLE chunks.
    ///
    /// The `length` field = payload.count + 4 (CRC included per THP spec).
    /// CRC32 is computed over: control_byte + CID + length + payload.
    static func encodeMultiChunk(controlByte: UInt8, cid: UInt16, payload: Data) -> [Data] {
        // Build header: control + CID(BE) + length(BE)
        var header = Data()
        header.append(controlByte)
        header.append(UInt8(cid >> 8))
        header.append(UInt8(cid & 0xFF))

        // length = payload + CRC
        let length = UInt16(payload.count + crcSize)
        header.append(UInt8(length >> 8))
        header.append(UInt8(length & 0xFF))

        // CRC32 over header + payload (not over CRC itself, not over padding)
        var checksumInput = header
        checksumInput.append(payload)
        let crc = crc32Checksum(checksumInput)

        // Full frame data: header + payload + CRC
        var frameData = checksumInput
        frameData.append(UInt8((crc >> 24) & 0xFF))
        frameData.append(UInt8((crc >> 16) & 0xFF))
        frameData.append(UInt8((crc >> 8) & 0xFF))
        frameData.append(UInt8(crc & 0xFF))

        // Split into BLE chunks
        return splitIntoChunks(frameData, cid: cid)
    }

    /// Split frame data into padded BLE-sized chunks.
    private static func splitIntoChunks(_ frame: Data, cid: UInt16) -> [Data] {
        var chunks: [Data] = []

        // First chunk: up to chunkSize bytes of frame data
        let firstEnd = min(frame.count, chunkSize)
        var firstChunk = Data(frame.prefix(firstEnd))
        // Pad to chunk size
        if firstChunk.count < chunkSize {
            firstChunk.append(Data(repeating: 0, count: chunkSize - firstChunk.count))
        }
        chunks.append(firstChunk)

        // Continuation chunks for remaining data
        var offset = firstEnd
        while offset < frame.count {
            var chunk = Data()
            // Continuation header
            chunk.append(Self.continuation)
            chunk.append(UInt8(cid >> 8))
            chunk.append(UInt8(cid & 0xFF))

            // Payload portion
            let remaining = frame.count - offset
            let payloadSize = min(remaining, contChunkPayloadCapacity)
            chunk.append(frame.subdata(in: offset..<(offset + payloadSize)))

            // Pad to chunk size
            if chunk.count < chunkSize {
                chunk.append(Data(repeating: 0, count: chunkSize - chunk.count))
            }

            chunks.append(chunk)
            offset += payloadSize
        }

        return chunks
    }

    /// Continuation control byte constant
    private static let continuation: UInt8 = 0x80

    // MARK: - Decoding

    /// Decoded THP frame
    struct DecodedFrame {
        let controlByte: THPControlByte
        let cid: UInt16
        let payload: Data  // transport payload (excluding CRC)
    }

    /// Decode a complete THP frame (after reassembly from chunks).
    /// Validates CRC32 and extracts payload.
    static func decode(data: Data) throws -> DecodedFrame {
        guard data.count >= headerSize + crcSize else {
            throw THPFrameError.frameTooShort
        }

        let controlByte = THPControlByte(rawValue: data[0])
        let cid = UInt16(data[1]) << 8 | UInt16(data[2])
        let lengthField = Int(UInt16(data[3]) << 8 | UInt16(data[4]))

        // length field includes CRC (4 bytes)
        let payloadLength = lengthField - crcSize
        guard payloadLength >= 0 else {
            throw THPFrameError.payloadLengthMismatch
        }

        let totalFrameSize = headerSize + payloadLength + crcSize
        guard data.count >= totalFrameSize else {
            throw THPFrameError.frameTooShort
        }

        // Extract and verify CRC
        let crcOffset = headerSize + payloadLength
        let receivedCRC = UInt32(data[crcOffset]) << 24
            | UInt32(data[crcOffset + 1]) << 16
            | UInt32(data[crcOffset + 2]) << 8
            | UInt32(data[crcOffset + 3])

        // CRC covers header + payload (not the CRC itself)
        let checksumInput = data.prefix(crcOffset)
        let computedCRC = crc32Checksum(Data(checksumInput))
        guard computedCRC == receivedCRC else {
            throw THPFrameError.crcMismatch(expected: computedCRC, received: receivedCRC)
        }

        let payload = payloadLength > 0
            ? data.subdata(in: headerSize..<(headerSize + payloadLength))
            : Data()

        return DecodedFrame(controlByte: controlByte, cid: cid, payload: payload)
    }

    /// Reassemble a complete frame from multiple BLE chunks.
    /// First chunk has 5-byte header; continuation chunks have 3-byte headers.
    static func reassemble(chunks: [Data]) throws -> Data {
        guard let first = chunks.first, first.count >= headerSize else {
            throw THPFrameError.frameTooShort
        }

        // length field includes CRC
        let lengthField = Int(UInt16(first[3]) << 8 | UInt16(first[4]))
        let totalFrameSize = headerSize + lengthField  // header + payload + CRC

        // Start with the first chunk (strip padding)
        var assembled = Data()
        let firstUseful = min(first.count, totalFrameSize)
        assembled.append(first.prefix(firstUseful))

        // Append continuation chunk payloads
        for chunk in chunks.dropFirst() {
            guard chunk.count >= continuationHeaderSize else { continue }

            let remaining = totalFrameSize - assembled.count
            if remaining <= 0 { break }

            let usefulBytes = min(chunk.count - continuationHeaderSize, remaining)
            assembled.append(chunk.subdata(in: continuationHeaderSize..<(continuationHeaderSize + usefulBytes)))
        }

        return assembled
    }

    /// Check if a chunk is a continuation chunk (bit 7 set)
    static func isContinuation(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return false }
        return (chunk[0] & 0x80) != 0
    }

    /// Extract CID from any chunk (bytes 1-2)
    static func extractCID(_ chunk: Data) -> UInt16? {
        guard chunk.count >= 3 else { return nil }
        return UInt16(chunk[1]) << 8 | UInt16(chunk[2])
    }

    // MARK: - CRC32

    /// Compute CRC32 using zlib (standard CRC-32-IEEE)
    static func crc32Checksum(_ data: Data) -> UInt32 {
        let bytes = [UInt8](data)
        let result = bytes.withUnsafeBufferPointer { bufferPointer -> UInt32 in
            let crc = zlib.crc32(0, bufferPointer.baseAddress, uInt(bufferPointer.count))
            return UInt32(crc)
        }
        return result
    }
}

// MARK: - Errors

enum THPFrameError: LocalizedError {
    case frameTooShort
    case crcMismatch(expected: UInt32, received: UInt32)
    case payloadLengthMismatch

    var errorDescription: String? {
        switch self {
        case .frameTooShort:
            return "THP frame too short"
        case .crcMismatch(let expected, let received):
            return "THP CRC32 mismatch: expected \(String(format: "%08x", expected)), received \(String(format: "%08x", received))"
        case .payloadLengthMismatch:
            return "THP payload length mismatch"
        }
    }
}
