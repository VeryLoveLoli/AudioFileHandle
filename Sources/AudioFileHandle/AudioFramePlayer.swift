//
//  AudioFramePlayer.swift
//  
//
//  Created by 韦烽传 on 2021/5/28.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import LinkedList
import Print

/**
 音频帧播放
 */
open class AudioFramePlayer: AudioUnitPlayerProtocol {
    
    /// 缓冲链表
    private var linkedList = LinkedListOneWay<[UInt8]>()
    /// 缓冲数据
    private var bufferBytes = [UInt8]()
    /// 缓冲数据大小
    private var bufferBytesCount: Int64 = 0
    /// 录制参数
    open internal(set) var basic: AudioStreamBasicDescription
    /// 音频设备参数
    public let component: AudioComponentDescription
    /// 播放器
    open internal(set) var player: AudioUnitPlayer?
    /// 队列
    public let queue: DispatchQueue
    /// 最大帧数据大小 一般每次帧数为512/1024，帧数X通道数X位数/字节位数
    open var maxFramesBytes = 1024*2*32/8
    
    /// 是否已准备好播放
    open internal(set) var isPrepareToPlaying = false
    /// 是否在播放
    open internal(set) var isPlaying = false
    
    /// 播放回调 (播放需要字节,剩余缓冲字节)
    open var callback: ((Int,Int64)->Void)?
    
    /**
     初始化
     
     - parameter    streamBasicDescription:     音频参数
     - parameter    componentDescription:       音频设备参数
     */
    public init(_ streamBasicDescription: AudioStreamBasicDescription, componentDescription: AudioComponentDescription = .remoteIO()) {
        
        basic = streamBasicDescription
        component = componentDescription
        queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).\(Self.self).serial")
    }
    
    /**
     准备
     */
    @discardableResult func prepare() -> Bool {
        
        if isPrepareToPlaying { return true }
        
        player = AudioUnitPlayer(basic, componentDescription: component)
        
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
     缓冲数据
     */
    open func buffer(_ bytes: [UInt8]) {
        
        queue.async {
            
            if self.prepare() {
                
                var start = 0
                
                while start < bytes.count {
                    
                    var end = start + self.maxFramesBytes
                    
                    if end > bytes.count {
                        
                        end = bytes.count
                    }
                    
                    self.linkedList.addTailNode(value: [UInt8](bytes[start..<end]))
                    
                    start = end
                }
                
                self.bufferBytesCount += Int64(bytes.count)
            }
        }
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
                self.linkedList = LinkedListOneWay<[UInt8]>()
                self.bufferBytes = [UInt8]()
            }
        }
    }
    
    // MARK: - AudioUnitPlayerProtocol
    
    public func audioUnit(_ player: AudioUnitPlayer, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        
        let byteCount = Int(ioData.pointee.mBuffers.mDataByteSize)
        
        /// 数据不足获取数据
        if bufferBytes.count < byteCount {
            
            /// 信号
            let dispatchSemaphore = DispatchSemaphore.init(value: 0)
            
            queue.async {
                
                /// 循环获取足够的数据，没有数据则跳过
                while let bytes = self.linkedList.removeHeadNode() {
                    
                    self.bufferBytes += bytes
                    
                    if self.bufferBytes.count >= byteCount {
                        
                        break
                    }
                }
                
                /// 发信号
                dispatchSemaphore.signal()
            }
            
            /// 等待信号
            dispatchSemaphore.wait()
        }
        
        /// 播放回调
        if let callback = callback {
            
            callback(byteCount, bufferBytesCount)
        }
        
        /// 数据足够才播放，固定播放`inNumberFrames`的帧数
        
        memset(ioData.pointee.mBuffers.mData, 0, byteCount)
        
        if bufferBytes.count >= byteCount {
            
            ioData.pointee.mBuffers.mData?.copyMemory(from: bufferBytes, byteCount: byteCount)
            
            /// 使用 `bufferBytes.suffix(bufferBytes.count - byteCount)` 会消耗大量的CPU，执行了O(k)
            bufferBytes = [UInt8](bufferBytes[byteCount..<bufferBytes.count])
            bufferBytesCount -= Int64(byteCount)
        }
        
        return noErr
    }
    
    public func audioUnit(_ player: AudioUnitPlayer, outNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        
        return noErr
    }
}
