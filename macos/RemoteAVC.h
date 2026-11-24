// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#import <VideoToolbox/VideoToolbox.h>

#include <cstdint>
#include <span>
#include <vector>

inline size_t annexBPrefixLength(std::span<const uint8_t> bytes) {
    if (bytes.size() < 3 || bytes[0] || bytes[1]) return 0;
    if (bytes[2] == 1) return 3;
    return bytes.size() >= 4 && bytes[2] == 0 && bytes[3] == 1 ? 4 : 0;
}

template<class Consume>
void forEachAnnexBNal(std::span<const uint8_t> bytes, Consume consume) {
    size_t begin = annexBPrefixLength(bytes);
    while (begin < bytes.size()) {
        size_t end = begin + 1;
        while (end < bytes.size() && !annexBPrefixLength(bytes.subspan(end))) ++end;
        consume(bytes.subspan(begin, end - begin));
        begin = end + annexBPrefixLength(bytes.subspan(end));
    }
}

inline void appendLengthPrefixedNAL(std::vector<uint8_t>& sample, std::span<const uint8_t> nal) {
    const uint32_t prefix = CFSwapInt32HostToBig(static_cast<uint32_t>(nal.size()));
    const auto *bytes = reinterpret_cast<const uint8_t *>(&prefix);
    sample.insert(sample.end(), bytes, bytes + sizeof(prefix));
    sample.insert(sample.end(), nal.begin(), nal.end());
}

class RemoteAVCDecoder {
public:
    RemoteAVCDecoder() = default;
    RemoteAVCDecoder(const RemoteAVCDecoder&) = delete;
    RemoteAVCDecoder& operator=(const RemoteAVCDecoder&) = delete;
    ~RemoteAVCDecoder() { reset(); }

    bool configure(std::span<const uint8_t> sps, std::span<const uint8_t> pps, VTDecompressionOutputCallbackRecord callback) {
        const uint8_t *sets[]{sps.data(), pps.data()};
        const size_t sizes[]{sps.size(), pps.size()};
        CMVideoFormatDescriptionRef format = nullptr;
        if (CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr, 2, sets, sizes, 4, &format)) return false;
        if (session_ && CMFormatDescriptionEqual(format, format_)) {
            CFRelease(format);
            return true;
        }
        reset();
        NSDictionary *attributes = @{
            (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        if (VTDecompressionSessionCreate(nullptr, format, nullptr, (__bridge CFDictionaryRef)attributes, &callback, &session_)) {
            CFRelease(format);
            return false;
        }
        format_ = format;
        return true;
    }

    bool decode(std::span<const uint8_t> bytes, CMTime pts) {
        if (!session_ || bytes.empty()) return false;
        CMBlockBufferRef block = nullptr;
        if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, bytes.size(), kCFAllocatorDefault, nullptr, 0,
            bytes.size(), 0, &block)) return false;
        OSStatus status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size());
        const CMSampleTimingInfo timing{kCMTimeInvalid, pts, kCMTimeInvalid};
        CMSampleBufferRef buffer = nullptr;
        size_t count = bytes.size();
        if (!status) status = CMSampleBufferCreateReady(nullptr, block, format_, 1, 1, &timing, 1, &count, &buffer);
        CFRelease(block);
        if (status) return false;
        status = VTDecompressionSessionDecodeFrame(session_, buffer, kVTDecodeFrame_EnableAsynchronousDecompression, nullptr, nullptr);
        CFRelease(buffer);
        return status == noErr;
    }

    void reset() {
        if (session_) {
            VTDecompressionSessionWaitForAsynchronousFrames(session_);
            VTDecompressionSessionInvalidate(session_);
            CFRelease(session_);
            session_ = nullptr;
        }
        if (format_) { CFRelease(format_); format_ = nullptr; }
    }

private:
    VTDecompressionSessionRef session_ = nullptr;
    CMVideoFormatDescriptionRef format_ = nullptr;
};
