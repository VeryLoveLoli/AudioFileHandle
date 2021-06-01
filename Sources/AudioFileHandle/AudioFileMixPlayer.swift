//
//  AudioFileMixPlayer.swift
//  
//
//  Created by 韦烽传 on 2021/6/1.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import Print

/**
 音频文件混音播放器
 */
open class AudioFileMixPlayer: AudioFileMixer {
    
    /**
     IO单元
     */
    override class func ioUnit(_ streamBasicDescription: AudioStreamBasicDescription) -> AudioUnitComponent.AudioUnit? {
        
        return AudioUnitPlayer(streamBasicDescription)
    }
    
    /// 时长（主输入总线音频时长）
    open var duration: Double {
        
        return readInfoList[mainInputBus].duration
    }
    
    /**
     开始
     */
    open override func start() -> OSStatus {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        var status = noErr
        
        queue.async {
            
            if self.isRun {
                
                dispatchSemaphore.signal()
            }
            
            status = self.startUnit()
            
            if status == noErr {
                
                self.isRun = true
            }
        }
        
        dispatchSemaphore.wait()
        
        return status
    }
    
    /**
     暂停
     */
    open override func pause() -> OSStatus {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        var status = noErr
        
        queue.async {
            
            status = self.pauseUnit()
            
            if status == noErr {
                
                self.isRun = false
            }
            
            dispatchSemaphore.signal()
        }
        
        dispatchSemaphore.wait()
        
        return status
    }
    
    /**
     停止
     */
    open override func stop() -> OSStatus {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        var status = pause()
        guard status == noErr else { return status }
        
        queue.async {
            
            /// 关闭文件
            for item in self.readInfoList {
                
                status = ExtAudioFileDispose(item.id)
                
                if status != noErr {
                    
                    dispatchSemaphore.signal()
                    break
                }
            }
            
            status = ExtAudioFileDispose(self.writeInfo.id)
            dispatchSemaphore.signal()
        }
        
        dispatchSemaphore.wait()
        
        return status
    }
    
    /**
     移动到时间点
     
     - parameter    time:   时间点
     */
    open func seek(_ time: Double) {
        
        queue.async {
            
            for i in 0..<self.readInfoList.count {
                
                let info = self.readInfoList[i]
                var inFrameOffset = Int64(info.basic.mSampleRate * time)
                
                if i == self.mainInputBus || !self.isLoopOtherInputBus {
                    
                    if inFrameOffset > info.frames {
                        
                        inFrameOffset = info.frames
                    }
                    else if inFrameOffset < 0 {
                        
                        inFrameOffset = 0
                    }
                }
                else {
                    
                    inFrameOffset = inFrameOffset%info.frames
                }
                
                let status = ExtAudioFileSeek(info.id, inFrameOffset)
                Print.debug("ExtAudioFileSeek \(status)")
            }
        }
    }
    
    // MARK: - AudioUnitMixerProtocol
    
    public override func audioUnit(_ mixer: AudioUnitMixer, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        if mainInputBus == inBusNumber {
            
            guard readInfoList.count >= inBusNumber else { return errno }
            
            /// 获取文件信息
            let info = readInfoList[Int(inBusNumber)]
            
            /// 文件位置
            var offset: Int64 = 0
            let status = ExtAudioFileTell(info.id, &offset)
            
            if let callback = callback {
                
                callback(Float(offset)/Float(info.frames), status)
            }
        }
        
        return super.audioUnit(mixer, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioData)
    }
}
