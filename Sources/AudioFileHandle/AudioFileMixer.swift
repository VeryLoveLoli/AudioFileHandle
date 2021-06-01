//
//  AudioFileMixer.swift
//  
//
//  Created by 韦烽传 on 2021/5/31.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import AudioFileInfo
import Print

/**
 音频文件混音器
 */
open class AudioFileMixer: AudioUnitMixerProtocol {
    
    /**
     IO单元
     */
    class func ioUnit(_ streamBasicDescription: AudioStreamBasicDescription) -> AudioUnitComponent.AudioUnit? {
        
        return AudioUnitOutput(streamBasicDescription)
    }
    
    /// 队列
    public let queue: DispatchQueue
    /// 读取文件信息列表
    public let readInfoList: [AudioFileReadInfo]
    /// 写入文件信息
    public let writeInfo: AudioFileWriteInfo
    /// 输出/播放 音频参数
    public var basic: AudioStreamBasicDescription
    /// 混音
    public let mixerUnit: AudioUnitMixer
    /// IO
    public let ioUnit: AudioUnitComponent.AudioUnit
    
    /// 主输入总线
    open var mainInputBus = 0
    /// 是否循环其它总线
    open var isLoopOtherInputBus = true
    /// 是否在运行
    open internal(set) var isRun = false
    /// 锁
    let isRunLock = NSLock()
    
    /// 回调（进度，状态）
    open var callback: ((Float, OSStatus)->Void)? = nil
    
    /**
     初始化
     
     - parameter    inPaths:            输入音频文件路径
     - parameter    outPath:            输出音频文件路径
     - parameter    basicDescription:   音频参数
     */
    public init?(_ inPaths: [String], outPath: String, basicDescription: AudioStreamBasicDescription) {
        
        queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).\(Self.self).serial")
        basic = basicDescription
        
        /// 获取文件信息
        var list = [AudioFileReadInfo]()
        for path in inPaths {
            guard let info = AudioFileReadInfo(path, converter: basic) else { Print.error("AudioFileReadInfo error"); return nil }
            list.append(info)
        }
        readInfoList = list
        
        /// 创建写入文件
        guard let info = AudioFileWriteInfo(outPath, basicDescription: basic) else { Print.error("AudioFileWriteInfo error"); return nil }
        writeInfo = info
        
        /// 状态
        var status: OSStatus = noErr
        
        /**
         混音器
         */
        guard let mixer = AudioUnitMixer(basic) else { Print.error("AudioUnitMixer error"); return nil }
        mixerUnit = mixer
        
        /**
         IO器
         */
        guard let io = AudioUnitOutput(basic) else { Print.error("AudioUnitOutput error"); return nil }
        ioUnit = io
        
        /// 设置混音数量
        let count = UInt32(readInfoList.count)
        status = mixerUnit.setBus(count)
        guard status == noErr else { return nil }
        
        /// 混音输入
        for i in 0..<count {
            
            status = mixerUnit.inRenderCallback(i)
            guard status == noErr else { return nil }
            status = mixerUnit.input(i, asbd: basic)
            guard status == noErr else { return nil }
        }
        
        /// 连接混音输出（总线0） 到 IO输入（总线0）
        status = AudioUnit.connection(mixerUnit, sourceOutBus: 0, destUnit: ioUnit, destInBus: 0)
        
        guard status == noErr else { return nil }
    }
    
    /**
     读取输出
     */
    func readOutput() {
        
        let info = readInfoList[mainInputBus]
        
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
            ioData.mNumberBuffers = 1
            ioData.mBuffers.mNumberChannels = basic.mChannelsPerFrame
            ioData.mBuffers.mDataByteSize = inNumberFrames*basic.mBytesPerFrame
            ioData.mBuffers.mData = calloc(Int(inNumberFrames), Int(basic.mBytesPerFrame))
            
            /// 渲染
            let status = AudioUnitRender(ioUnit.instance, &ioActionFlags, &inTimeStamp, inOutputBusNumber, inNumberFrames, &ioData)
            
            /// 释放内存
            free(ioData.mBuffers.mData)
            ioData.mBuffers.mData = nil
            
            callback?(Float(offsetFrame)/Float(info.frames), status)
            
            guard status == noErr else { Print.error("AudioUnitRender \(status)"); return }
            
            /// 加这个才能调用下一次混音输入
            inTimeStamp.mSampleTime += Float64(inNumberFrames)
        }
    }
    
    /**
     开始音频单元
     */
    func startUnit() -> OSStatus {
        
        mixerUnit.delegate = self
        
        var status = AudioUnitInitialize(mixerUnit.instance)
        Print.debug("AudioUnitInitialize mixerUnit \(status)")
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
        status = AudioUnitUninitialize(mixerUnit.instance)
        Print.debug("AudioUnitUninitialize mixerUnit \(status)")
        guard status == noErr else { return status }
        
        mixerUnit.delegate = nil
        
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
        
        if status == noErr {
            
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
        for item in readInfoList {
            
            status = ExtAudioFileDispose(item.id)
            guard status == noErr else { return status }
        }
        
        status = ExtAudioFileDispose(writeInfo.id)
        guard status == noErr else { return status }
        
        return status
    }
    
    // MARK: - AudioUnitMixerProtocol
    
    public func audioUnit(_ mixer: AudioUnitMixer, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        guard readInfoList.count >= inBusNumber else { return errno }
        
        /// 获取文件信息
        let info = readInfoList[Int(inBusNumber)]
        
        /// 文件位置
        var offset: Int64 = 0
        var status = ExtAudioFileTell(info.id, &offset)
        guard status == noErr else { return status }
        
        /// 文件读取结束
        if offset == info.frames {
            
            /// 主输入总线输入完毕 停止播放
            if mainInputBus == inBusNumber {
                
                return stop()
            }
            else if isLoopOtherInputBus {
                
                /// 移动到文件帧位置
                status = ExtAudioFileSeek(info.id, 0)
                guard status == noErr else { return status }
            }
            else {
                
                return noErr
            }
        }
        
        /// 读取文件
        var ioNumberFrames = inNumberFrames
        status = ExtAudioFileRead(info.id, &ioNumberFrames, ioData!)
        
        return status
    }
    
    open func audioUnit(_ mixer: AudioUnitMixer, outBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        /// 写入文件
        return ExtAudioFileWrite(writeInfo.id, inNumberFrames, ioData!)
    }
}
