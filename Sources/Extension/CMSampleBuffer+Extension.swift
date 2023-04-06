import Accelerate
import CoreMedia
import AVFoundation
import ReplayKit

extension CMSampleBuffer {
    var isNotSync: Bool {
        get {
            getAttachmentValue(for: kCMSampleAttachmentKey_NotSync) ?? false
        }
        set {
            setAttachmentValue(for: kCMSampleAttachmentKey_NotSync, value: newValue)
        }
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var isValid: Bool {
        CMSampleBufferIsValid(self)
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var dataBuffer: CMBlockBuffer? {
        get {
            CMSampleBufferGetDataBuffer(self)
        }
        set {
            _ = newValue.map {
                CMSampleBufferSetDataBuffer(self, newValue: $0)
            }
        }
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var imageBuffer: CVImageBuffer? {
        CMSampleBufferGetImageBuffer(self)
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var numSamples: CMItemCount {
        CMSampleBufferGetNumSamples(self)
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var duration: CMTime {
        CMSampleBufferGetDuration(self)
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var formatDescription: CMFormatDescription? {
        CMSampleBufferGetFormatDescription(self)
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var decodeTimeStamp: CMTime {
        CMSampleBufferGetDecodeTimeStamp(self)
    }

    @available(iOS, obsoleted: 13.0)
    @available(tvOS, obsoleted: 13.0)
    @available(macOS, obsoleted: 10.15)
    var presentationTimeStamp: CMTime {
        CMSampleBufferGetPresentationTimeStamp(self)
    }

    func muted(_ muted: Bool) -> CMSampleBuffer? {
        guard muted else {
            return self
        }
        guard let dataBuffer = dataBuffer else {
            return nil
        }
        let status = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: dataBuffer,
            offsetIntoDestination: 0,
            dataLength: dataBuffer.dataLength
        )
        guard status == noErr else {
            return nil
        }
        return self
    }

    // swiftlint:disable discouraged_optional_boolean
    @inline(__always)
    private func getAttachmentValue(for key: CFString) -> Bool? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
            let value = attachments.first?[key] as? Bool else {
            return nil
        }
        return value
    }

    @inline(__always)
    private func setAttachmentValue(for key: CFString, value: Bool) {
        guard
            let attachments: CFArray = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true), 0 < CFArrayGetCount(attachments) else {
            return
        }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
        )
    }
    
    public func toStandardPCMBuffer(channels: AVAudioChannelCount) -> AVAudioPCMBuffer? {
        guard let sourceFormat = CMSampleBufferGetFormatDescription(self) else {
            return nil
        }
        let fmtType = CMFormatDescriptionGetMediaSubType(sourceFormat)
        if fmtType != kAudioFormatLinearPCM {
        }
        let frameCount = CMSampleBufferGetNumSamples(self)
        let fromFormat = AVAudioFormat(cmAudioFormatDescription: sourceFormat)
        guard let toFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: fromFormat.sampleRate,
                                           channels: channels,
                                           interleaved: false)
        else {
            return nil
        }
       
       guard frameCount > 0, let tmpBuffer = AVAudioPCMBuffer(pcmFormat: fromFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
           return nil
       }
       tmpBuffer.frameLength = tmpBuffer.frameCapacity
       let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frameCount), into: tmpBuffer.mutableAudioBufferList)
       if status != noErr {
           return nil
       }
       guard let outBuffer = AVAudioPCMBuffer(pcmFormat: toFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
           return nil
       }
        outBuffer.frameLength = outBuffer.frameCapacity
       guard let converter = AVAudioConverter(from: fromFormat, to: toFormat) else {
           return nil
       }
       do {
           try converter.convert(to: outBuffer, from: tmpBuffer)
       } catch {
           return nil
       }
       return outBuffer
   }
}


extension AVAudioPCMBuffer {
    
    public func toStandardSampleBuffer(pts: CMTime? = nil) -> CMSampleBuffer? {
        let channels = UInt32(format.channelCount)
        
        guard let convertFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: format.sampleRate,
                                                channels: channels,
                                                interleaved: true) else {
            return nil
        }
        
        guard let converter = AVAudioConverter(from: format, to: convertFormat) else {
            return nil
        }
        guard let convertBuffer = AVAudioPCMBuffer(pcmFormat: convertFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        convertBuffer.frameLength = convertBuffer.frameCapacity
        do {
            try converter.convert(to: convertBuffer, from: self)
        } catch {
            return nil
        }
        var sampleBufferPtr: CMSampleBuffer? = nil

        let based_pts = pts ?? CMTime.zero
        let scale = Int32(format.sampleRate)
        let new_pts = CMTimeMakeWithSeconds(CMTimeGetSeconds(based_pts), preferredTimescale: scale)
        var timing = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: scale),
                                        presentationTimeStamp: new_pts,
                                        decodeTimeStamp: CMTime.invalid)

        let createStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                                dataBuffer: nil,
                                                dataReady: false,
                                                makeDataReadyCallback: nil,
                                                refcon: nil,
                                                formatDescription: convertFormat.formatDescription,
                                                sampleCount: CMItemCount(convertBuffer.frameLength),
                                                sampleTimingEntryCount: 1,
                                                sampleTimingArray: &timing,
                                                sampleSizeEntryCount: 0,
                                                sampleSizeArray: nil,
                                                sampleBufferOut: &sampleBufferPtr)
        
        guard createStatus == noErr, let sampleBuffer = sampleBufferPtr else {
            return nil
        }

        if #available(iOS 13.0, *) {

            let setBufferStatus = CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                                                 blockBufferAllocator: kCFAllocatorDefault,
                                                                                 blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                                 flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment ,
                                                                                 bufferList: convertBuffer.audioBufferList)

            guard setBufferStatus == noErr else {
                return nil
            }
        } else {
            var bbuf: CMBlockBuffer? = nil
            let dataLen:Int = Int(self.frameLength*channels*2)
            let bbCreateStatus = CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: UInt32(dataLen), flags: 0, blockBufferOut: &bbuf)
            if createStatus != noErr || bbuf == nil {
                return nil
            }
            let raw_data_buffer = convertBuffer.mutableAudioBufferList[0].mBuffers.mData
            
            let assignStatus = CMBlockBufferAppendMemoryBlock(bbuf!, memoryBlock: raw_data_buffer, length: dataLen, blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0, dataLength: dataLen, flags: 0)
            if assignStatus != noErr {
                return nil
            }

            let setBufferStatus = CMSampleBufferSetDataBuffer(sampleBuffer, newValue: bbuf!)

            if setBufferStatus != noErr {
                return nil
            }
        }
        return sampleBuffer
    }
}
