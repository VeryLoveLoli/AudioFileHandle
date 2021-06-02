//
//  AudioFileRecorder.swift
//  
//
//  Created by 韦烽传 on 2021/5/28.
//

import Foundation
import AudioToolbox
import AudioUnitComponent
import Print
import WebRTCNSSwift
import LameSwift

/**
 音频文件录制
 */
open class AudioFileRecorder: AudioUnitRecorderProtocol {
    
    /// 队列
    public let queue: DispatchQueue
    /// 音频流录制器
    open internal(set) var recorder: AudioUnitRecorder?
    /// 文件地址
    public let url: CFURL
    /// 文件对象
    private var file: ExtAudioFileRef?
    /// 录制参数
    open internal(set) var basic: AudioStreamBasicDescription
    /// 文件类型
    public  let type: AudioFileTypeID
    /// 音频设备参数
    public let component: AudioComponentDescription
    
    /// 数据帧数回调（音频数据，帧数，总帧数）
    open var callback: (([UInt8], UInt32, Int64)->Void)?
    
    /// 是否已准备录制
    open internal(set) var isPrepareToRecording = false
    /// 是否在录制
    open internal(set) var isRecording = false
    
    /// WebRTC降噪（需在`record()`前设置，调用`stop()`后会自动清除）
    open var webRTCNS: WebRTCNSSwift?
    /// Lame MP3 转码（需在`record()`前设置，调用`stop()`后会自动清除）
    open var lameSwift: LameSwift?
    
    /**
     初始化
     
     - parameter    path:                   文件路径
     - parameter    basicDescription:       音频参数
     - parameter    fileType:               文件类型
     - parameter    componentDescription:   音频设备参数
     */
    public init(_ path: String, basicDescription: AudioStreamBasicDescription, fileType: AudioFileTypeID = kAudioFileCAFType, componentDescription: AudioComponentDescription = .remoteIO()) {
        
        queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).\(Self.self).serial")
        url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path as CFString, .cfurlposixPathStyle, false)
        basic = basicDescription
        type = fileType
        component = componentDescription
    }
    
    /**
     准备
     */
    @discardableResult func prepare() -> Bool {
        
        if isPrepareToRecording { return true }
        
        /// 文件标记
        let flags = AudioFileFlags.eraseFile
        
        /// 创建音频文件（文件头4096长度）
        let status = ExtAudioFileCreateWithURL(url, type, &basic, nil, flags.rawValue, &file)
        Print.debug("ExtAudioFileCreateWithURL \(status)")
        guard status == noErr else { return false }
        
        recorder = AudioUnitRecorder(basic, componentDescription: component)
        
        if recorder != nil {
            
            isPrepareToRecording = true
        }
        
        return isPrepareToRecording
    }
    
    /**
     准备录制
     */
    @discardableResult open func prepareToRecord() -> Bool {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        queue.async {
            
            self.prepare()
            
            dispatchSemaphore.signal()
        }
        
        dispatchSemaphore.wait()
        
        return isPrepareToRecording
    }
    
    /**
     开始
     */
    @discardableResult func start() -> Bool {
        
        if isRecording { return true }
        
        if !prepare() { return false }
        
        recorder?.delegate = self
        
        if (recorder?.start() ?? errno) == noErr {
            
            isRecording = true
        }
        else {
            
            recorder?.delegate = nil
        }
        
        return isRecording
    }
    
    /**
     录制
     */
    @discardableResult open func record() -> Bool {
        
        let dispatchSemaphore = DispatchSemaphore.init(value: 0)
        
        queue.async {
            
            self.start()
            
            dispatchSemaphore.signal()
        }
        
        dispatchSemaphore.wait()
        
        return isRecording
    }
    
    /**
     暂停
     */
    open func pause() {
        
        queue.async {
            
            if self.isRecording {
                
                self.isRecording = false
                self.recorder?.stop()
                self.recorder?.delegate = nil
            }
        }
    }
    
    /**
     停止
     */
    open func stop() {
        
        pause()
        
        queue.async {
            
            self.webRTCNS?.close()
            self.webRTCNS = nil
            
            self.lameSwift?.stop()
            self.lameSwift = nil
            
            if self.isPrepareToRecording {
                
                self.isPrepareToRecording = false
                
                if let file = self.file {
                    
                    let status = ExtAudioFileDispose(file)
                    Print.debug("ExtAudioFileDispose \(status)")
                }
            }
        }
    }
    
    // MARK: - AudioUnitRecorderProtocol
    
    public func audioUnit(_ recorder: AudioUnitRecorder, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) {
        
        guard let file = file else { return }
        guard let ioDataRaw = ioData.pointee.mBuffers.mData else { return }
        
        /// 获取音频数据
        let data = Data(bytes: ioDataRaw, count: Int(ioData.pointee.mBuffers.mDataByteSize))
        var bytes = [UInt8](data)
        
        var ioNumberFrames = inNumberFrames
        
        if let webRTCNS = webRTCNS {
            
            /// 降噪
            bytes = webRTCNS.automaticHandle(bytes)
            
            /// 降噪帧数
            ioNumberFrames = UInt32(bytes.count)/basic.mBytesPerFrame
            
            /// 降噪缓冲
            var buffer = AudioBufferList()
            buffer.mNumberBuffers = 1
            buffer.mBuffers.mNumberChannels = basic.mChannelsPerFrame
            buffer.mBuffers.mDataByteSize = UInt32(bytes.count)
            buffer.mBuffers.mData = calloc(bytes.count, 1)
            buffer.mBuffers.mData?.copyMemory(from: bytes, byteCount: bytes.count)
            
            /// 写入数据
            ExtAudioFileWrite(file, ioNumberFrames, &buffer)
        }
        else {
            
            /// 写入数据
            ExtAudioFileWrite(file, ioNumberFrames, ioData)
        }
        
        lameSwift?.addData(bytes)
        
        if let callback = callback {
            
            /// 总帧数
            var numbersFrames: Int64 = 0
            
            if ExtAudioFileTell(file, &numbersFrames) == noErr {
                
                callback(bytes, ioNumberFrames, numbersFrames)
            }
        }
    }
}
