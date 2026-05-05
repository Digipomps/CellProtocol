// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

#if canImport(Compression)
import Compression
#endif

enum FileCryptoCompressionError: Error {
    case compressionFailed
    case decompressionFailed
    case compressionUnavailable
}

enum FileCryptoCompression {
    static func compress(_ data: Data, algorithm: FileCryptoCompressionAlgorithm) throws -> Data {
#if canImport(Compression)
        switch algorithm {
        case .none:
            return data
        case .zlib:
            return try process(data, operation: COMPRESSION_STREAM_ENCODE, algorithm: COMPRESSION_ZLIB)
        }
#else
        switch algorithm {
        case .none:
            return data
        case .zlib:
            throw FileCryptoCompressionError.compressionUnavailable
        }
#endif
    }

    static func decompress(
        _ data: Data,
        algorithm: FileCryptoCompressionAlgorithm,
        expectedByteCount: Int? = nil
    ) throws -> Data {
#if canImport(Compression)
        let output: Data
        switch algorithm {
        case .none:
            output = data
        case .zlib:
            output = try process(data, operation: COMPRESSION_STREAM_DECODE, algorithm: COMPRESSION_ZLIB)
        }

        if let expectedByteCount, output.count != expectedByteCount {
            throw FileCryptoCompressionError.decompressionFailed
        }
        return output
#else
        let output: Data
        switch algorithm {
        case .none:
            output = data
        case .zlib:
            throw FileCryptoCompressionError.compressionUnavailable
        }

        if let expectedByteCount, output.count != expectedByteCount {
            throw FileCryptoCompressionError.decompressionFailed
        }
        return output
#endif
    }

#if canImport(Compression)
    private static func process(
        _ data: Data,
        operation: compression_stream_operation,
        algorithm: compression_algorithm
    ) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        let destinationBufferSize = 64 * 1024
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destinationBuffer.deallocate() }

        let bootstrapPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { bootstrapPointer.deallocate() }

        var stream = compression_stream(
            dst_ptr: bootstrapPointer,
            dst_size: 0,
            src_ptr: UnsafePointer(bootstrapPointer),
            src_size: 0,
            state: nil
        )
        let streamStatus = compression_stream_init(&stream, operation, algorithm)
        guard streamStatus != COMPRESSION_STATUS_ERROR else {
            throw operation == COMPRESSION_STREAM_ENCODE
                ? FileCryptoCompressionError.compressionFailed
                : FileCryptoCompressionError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        return try data.withUnsafeBytes { rawBuffer in
            guard let sourcePointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Data()
            }

            stream.src_ptr = sourcePointer
            stream.src_size = data.count

            var output = Data()
            let flags = operation == COMPRESSION_STREAM_ENCODE
                ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                : 0

            while true {
                stream.dst_ptr = destinationBuffer
                stream.dst_size = destinationBufferSize

                let status = compression_stream_process(&stream, flags)
                let producedCount = destinationBufferSize - stream.dst_size
                if producedCount > 0 {
                    output.append(destinationBuffer, count: producedCount)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    throw operation == COMPRESSION_STREAM_ENCODE
                        ? FileCryptoCompressionError.compressionFailed
                        : FileCryptoCompressionError.decompressionFailed
                }
            }
        }
    }
#endif
}
