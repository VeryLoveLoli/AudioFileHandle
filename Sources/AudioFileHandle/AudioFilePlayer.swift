//
//  AudioFilePlayer.swift
//  
//
//  Created by 韦烽传 on 2021/5/28.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import Print

/**
 音频文件播放器
 */
open class AudioFilePlayer: AudioUnitPlayerProtocol {
    
    /// 队列
    public let queue: DispatchQueue
    /// 音频流录制器
    open var player: AudioUnitPlayer?
    /// 文件地址
    public let url: CFURL
    /// 文件对象
    private var file: ExtAudioFileRef?
    /// 文件参数
    open internal(set) var basic = AudioStreamBasicDescription()
    /// 帧数
    open internal(set) var numbersFrames: Int64 = 0
    /// 时长
    open internal(set) var duration: Double = 0
    /// 播放时转换的参数
    open internal(set) var client: AudioStreamBasicDescription?
    /// 音频设备参数
    public let component: AudioComponentDescription
    
    /// 播放进度回调（当前帧数，总帧数）
    open var callback: ((Int64,Int64)->Void)?
    
    /// 是否已准备好播放
    open internal(set) var isPrepareToPlaying = false
    /// 是否在播放
    open internal(set) var isPlaying = false
    
    /**
     初始化
     
     - parameter    path:                   文件路径
     - parameter    clientDescription:      播放时转换的音频参数
     - parameter    componentDescription:   音频设备参数
     */
    public init(_ path: String, clientDescription: AudioStreamBasicDescription? = nil, componentDescription: AudioComponentDescription = .remoteIO()) {
        
        queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).\(Self.self).serial")
        url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path as CFString, .cfurlposixPathStyle, false)
        client = clientDescription
        component = componentDescription
    }
    
    /**
     准备
     */
    @discardableResult func prepare() -> Bool {
        
        if isPrepareToPlaying { return true }
        
        var status = ExtAudioFileOpenURL(url, &file)
        Print.debug("ExtAudioFileOpenURL \(status)")
        guard status == noErr else { return false }
        
        /// 获取文件音频流参数
        var size = UInt32(MemoryLayout.stride(ofValue: basic))
        status = ExtAudioFileGetProperty(file!, kExtAudioFileProperty_FileDataFormat, &size, &basic)
        Print.debug("ExtAudioFileGetProperty kExtAudioFileProperty_FileDataFormat \(status)")
        guard status == noErr else { return false }
        
        /// 获取文件音频流帧数
        var numbersFramesSize = UInt32(MemoryLayout.stride(ofValue: numbersFrames))
        status = ExtAudioFileGetProperty(file!, kExtAudioFileProperty_FileLengthFrames, &numbersFramesSize, &numbersFrames)
        Print.debug("ExtAudioFileGetProperty kExtAudioFileProperty_FileLengthFrames \(status)")
        guard status == noErr else { return false }
        
        /// 时长
        duration = Float64(numbersFrames)/basic.mSampleRate
        
        var streamBasicDescription = basic
        
        if client != nil {
            
            /// 设置客户端音频流参数（输出数据参数）
            status = ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.stride(ofValue: client)), &client)
            Print.debug("ExtAudioFileSetProperty kExtAudioFileProperty_ClientDataFormat \(status)")
            guard status == noErr else { return false }
            
            streamBasicDescription = client!
        }
        
        player = AudioUnitPlayer(streamBasicDescription, componentDescription: component)
        
        if player != nil {
            
            isPrepareToPlaying = true
        }
        
        return isPrepareToPlaying
    }
    
    /**
     准备播放
     */
    @discardableResult open func prepareToPlay() -> Bool {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        queue.async {
            
            self.prepare()
            
            dispatchSemaphore.signal()
        }
        
        dispatchSemaphore.wait()
        
        return isPrepareToPlaying
    }
    
    /**
     开始
     */
    @discardableResult func start() -> Bool {
        
        if isPlaying { return true }
        
        if !prepare() { return false }
        
        player?.delegate = self
        
        if (player?.start() ?? errno) == noErr {
            
            isPlaying = true
        }
        else {
            
            player?.delegate = nil
        }
        
        return isPlaying
    }
    
    /**
     播放
     */
    @discardableResult open func play() -> Bool {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        queue.async {
            
            self.start()
            
            dispatchSemaphore.signal()
        }
        
        dispatchSemaphore.wait()
        
        return isPlaying
    }
    
    /**
     暂停
     */
    open func pause() {
        
        queue.async {
            
            if self.isPlaying {
                
                self.isPlaying = false
                self.player?.stop()
                self.player?.delegate = nil
            }
        }
    }
    
    /**
     停止
     */
    open func stop() {
        
        pause()
        
        queue.async {
            
            if self.isPrepareToPlaying {
                
                self.isPrepareToPlaying = false
                
                if let file = self.file {
                    
                    let status = ExtAudioFileDispose(file)
                    Print.debug("ExtAudioFileDispose \(status)")
                }
            }
        }
    }
    
    /**
     移动到时间点
     
     - parameter    time:   时间点
     */
    open func seek(_ time: Double) {
        
        if prepareToPlay() {
            
            queue.async {
                
                var inFrameOffset = Int64(self.basic.mSampleRate * time)
                
                if inFrameOffset > self.numbersFrames {
                    
                    inFrameOffset = self.numbersFrames
                }
                else if inFrameOffset < 0 {
                    
                    inFrameOffset = 0
                }
                
                if let file = self.file {
                    
                    let status = ExtAudioFileSeek(file, inFrameOffset)
                    Print.debug("ExtAudioFileSeek \(status)")
                }
            }
        }
    }
    
    // MARK: - AudioUnitPlayerProtocol
    
    public func audioUnit(_ player: AudioUnitPlayer, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        
        guard let file = file else { return errno }
        
        if let callback = callback {
            
            var value: Int64 = 0
            
            if ExtAudioFileTell(file, &value) == noErr {
                
                callback(value, numbersFrames)
            }
        }
        
        var ioNumberFrames = inNumberFrames
        let status = ExtAudioFileRead(file, &ioNumberFrames, ioData)
        
        if ioNumberFrames == 0 || status != noErr {
            
            player.stop()
            player.delegate = nil
            
            queue.async {
                
                if self.isPlaying {
                    
                    self.isPlaying = false
                }
            }
        }
        
        return status
    }
    
    public func audioUnit(_ player: AudioUnitPlayer, outNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        return noErr
    }
}
