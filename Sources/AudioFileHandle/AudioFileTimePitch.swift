//
//  AudioFileTimePitch.swift
//  
//
//  Created by 韦烽传 on 2021/6/7.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import AudioFileInfo
import Print

/**
 音频文件音调
 */
open class AudioFileTimePitch: AudioUnitTimePitchProtocol {
    
    /// 队列
    public let queue: DispatchQueue
    
    /// 读取音频参数
    open internal(set) var readASBD: AudioStreamBasicDescription
    /// 写入音频参数
    open internal(set) var writeASBD: AudioStreamBasicDescription
    
    /// 读取文件信息
    public let readInfo: AudioFileReadInfo
    /// 写入文件信息
    open internal(set) var writeInfo: AudioFileWriteInfo
    
    /// 音调
    public let timePitchUnit: AudioUnitTimePitch
    /// IO `offline` = `true` `AudioUnitOutput` 否则为 `AudioUnitPlayer`
    public let ioUnit: AudioUnitComponent.AudioUnit
    
    /// 是否离线 `true` 直接处理得到文件 `false` 试听
    public let offline: Bool
    
    /// 是否在运行
    open internal(set) var isRun = false
    /// 锁
    let isRunLock = NSLock()
    
    /// 回调（进度，状态）
    open var callback: ((Float, OSStatus)->Void)? = nil
    /// 输出回调（数据，帧数）
    open var outputCallback: (([[UInt8]], UInt32)->Void)?
    
    /**
     初始化
     
     - parameter    inPath:                     输入音频文件路径
     - parameter    outPath:                    输出音频文件路径
     - parameter    offline:                    是否离线 `true` 直接处理得到文件 `false` 试听
     - parameter    readDescription:            读取音频参数（使用非交错 `kAudioFormatFlagIsNonInterleaved` 读取音频才不会-50、非交错后混音需浮点 `kAudioFormatFlagIsFloat` 否则会出现-10868）
     - parameter    writeDescription:           写入音频参数（使用交错）
     */
    public init?(_ inPath: String, outPath: String, offline: Bool, readDescription: AudioStreamBasicDescription, writeDescription: AudioStreamBasicDescription) {
        
        queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).\(Self.self).serial")
        readASBD = readDescription
        writeASBD = writeDescription
        
        self.offline = offline
        
        /// 读取文件信息
        guard let read_info = AudioFileReadInfo(inPath, converter: readASBD) else { Print.error("AudioFileReadInfo error"); return nil }
        readInfo = read_info
        
        /// 写入文件信息
        guard let write_info = AudioFileWriteInfo(outPath, basicDescription: writeASBD, converter: readASBD) else { Print.error("AudioFileWriteInfo error"); return nil }
        writeInfo = write_info
        
        /// 音调器
        guard let time_pitch_unit = AudioUnitTimePitch(readASBD) else { Print.error("AudioUnitTimePitch error"); return nil }
        timePitchUnit = time_pitch_unit
        
        /// IO器
        guard let putput_unit = offline ? AudioUnitOutput(readASBD) : AudioUnitPlayer(readASBD) else { Print.error("\(offline ? "AudioUnitOutput" : "AudioUnitPlayer") error"); return nil}
        ioUnit = putput_unit
        
        /// 连接 音调器输出（总线0） 到 IO输入（总线0）
        let status = AudioUnitComponent.AudioUnit.connection(timePitchUnit, sourceOutBus: 0, destUnit: ioUnit, destInBus: 0)
        guard status == noErr else { Print.error("AudioUnit.connection error \(status)"); return nil }
    }
    
    /**
     读取输出
     */
    func readOutput() {
        
        let info = readInfo
        
        /// 时间
        var inTimeStamp = AudioTimeStamp()
        memset(&inTimeStamp, 0, MemoryLayout.stride(ofValue: inTimeStamp))
        inTimeStamp.mFlags = .sampleTimeValid
        inTimeStamp.mSampleTime = 0
        
        /// 标识
        var ioActionFlags: AudioUnitRenderActionFlags = AudioUnitRenderActionFlags(rawValue: 0)
        /// 总线
        let inOutputBusNumber: UInt32 = 0
        /// 帧数
        var inNumberFrames: UInt32 = 512
        
        var offsetFrame: Int64 = 0
        
        callback?(0, noErr)
        
        while offsetFrame < info.frames {
            
            if (offsetFrame + Int64(inNumberFrames)) > info.frames {
                
                inNumberFrames = UInt32(info.frames - offsetFrame)
                offsetFrame = info.frames
            }
            else {
                
                offsetFrame += Int64(inNumberFrames)
            }
            
            /// 缓冲列表
            var ioData = AudioBufferList()
            ioData.mNumberBuffers = readASBD.mChannelsPerFrame
            
            /**
             创建非交错多通道需使用 `AudioBuffer` 数组
             */
            func callocAudioBuffer(_ buffer: UnsafeMutablePointer<AudioBuffer>, channels: UInt32) {
                
                for i in 0..<Int(channels) {
                    
                    var item = AudioBuffer()
                    item.mNumberChannels = 1
                    item.mDataByteSize = inNumberFrames*readASBD.mBytesPerFrame
                    item.mData = calloc(Int(item.mDataByteSize), 1)
                    
                    buffer[i] = item
                }
            }
            
            /**
             释放非交错多通道需使用 `AudioBuffer` 数组
             */
            func freeAudioBuffer(_ buffer: UnsafeMutablePointer<AudioBuffer>, channels: UInt32) {
                
                for i in 0..<Int(channels) {
                    
                    free(buffer[i].mData)
                    buffer[i].mData = nil
                }
            }
            
            /**
             获取非交错多通道数据
             */
            func bytesAudioBuffer(_ buffer: UnsafeMutablePointer<AudioBuffer>, channels: UInt32) -> [[UInt8]] {
                
                var list: [[UInt8]] = []
                
                for i in 0..<Int(channels) {
                    
                    var bytes = [UInt8].init(repeating: 0, count: Int(buffer[i].mDataByteSize))
                    memcpy(&bytes, buffer[i].mData, Int(buffer[i].mDataByteSize))
                    
                    list.append(bytes)
                }
                
                return list
            }
            
            callocAudioBuffer(&ioData.mBuffers, channels: ioData.mNumberBuffers)
            
            /// 渲染
            var status = AudioUnitRender(ioUnit.instance, &ioActionFlags, &inTimeStamp, inOutputBusNumber, inNumberFrames, &ioData)
            
            guard status == noErr else { Print.error("AudioUnitRender \(status)"); freeAudioBuffer(&ioData.mBuffers, channels: ioData.mNumberBuffers); return }
            guard inNumberFrames != 0 else { Print.error("inNumberFrames == 0"); freeAudioBuffer(&ioData.mBuffers, channels: ioData.mNumberBuffers); return }
            
            /// 写入文件
            status = ExtAudioFileWrite(writeInfo.id, inNumberFrames, &ioData)
            
            guard status == noErr else { Print.error("ExtAudioFileWrite \(status)"); freeAudioBuffer(&ioData.mBuffers, channels: ioData.mNumberBuffers); return }
            
            outputCallback?(bytesAudioBuffer(&ioData.mBuffers, channels: ioData.mNumberBuffers), inNumberFrames)
            
            freeAudioBuffer(&ioData.mBuffers, channels: ioData.mNumberBuffers)
            
            callback?(Float(offsetFrame)/Float(info.frames), status)
            
            /// 加这个才能调用下一次混音输入
            inTimeStamp.mSampleTime += Float64(inNumberFrames)
        }
    }
    
    /**
     开始音频单元
     */
    func startUnit() -> OSStatus {
        
        timePitchUnit.delegate = self
        
        var status = AudioUnitInitialize(timePitchUnit.instance)
        Print.debug("AudioUnitInitialize timePitchUnit \(status)")
        guard status == noErr else { return status }
        status = AudioUnitInitialize(ioUnit.instance)
        Print.debug("AudioUnitInitialize ioUnit \(status)")
        guard status == noErr else { return status }
        status = AudioOutputUnitStart(ioUnit.instance)
        Print.debug("AudioOutputUnitStart ioUnit \(status)")
        guard status == noErr else { return status }
        
        return status
    }
    
    /**
     暂停音频单元
     */
    func pauseUnit() -> OSStatus {
        
        var status = AudioOutputUnitStop(ioUnit.instance)
        Print.debug("AudioOutputUnitStop ioUnit \(status)")
        guard status == noErr else { return status }
        status = AudioUnitUninitialize(ioUnit.instance)
        Print.debug("AudioUnitUninitialize ioUnit \(status)")
        guard status == noErr else { return status }
        status = AudioUnitUninitialize(timePitchUnit.instance)
        Print.debug("AudioUnitUninitialize timePitchUnit \(status)")
        guard status == noErr else { return status }
        
        timePitchUnit.delegate = nil
        
        return status
    }
    
    /**
     开始
     */
    open func start() -> OSStatus {
        
        var run = false
        
        isRunLock.lock()
        run = isRun
        isRunLock.unlock()
        
        if run {
            
            return noErr
        }
        
        let status = startUnit()
        
        if status == noErr && offline {
            
            queue.async {
                
                self.isRunLock.lock()
                self.isRun = true
                self.isRunLock.unlock()
                
                self.readOutput()
                
                self.isRunLock.lock()
                self.isRun = false
                self.isRunLock.unlock()
            }
        }
        
        return status
    }
    
    /**
     暂停
     */
    open func pause() -> OSStatus {
        
        let status = pauseUnit()
        
        if status == noErr {
            
            self.isRunLock.lock()
            self.isRun = false
            self.isRunLock.unlock()
        }
        
        return status
    }
    
    /**
     停止
     */
    open func stop() -> OSStatus {
        
        var status = pause()
        guard status == noErr else { return status }
        
        /// 关闭文件
        status = ExtAudioFileDispose(readInfo.id)
        guard status == noErr else { return status }
        
        status = ExtAudioFileDispose(writeInfo.id)
        guard status == noErr else { return status }
        
        return status
    }
    
    /**
     移动到时间点
     如果已运行 则先 `pause()` 再设置 `seek(_ time: Double)` 然后再启动 `start()`
     
     - parameter    time:   时间点
     */
    open func seek(_ time: Double) {
        
        queue.async {
            
            var inFrameOffset = Int64(self.readASBD.mSampleRate * time)
            
            if inFrameOffset > self.readInfo.frames {
                
                inFrameOffset = self.readInfo.frames
            }
            else if inFrameOffset < 0 {
                
                inFrameOffset = 0
            }
            
            let status = ExtAudioFileSeek(self.readInfo.id, inFrameOffset)
            Print.debug("ExtAudioFileSeek \(status)")
        }
    }
    
    // MARK - AudioUnitTimePitchProtocol
    
    public func audioUnit(_ timePitch: AudioUnitTimePitch, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        guard inNumberFrames > 0 else { return errno }
        guard ioData != nil else { return errno }
                
        /// 文件位置
        var offset: Int64 = 0
        var status = ExtAudioFileTell(readInfo.id, &offset)
        guard status == noErr else { return status }
        
        if !offline {
            
            callback?(Float(offset)/Float(readInfo.frames), noErr)
        }
        
        /// 文件读取结束
        if offset == readInfo.frames && offline {
            
            return stop()
        }
        
        /// 读取文件
        var ioNumberFrames = inNumberFrames
        status = ExtAudioFileRead(readInfo.id, &ioNumberFrames, ioData!)
        
        return status
    }
}
