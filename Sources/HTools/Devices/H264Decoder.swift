import AVFoundation
import CoreMedia
import Foundation

/// 把 `screenrecord --output-format=h264` 输出的 Annex-B 字节流解码并显示到
/// `AVSampleBufferDisplayLayer`（系统用 VideoToolbox 硬解），不依赖 scrcpy / ffmpeg。
///
/// 所有状态都只在内部串行队列上访问；`feed` 可以从任意线程调用。
final class H264Decoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mino.htools.h264")
    private let layer: AVSampleBufferDisplayLayer
    private let onFirstFrame: @Sendable () -> Void

    private var buffer: [UInt8] = []
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var needsKeyFrame = true
    private var didReportFirstFrame = false
    private var idleFlush: DispatchWorkItem?

    init(layer: AVSampleBufferDisplayLayer, onFirstFrame: @escaping @Sendable () -> Void) {
        self.layer = layer
        self.onFirstFrame = onFirstFrame
    }

    func feed(_ data: Data) {
        queue.async { [self] in
            buffer.append(contentsOf: data)
            drain(includeTail: false)
            scheduleIdleFlush()
        }
    }

    /// 重新开始一路流（例如 screenrecord 到 3 分钟上限自动结束后重启）。
    func reset() {
        queue.async { [self] in
            idleFlush?.cancel()
            buffer.removeAll()
            sps = nil
            pps = nil
            format = nil
            needsKeyFrame = true
        }
    }

    // MARK: - 切分 NAL

    /// 静止画面时 screenrecord 不会再输出数据，最后一个 NAL 后面也就没有下一个起始码来标记结束。
    /// 一小段时间没有新数据就把缓冲里剩下的当作完整 NAL 处理，避免最后一帧一直卡在缓冲区里。
    private func scheduleIdleFlush() {
        idleFlush?.cancel()
        let work = DispatchWorkItem { [self] in drain(includeTail: true) }
        idleFlush = work
        queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: work)
    }

    private func drain(includeTail: Bool) {
        let count = buffer.count
        var starts: [Int] = []
        var i = 0
        while i + 2 < count {
            let third = buffer[i + 2]
            if third > 1 {
                i += 3
            } else if third == 1 {
                if buffer[i] == 0 && buffer[i + 1] == 0 { starts.append(i) }
                i += 3
            } else {
                i += 1
            }
        }

        for (index, start) in starts.enumerated() {
            let isLast = index == starts.count - 1
            if isLast && !includeTail { break }

            let begin = start + 3
            var end = isLast ? count : starts[index + 1]
            // NAL 末尾不会是 0x00（RBSP 结尾位保证），多出来的零属于下一个 4 字节起始码。
            while end > begin && buffer[end - 1] == 0 { end -= 1 }
            if end > begin { handle(buffer[begin..<end]) }
        }

        if includeTail {
            buffer.removeAll()
        } else if let last = starts.last {
            buffer.removeSubrange(0..<last)
        } else if count > 2 {
            // 没有起始码：只保留末尾 2 字节，防止起始码被切在两次读取之间。
            buffer.removeSubrange(0..<(count - 2))
        }
    }

    // MARK: - 解码

    private func handle(_ nal: ArraySlice<UInt8>) {
        guard let header = nal.first else { return }
        switch header & 0x1F {
        case 7:
            let value = Array(nal)
            if sps != value { sps = value; format = nil }
        case 8:
            let value = Array(nal)
            if pps != value { pps = value; format = nil }
        case 5:
            if enqueue(nal, isKeyFrame: true) { needsKeyFrame = false }
        case 1:
            if !needsKeyFrame { _ = enqueue(nal, isKeyFrame: false) }
        default:
            break
        }
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        guard let sps, let pps else { return nil }
        var description: CMFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                guard let sBase = s.baseAddress, let pBase = p.baseAddress else { return }
                let pointers = [sBase, pBase]
                let sizes = [s.count, p.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return description
    }

    private func enqueue(_ nal: ArraySlice<UInt8>, isKeyFrame: Bool) -> Bool {
        if format == nil { format = makeFormat() }
        guard let format else { return false }

        if layer.sampleBufferRenderer.status == .failed {
            layer.sampleBufferRenderer.flush()
            needsKeyFrame = true
            if !isKeyFrame { return false }
        }

        // Annex-B -> AVCC：起始码换成 4 字节大端长度前缀。
        var length = UInt32(nal.count).bigEndian
        var avcc = Data(bytes: &length, count: 4)
        avcc.append(contentsOf: nal)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return false }

        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return false }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return false }

        // 实时画面：收到就显示，不按时间戳排队。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        layer.sampleBufferRenderer.enqueue(sample)

        if !didReportFirstFrame {
            didReportFirstFrame = true
            onFirstFrame()
        }
        return true
    }
}
