//
//  AudioVideoFileComposition.swift
//  
//
//  Created by 韦烽传 on 2021/6/2.
//

import Foundation
import AVFoundation
import Print

/**
 音视频文件合成
 */
open class AudioVideoFileComposition {
    
    /**
     拼接轨道
     
     - parameter    composition:    合成器
     - parameter    items:          地址组
     - parameter    maxTime:        轨道最大时间
     - parameter    type:           轨道类型
     */
    public class func splicing(_ composition: AVMutableComposition, items: [URL], maxTime: CMTime = CMTime(value: CMTimeValue.max, timescale: 1), type: AVMediaType = .audio) -> (AVMutableCompositionTrack, CMTime)? {
        
        /// 轨道
        guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { Print.error("splicing composition \(type) track nil"); return nil }
        
        /// 总时间
        var time: CMTime = .zero
        
        /// 拼接
        for item in items {
            
            /// 资源
            let asset = AVURLAsset(url: item)
            /// 资源时间
            var duration = asset.duration
            
            if time + duration > maxTime {
                
                duration = maxTime - time
            }
            
            /// 资源轨道
            if let track_item = asset.tracks(withMediaType: type).first {
                
                do {
                    
                    // 插入轨道
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track_item, at: time)
                    
                    time = time + duration
                    
                } catch {
                    
                    Print.error("splicing \(item.absoluteString) insertTimeRange \(error)")
                }
            }
            else {
                
                Print.error("splicing \(item.absoluteString) tracks \(type) nil")
            }
            
            if time == maxTime {
                
                break
            }
        }
        
        return (track, time)
    }
    
    /**
     循环轨道
     
     - parameter    composition:    合成器
     - parameter    items:          地址组
     - parameter    time:           时间
     - parameter    type:           轨道类型
     */
    public static func loop(_ composition: AVMutableComposition, items: [URL], time: CMTime, type: AVMediaType = .audio) -> AVMutableCompositionTrack? {
        
        /// 轨道
        guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { Print.error("splicing composition \(type) track nil"); return nil }
        
        /// 轨道时长列表
        var list: [AVURLAsset] = []
        /// 列表总时长
        var list_duration: CMTime = .zero
        
        for item in items {
            
            /// 资源
            let asset = AVURLAsset(url: item)
            /// 资源时长
            let duration = asset.duration
            
            if duration == .zero {
                
                Print.error("loop \(item.absoluteString) duration zero")
                
                continue
            }
            
            list.append(asset)
            list_duration = list_duration + duration
        }
        
        if list.count == 0 || list_duration == .zero {
            
            Print.error("loop items / duration / track \(type) nil")
            
            return nil
        }
        
        
        /// 插入位置
        var insertTime = CMTime.zero
        /// 索引
        var index = 0
        
        /// 循环填充轨道
        while insertTime < time {
            
            /// 资源
            let asset = list[index]
            
            /// 资源时间
            var duration = asset.duration
            
            /// 如果加入的轨道超出则截取
            if insertTime + duration > time {
            
                duration = time - insertTime
            }
            
            /// 轨道
            if let track_item = asset.tracks(withMediaType: type).first {
                
                do {
                    
                    // 插入轨道
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track_item, at: insertTime)
                    
                    /// 下一个位置
                    insertTime = insertTime + duration
                    
                } catch {
                    
                    Print.error("loop \(asset.url.absoluteString) track insertTimeRange \(error)")
                    
                    return nil
                }
            }
            else {
                
                Print.error("loop \(asset.url.absoluteString) tracks \(type) nil")
                
                return nil
            }
            
            index += 1
            index %= list.count
        }
        
        return track
    }
    
    /**
     开始合成
     
     - parameter    type:                   导出类型 `.m4a` 或 `.mp4`
     - parameter    outPath:                合成输出的路径（音频后缀必须为`.m4a`，视频后缀必须为`.mp4`）
     - parameter    trackHandler:           轨道处理 返回混音轨道 闭包内调用`splicing`或`loop`方法获取轨道
     - parameter    completionHandler:      合成状态
     */
    public static func start(_ type: AVFileType, outPath: String, trackHandler: @escaping (AVMutableComposition)->([AVMutableCompositionTrack]?), completionHandler: @escaping (AVAssetExportSession.Status)->Void) {
        
        let queue = DispatchQueue(label: "\(Date().timeIntervalSince1970).start.\(Self.self).serial")
        
        queue.async {
            
            if type != .m4a && type != .mp4 {
                
                Print.error("导出类型仅支持 音频 .m4a 视频 .mp4")
                completionHandler(.failed)
                return
            }
            
            /// 判断输出音频是文件否存在
            if FileManager.default.fileExists(atPath: outPath) {
                
                do {
                    
                    /// 删除输出音频文件
                    try FileManager.default.removeItem(atPath: outPath)
                    
                } catch {
                    
                    Print.error(error.localizedDescription)
                    
                    completionHandler(.failed)
                    
                    return
                }
            }
                        
            /// 合成器
            let composition = AVMutableComposition()
            
            /// 导出预设
            var presetName = AVAssetExportPresetAppleM4A
            
            if type == .mp4 {
                
                presetName = AVAssetExportPresetHighestQuality
            }
            
            /// 导出
            guard let export = AVAssetExportSession(asset: composition, presetName: presetName) else { Print.error("AVAssetExportSession create error presetName \(presetName)"); completionHandler(.failed); return }
            
            /// 导出类型
            export.outputFileType = type
            /// 导出路径
            export.outputURL = URL(fileURLWithPath: outPath)
            
            if let max_track = trackHandler(composition) {
                
                /// 混音
                let mix = AVMutableAudioMix()
                /// 混音参数数组
                var parameters: [AVAudioMixInputParameters] = []
                
                /// 混音音轨
                for track in max_track {
                    
                    /// 添加混音参数
                    parameters.append(AVMutableAudioMixInputParameters(track: track))
                }
                
                /// 设置混音参数
                mix.inputParameters = parameters
                /// 设置混音
                export.audioMix = mix
            }
            
            /// 导出
            export.exportAsynchronously {
                
                completionHandler(export.status)
            }
        }
    }
}
