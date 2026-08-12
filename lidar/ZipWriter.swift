//
//  ZipWriter.swift
//  lidar
//

import Foundation

enum ZipWriter {
    struct Entry {
        let filename: String
        let data: Data
    }

    /// Builds an uncompressed (store-method) ZIP archive.
    static func makeArchive(entries: [Entry]) -> Data {
        var localFiles = Data()
        var centralDirectory = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            let nameData = Data(entry.filename.utf8)
            let offset = UInt32(localFiles.count)
            offsets.append(offset)

            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            // Local file header
            localFiles.appendUInt32(0x04034b50) // signature
            localFiles.appendUInt16(20) // version needed
            localFiles.appendUInt16(0) // flags
            localFiles.appendUInt16(0) // compression: store
            localFiles.appendUInt16(0) // mod time
            localFiles.appendUInt16(0) // mod date
            localFiles.appendUInt32(crc)
            localFiles.appendUInt32(size)
            localFiles.appendUInt32(size)
            localFiles.appendUInt16(UInt16(nameData.count))
            localFiles.appendUInt16(0) // extra length
            localFiles.append(nameData)
            localFiles.append(entry.data)

            // Central directory header
            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20) // version made by
            centralDirectory.appendUInt16(20) // version needed
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt16(UInt16(nameData.count))
            centralDirectory.appendUInt16(0) // extra
            centralDirectory.appendUInt16(0) // comment
            centralDirectory.appendUInt16(0) // disk start
            centralDirectory.appendUInt16(0) // int attrs
            centralDirectory.appendUInt32(0) // ext attrs
            centralDirectory.appendUInt32(offset)
            centralDirectory.append(nameData)
        }

        let centralOffset = UInt32(localFiles.count)
        let centralSize = UInt32(centralDirectory.count)
        var end = Data()
        end.appendUInt32(0x06054b50)
        end.appendUInt16(0) // disk number
        end.appendUInt16(0) // start disk
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(centralSize)
        end.appendUInt32(centralOffset)
        end.appendUInt16(0) // comment length

        var archive = Data()
        archive.reserveCapacity(localFiles.count + centralDirectory.count + end.count)
        archive.append(localFiles)
        archive.append(centralDirectory)
        archive.append(end)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
