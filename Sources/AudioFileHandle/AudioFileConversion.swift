//
//  AudioFileConversion.swift
//  
//
//  Created by 韦烽传 on 2021/6/2.
//

import Foundation
import AVFoundation
import Print

/**
 音频文件转码
 */
open class AudioFileConversion {
    
    /**
     m4a转caf(PCM)
     
     - parameter    inPath:         输入音频路径（`m4a`格式）
     - parameter    outPath:        输出音频路径（`caf`格式）
     - parameter    basic:          音频参数
     - parameter    complete:       完成
     */
    public static func m4aToCaf(_ inPath: String, outPath: String, basic: AudioStreamBasicDescription, complete: @escaping (Bool)->Void) {
        
        let queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).m4aToCaf.\(Self.self).serial")
        
        queue.async {
            
            /// 判断输入音频文件是否存在
            if !FileManager.default.fileExists(atPath: inPath) {
                
                Print.error("\(inPath) fileExists false")
                
                complete(false)
                
                return
            }
            
            /// 判断输出音频是文件否存在
            if FileManager.default.fileExists(atPath: outPath) {
                
                do {
                    
                    /// 删除输出音频文件
                    try FileManager.default.removeItem(atPath: outPath)
                    
                } catch {
                    
                    Print.error(error.localizedDescription)
                    
                    complete(false)
                    
                    return
                }
            }
            
            /// 音频资源
            let asset = AVURLAsset(url: URL(fileURLWithPath: inPath))
            /// 资源读取器
            let assetReader = try! AVAssetReader(asset: asset)
            /// 资源轨道读取
            let assetReaderOutput = AVAssetReaderAudioMixOutput(audioTracks: asset.tracks, audioSettings: nil)
            
            /// 资源读取器 添加 资源轨道
            if assetReader.canAdd(assetReaderOutput) {
                
                assetReader.add(assetReaderOutput)
            }
            
            /// 资源写入器
            let assetWriter = try! AVAssetWriter(url: URL(fileURLWithPath: outPath), fileType: .caf)
            
            /// 通道布局
            var channelLayout = AudioChannelLayout()
            /// 设置通道类型
            channelLayout.mChannelLayoutTag = basic.mBitsPerChannel == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
            
            /// 写入参数
            let parameters: [String : Any] = [AVFormatIDKey: basic.mFormatID,
                                                  AVNumberOfChannelsKey: basic.mChannelsPerFrame,
                                                  AVChannelLayoutKey: Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size),
                                                  AVLinearPCMIsNonInterleaved: false,
                                                  AVLinearPCMBitDepthKey: basic.mBitsPerChannel,
                                                  AVLinearPCMIsFloatKey: false,
                                                  AVLinearPCMIsBigEndianKey: false,
                                                  AVSampleRateKey: basic.mSampleRate]
            
            /// 资源写入
            let assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: parameters)
            
            /// 资源写入器 添加 资源写入
            if assetWriter.canAdd(assetWriterInput) {
                
                assetWriter.add(assetWriterInput)
            }
            
            /// 是否是实时数据
            assetWriterInput.expectsMediaDataInRealTime = false
            
            /// 开始资源写入等待
            assetWriter.startWriting()
            /// 开始资源读取等待
            assetReader.startReading()
            
            /// 获取资源音轨
            let track = asset.tracks(withMediaType: .audio).first!
            /// 资源时间区间
            let startTime = CMTime(value: 0, timescale: track.naturalTimeScale)
            /// 开始资源写入会话
            assetWriter.startSession(atSourceTime: startTime)
            
            var number = 0
            
            /// 准备请求数据
            assetWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "caf_assetWriterInput.\(queue.label)")) {
                
                /// 是否准备好获取数据
                while assetWriterInput.isReadyForMoreMediaData {
                    
                    /// 获取资源轨道数据
                    if let nextBuffer = assetReaderOutput.copyNextSampleBuffer() {
                        
                        /// 添加到资源写入
                        assetWriterInput.append(nextBuffer)
                        /// 记录数据偏移
                        number += CMSampleBufferGetTotalSampleSize(nextBuffer)
                    }
                    else {
                        /// 数据获取完毕
                        
                        /// 标记写入完成
                        assetWriterInput.markAsFinished()
                        
                        /// 完成等待
                        assetWriter.finishWriting {
                            
                            do {
                                
                                let dict = try FileManager.default.attributesOfItem(atPath: outPath)
                                Print.debug(dict)
                                /// 写入状态
                                complete(assetWriter.status == .completed)
                                
                            } catch {
                                
                                Print.error(error.localizedDescription)
                                complete(false)
                            }
                        }
                        
                        /// 取消读取
                        assetReader.cancelReading()
                    }
                }
            }
        }
    }
}
