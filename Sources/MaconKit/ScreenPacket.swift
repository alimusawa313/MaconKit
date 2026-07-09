//
//  ScreenPacket.swift
//  MaconKit
//
//  Serializes a VideoToolbox-encoded H.264 sample into the wire packet the
//  companion app expects. Kept here (not in the app) so it can be unit-tested
//  against real encoder output.
//
//  Layout (big-endian lengths):
//    [1] flags  bit0 = keyframe
//    if keyframe: [1] paramSetCount [2] len [set] … (SPS then PPS)
//    [4] sampleLen [AVCC sample data]
//

import Foundation
import CoreMedia

public enum ScreenPacket {

    /// Encode one compressed sample. Returns nil if the sample has no data.
    public static func encode(from sample: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length > 0 else { return nil }

        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        var packet = Data()
        packet.append(keyframe ? 1 : 0)

        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var sets: [(ptr: UnsafePointer<UInt8>, size: Int)] = []
            for index in 0..<2 {
                var setPtr: UnsafePointer<UInt8>?
                var setSize = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &setPtr,
                    parameterSetSizeOut: &setSize, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let setPtr {
                    sets.append((setPtr, setSize))
                }
            }
            packet.append(UInt8(sets.count))
            for set in sets {
                appendUInt16(&packet, UInt16(set.size))
                packet.append(set.ptr, count: set.size)
            }
        }

        appendUInt32(&packet, UInt32(length))
        pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            packet.append($0, count: length)
        }
        return packet
    }

    static func appendUInt16(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF))
    }
    static func appendUInt32(_ data: inout Data, _ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((v >> shift) & 0xFF)) }
    }
}
