// QuotaLens 高性能分块流式 JSONL 读取器
// 从指定字节偏移量开始读取，按换行完整切分，保证内存恒定 (O(chunkSize))

import Foundation
import Darwin

public struct JSONLLineRecord: Sendable {
    public let lineIndex: Int
    public let startOffset: Int64
    public let lineBytes: Int
    public let lineString: String

    public init(lineIndex: Int, startOffset: Int64, lineBytes: Int, lineString: String) {
        self.lineIndex = lineIndex
        self.startOffset = startOffset
        self.lineBytes = lineBytes
        self.lineString = lineString
    }
}

public final class StreamingJSONLReader: Sendable {
    public static let defaultChunkSize = 1024 * 1024 // 1 MB

    public init() {}

    /// 流式逐行读取文件从 startOffset 到 endLimitOffset 的完整行
    public static func readLines(
        fileURL: URL,
        startOffset: Int64 = 0,
        endLimitOffset: Int64? = nil,
        chunkSize: Int = defaultChunkSize,
        discardIrrelevantAfterPrefixBytes: Int = .max,
        shouldIncludeLineData: ((Data.SubSequence) -> Bool)? = nil,
        onLine: (JSONLLineRecord) throws -> Void
    ) throws -> (finalOffset: Int64, totalLinesRead: Int) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw NSError(
                domain: "QuotaLens.StreamingReader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法以只读方式打开文件: \(fileURL.lastPathComponent)"]
            )
        }
        defer { try? fileHandle.close() }

        var statBuf = stat()
        let status = stat((fileURL.path as NSString).fileSystemRepresentation, &statBuf)
        guard status == 0 else {
            throw NSError(
                domain: "QuotaLens.StreamingReader",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "无法读取文件大小: \(fileURL.lastPathComponent)"]
            )
        }
        let fileSize = Int64(statBuf.st_size)
        let targetEndOffset = min(fileSize, endLimitOffset ?? fileSize)
        guard startOffset < targetEndOffset else {
            return (startOffset, 0)
        }

        try fileHandle.seek(toOffset: UInt64(startOffset))

        var currentOffset = startOffset
        var pendingLine = Data()
        pendingLine.reserveCapacity(min(chunkSize, 64 * 1024))
        var lineStartOffset = startOffset
        var isDiscardingIrrelevantLine = false
        var lineIndex = 0
        var totalLinesRead = 0

        func shouldKeepLine(_ lineData: Data) -> Bool {
            guard let shouldIncludeLineData else { return true }
            return shouldIncludeLineData(lineData[lineData.startIndex..<lineData.endIndex])
        }

        func relieveAllocatorPressure() {
            #if os(macOS)
            _ = malloc_zone_pressure_relief(nil, 0)
            #endif
        }

        func maybeStartDiscardingIrrelevantLine() {
            guard let shouldIncludeLineData,
                  !isDiscardingIrrelevantLine,
                  pendingLine.count >= discardIrrelevantAfterPrefixBytes else {
                return
            }

            let prefixEnd = pendingLine.index(
                pendingLine.startIndex,
                offsetBy: min(pendingLine.count, discardIrrelevantAfterPrefixBytes)
            )
            if !shouldIncludeLineData(pendingLine[pendingLine.startIndex..<prefixEnd]) {
                pendingLine.removeAll(keepingCapacity: false)
                relieveAllocatorPressure()
                isDiscardingIrrelevantLine = true
            }
        }

        func processCompleteLine(_ lineData: Data, startOffset: Int64, lineBytes: Int) throws {
            guard shouldKeepLine(lineData) else { return }
            guard let lineStr = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\r")),
                  !lineStr.isEmpty else {
                return
            }

            let record = JSONLLineRecord(
                lineIndex: lineIndex,
                startOffset: startOffset,
                lineBytes: lineBytes,
                lineString: lineStr
            )
            try autoreleasepool {
                try onLine(record)
            }
            totalLinesRead += 1
        }

        while currentOffset < targetEndOffset {
            let bytesToRead = min(Int64(chunkSize), targetEndOffset - currentOffset)
            guard bytesToRead > 0 else { break }

            let chunkStartOffset = currentOffset
            let chunk = fileHandle.readData(ofLength: Int(bytesToRead))
            guard !chunk.isEmpty else { break }

            currentOffset += Int64(chunk.count)

            // 按换行符切分完整行。默认必须扫描到行尾后再判定事件类型，
            // 因为合法 JSON 可以把 `type` 放在 4 KB 甚至 1 MB 之后。
            var chunkCursor = chunk.startIndex
            while let newlineIndex = chunk[chunkCursor..<chunk.endIndex].firstIndex(of: 0x0A) { // '\n'
                let segment = chunk[chunkCursor..<newlineIndex]
                let newlineDistance = chunk.distance(from: chunk.startIndex, to: newlineIndex)
                let newlineOffset = chunkStartOffset + Int64(newlineDistance)
                let fullLineBytes = Int(newlineOffset - lineStartOffset) + 1

                if !isDiscardingIrrelevantLine {
                    pendingLine.append(contentsOf: segment)
                    try processCompleteLine(pendingLine, startOffset: lineStartOffset, lineBytes: fullLineBytes)
                }

                pendingLine.removeAll(keepingCapacity: false)
                if fullLineBytes >= discardIrrelevantAfterPrefixBytes {
                    relieveAllocatorPressure()
                }
                isDiscardingIrrelevantLine = false
                lineIndex += 1
                chunkCursor = chunk.index(after: newlineIndex)

                let nextDistance = chunk.distance(from: chunk.startIndex, to: chunkCursor)
                lineStartOffset = chunkStartOffset + Int64(nextDistance)
            }

            if chunkCursor < chunk.endIndex {
                if !isDiscardingIrrelevantLine {
                    pendingLine.append(contentsOf: chunk[chunkCursor..<chunk.endIndex])
                    maybeStartDiscardingIrrelevantLine()
                }
            }
        }

        // EOF 处可能有一条完整 JSON 但没有换行。只有能被 JSON 解析时才提交；
        // 否则保留偏移，等待后续追加补齐这条半截记录。
        if isDiscardingIrrelevantLine {
            return (currentOffset, totalLinesRead)
        }

        if !pendingLine.isEmpty,
           currentOffset == targetEndOffset {
            if !shouldKeepLine(pendingLine) {
                return (currentOffset, totalLinesRead)
            }
            guard let lineStr = String(data: pendingLine, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\r")),
                  !lineStr.isEmpty,
                  let lineData = lineStr.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: lineData)) != nil else {
                let consumedEndOffset = currentOffset - Int64(pendingLine.count)
                return (consumedEndOffset, totalLinesRead)
            }
            let record = JSONLLineRecord(
                lineIndex: lineIndex,
                startOffset: lineStartOffset,
                lineBytes: pendingLine.count,
                lineString: lineStr
            )
            try autoreleasepool {
                try onLine(record)
            }
            totalLinesRead += 1
            return (currentOffset, totalLinesRead)
        }

        // 计算已消耗的完整字节终点（回退未结束的尾部残留）
        let consumedEndOffset = currentOffset - Int64(pendingLine.count)
        return (consumedEndOffset, totalLinesRead)
    }
}
