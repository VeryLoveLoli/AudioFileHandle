//
//  AudioFileMixRecorder.swift
//  
//
//  Created by 韦烽传 on 2021/5/31.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import Print

/**
 音频文件混音录制器
 */
open class AudioFileMixRecorder: AudioFileMixer {
    
    /// 是否在运行
    open override var isRun: Bool {
        
        get { return recorder.isRecording }
        set { }
    }
    
    /// 录制器
    public let recorder: AudioFileRecorder
    /// 录制缓冲数据
    var bufferBytes = [UInt8]()
    
    /**
     初始化
     
     - parameter    inPaths:            输入音频文件路径
     - parameter    outPath:            输出音频文件路径
     - parameter    recordPath:         录制音频文件路径
     - parameter    basicDescription:   音频参数
     */
    public init?(_ inPaths: [String], outPath: String, recordPath: String, basicDescription: AudioStreamBasicDescription, componentDescription: AudioComponentDescription = .remoteIO()) {
        
        recorder = AudioFileRecorder(recordPath, basicDescription: basicDescription)
        
        super.init(inPaths, outPath: outPath, basicDescription: basicDescription)
        
        /// 准备录制
        guard recorder.prepare() else { Print.error("recorder prepare error"); return nil }
        
        var status: OSStatus = noErr
        
        /// 设置混音数量
        let count = UInt32(readInfoList.count) + 1
        status = mixerUnit.setBus(count)
        guard status == noErr else { return nil }
        
        /// 添加混音输入
        status = mixerUnit.inRenderCallback(count-1)
        guard status == noErr else { return nil }
        status = mixerUnit.input(count-1, asbd: basic)
        guard status == noErr else { return nil }
    }
    
    /**
     读取输出
     
     - parameter    bytes:                  音频数据
     - parameter    inNumberFrames:         帧数
     - parameter    numberFrames:           总帧数
     */
    func readOutput(_ bytes: [UInt8], inNumberFrames: UInt32, numberFrames: Int64) {
        
        bufferBytes = bytes
        
        /// 标识
        var ioActionFlags: AudioUnitRenderActionFlags = AudioUnitRenderActionFlags(rawValue: 0)
        /// 总线
        let inOutputBusNumber: UInt32 = 0
        
        /// 时间
        var inTimeStamp = AudioTimeStamp()
        memset(&inTimeStamp, 0, MemoryLayout.stride(ofValue: inTimeStamp))
        inTimeStamp.mFlags = .sampleTimeValid
        inTimeStamp.mSampleTime = Float64(numberFrames) - Float64(inNumberFrames)
        
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
        
        if status != noErr {
            
            print("AudioUnitRender error: \(status)")
        }
    }
    
    /**
     开始
     */
    open override func start() -> OSStatus {
        
        if recorder.isRecording {
            
            return noErr
        }
        
        let status = startUnit()
        
        recorder.callback = { [weak self] (bytes, inNumberFrames, numberFrames) in
            
            self?.queue.async {
                
                self?.readOutput(bytes, inNumberFrames: inNumberFrames, numberFrames: numberFrames)
            }
        }
        
        guard recorder.record() else { return errno }
        
        return status
    }
    
    /**
     暂停
     */
    open override func pause() -> OSStatus {
        
        recorder.pause()
        recorder.callback = nil
        
        return pauseUnit()
    }
    
    /**
     停止
     */
    open override func stop() -> OSStatus {
        
        recorder.stop()
        
        return super.stop()
    }
    
    
    // MARK: - AudioUnitMixerProtocol
    
    public override func audioUnit(_ mixer: AudioUnitMixer, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        guard readInfoList.count >= inBusNumber else { return errno }
        
        if mainInputBus == inBusNumber {
            
            memset(ioData!.pointee.mBuffers.mData, 0, bufferBytes.count)
            ioData!.pointee.mBuffers.mData?.copyMemory(from: bufferBytes, byteCount: bufferBytes.count)
            
            return noErr
        }
        
        var index = inBusNumber
        if index > mainInputBus {
            index -= 1
        }
        
        /// 获取文件信息
        let info = readInfoList[Int(index)]
        
        /// 文件位置
        var offset: Int64 = 0
        var status = ExtAudioFileTell(info.id, &offset)
        guard status == noErr else { return status }
        
        /// 文件读取结束
        if offset == info.frames {
            
            if isLoopOtherInputBus {
                
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
}
