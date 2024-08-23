//
//  ScreenPickerManager.swift
//  presenterMode
//
//  Created by Ben Jones on 6/13/24.
//

import ScreenCaptureKit
import OSLog
import SwiftUI
import CollectionConcurrencyKit
import AVFoundation

enum FrameType {
    case uncropped(IOSurface)
    case cropped(CGImage)
}

struct HistoryEntry {
    let scWindow : SCWindow
    var preview: CGImage?
}

class ScreenPickerManager: NSObject, ObservableObject, SCContentSharingPickerObserver {
    
    private let logger = Logger()
    private let screenPicker = SCContentSharingPicker.shared
    
    private let avDeviceManager: AVDeviceManager
    init(avManager: AVDeviceManager) {
        self.avDeviceManager = avManager
    }
    
    public static let sharingStoppedImage: CGImage = CGImage(pngDataProviderSource: CGDataProvider(data: NSDataAsset(name: "sharingStopped")!.data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!

    //seems hacky to store both the view and the impl here
    private var app: presenterModeApp?
    private var streamView: StreamView?
    private var streamViewImpl: StreamViewImpl?
    private var scDelegate: SCStreamDelegate?
    private let videoSampleBufferQueue = DispatchQueue(label: "edu.utah.cs.benjones.VideoSampleBufferQueue")
    private var runningStream: SCStream?
    private var frameCaptureTask: Task<Void, Never>?
    
    @Published var history = [HistoryEntry]()
    
    func registerView(_ streamView: StreamView, _ streamViewImpl: StreamViewImpl) {
        //TODO: Do we need to clear the old one?
        self.streamView = streamView
        self.streamViewImpl = streamViewImpl
        logger.debug("attaching view to picker manager")
    }
    
    //TODO MOVE OUT OF THIS BIG CLASS!
    func streamAVDevice(device: AVCaptureDevice, avMirroring: Bool){
        logger.debug("want to stream device: \(device.localizedName)")
        if(frameCaptureTask != nil){
            frameCaptureTask!.cancel()
            runningStream!.stopCapture()
            frameCaptureTask = nil
        }
        streamView?.streamAVDevice(streamViewImpl: streamViewImpl!, device: device,
        avMirroring: avMirroring)
    }
    
    func updateAVMirroring(avMirroring: Bool){
        streamView?.setAVMirroring(mirroring: avMirroring)
    }
    
    func setApp(app:presenterModeApp){
        self.app = app
    }
    
    
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        logger.debug("Cancelled!!")
    }
    
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        
        logger.debug("Updated from picker!")
        logger.debug("Filter rect: \(filter.contentRect.debugDescription) size: \(filter.contentRect.size.debugDescription) scale: \(filter.pointPixelScale) iswindow?: \(filter.style == .window)")
        
        startStreamingFromFilter(filter: filter)
        
    }
    
    func startStreamingFromFilter(filter: SCContentFilter) {
        avDeviceManager.stopSharing()
        Task { @MainActor in
            
            //open up the window
            await app?.openWindow()
            self.streamView!.streamWindow(streamViewImpl: self.streamViewImpl!)
            
            switch(filter.style){
            case .window:
                
                //hack to get the window being shared
                let matchingWindows = await getCurrentlySharedWindow(size: filter.contentRect.size)
                
                //TODO, remove any history entries which aren't in matchingwindows anymore
                
                self.history.removeAll{ window in matchingWindows.contains(window.scWindow)}
                await self.history.append(contentsOf: matchingWindows.concurrentCompactMap{window in
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width)
                    config.height = Int(window.frame.height)
                    config.scalesToFit = true
                    do {
                        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                        return HistoryEntry(scWindow: window, preview: screenshot)
                    } catch {
                        self.logger.debug("history entry add failed: \(error)")
                    }
                    return nil
                })
            case .none:
                logger.error("Filter has no style (type)")
                return
            case .display:
                logger.debug("sharing a full display, not adding to history")
            case .application:
                logger.debug("sharing an application, not adding to history")
            @unknown default:
                logger.error("Filter has unknown style (type)")
            }
        }
        

        if(frameCaptureTask != nil){
            Task {

                do {
                    try await self.runningStream?.updateContentFilter(filter)
                    try await self.runningStream?.updateConfiguration(getStreamConfig(filter.contentRect.size))
                } catch {
                    logger.error("Couldn't update stream on picker change: \(error)")
                }
            }
        } else {
            
            
            self.frameCaptureTask = Task {
                do {
                    for try await frame in frameSequenceFromFilter(filter: filter) {
                        await self.streamView?.updateFrame(frame)

                    }
                } catch {
                    logger.error("Error with stream: \(error)")
                }
                //so the stream can restart in the future
                await self.streamView?.updateFrame(FrameType.cropped(ScreenPickerManager.sharingStoppedImage))
                self.frameCaptureTask = nil
            }
        }
    }
    
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        logger.debug("Picker start failed failed: \(error)")
    }
    
    func present(){
        if(!screenPicker.isActive){
            screenPicker.isActive = true
            screenPicker.add(self)
        }
        //TODO present for if stream is already running
        
        //You can't currently set the picker to support single app or single window
        //You can either allow multiple of everything too, or only windows/only apps
        //Thanks apple!
        
//        let configuration = {
//            var configuration = SCContentSharingPickerConfiguration()
//            configuration.allowedPickerModes = .singleApplication | .singleWindow
//            
//        }

        screenPicker.present()
    }
    
    func frameSequenceFromFilter(filter: SCContentFilter) -> AsyncThrowingStream<FrameType, Error> {
        return AsyncThrowingStream<FrameType, Error> { continuation in
            
            
            let delegate = StreamToFramesDelegate(continuation: continuation, filter: filter)
            self.scDelegate = delegate
            self.runningStream = SCStream(filter: filter, configuration: getStreamConfig(filter.contentRect.size), delegate: self.scDelegate!)
            do {
                try self.runningStream?.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
                self.runningStream?.startCapture()
            } catch {
                logger.debug("Start capture failed: \(error)")
            }
        }
    }
    
}


class StreamToFramesDelegate : NSObject, SCStreamDelegate, SCStreamOutput {
    var logger = Logger()

    private var trigger = ConservativeTrigger()
    
    private var streamDimensions = CGSize(width: 1920, height: 1080)
    private var continuation: AsyncThrowingStream<FrameType, Error>.Continuation
    private var filter: SCContentFilter
    
    init(continuation: AsyncThrowingStream<FrameType, Error>.Continuation, filter: SCContentFilter){
        self.continuation = continuation
        self.filter = filter
        logger.info("Created stream delegate")
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of: SCStreamOutputType){
        guard buffer.isValid else {
            return
        }
        //get the sample buffer attachments for some reason?
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(buffer,
                                                                             createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return }
        
        // Validate the status of the frame. If it isn't `.complete`, return nil.
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else {
            return
        }
        
        guard let contentRectDict = attachments[.contentRect],
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat,
              let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary) else {
            logger.error("Couldn't get contectRect!")
            return
        }
        let scaledSize = CGSize(width: contentRect.size.width*scaleFactor, height: contentRect.size.height*scaleFactor)
        let unscaledContentSize = CGSize(width: contentRect.size.width/contentScale, height: contentRect.size.height/contentScale)
        
        guard of == SCStreamOutputType.screen else { return }
        
        //extract the image
        guard let pixelBuffer = buffer.imageBuffer else {
            return
        }
        
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            logger.error("Couldn't get IOSurface")
            return
        }
       
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        
        let croppingRequired = !rectsApproxEqual(scaledSize, CGSize(width:surface.width, height: surface.height))
        //if we don't need to crop then the size couldn't have changed
        let sizeChanged = croppingRequired && self.streamDimensions != scaledSize
        if(sizeChanged){
            self.streamDimensions = scaledSize
        }
        
        let triggered = trigger.tick(updateOccurred: sizeChanged)
        if(triggered){
            //update the stream config
            Task {
                do {
                    //filter is not updated...
                    logger.debug("updating config with dimensions: \(unscaledContentSize.debugDescription)")
                    try await stream.updateConfiguration(getStreamConfig(unscaledContentSize))
                    logger.debug("stream config updated")
                } catch {
                    logger.error("couldn't update stream: \(error)")
                }
            }
        }
        //after the config update happens we should be able to do this
        if(!croppingRequired){
            continuation.yield(FrameType.uncropped(surface))
            return
        }
        
        //crop it to the content rect size
        let cii = CIImage(ioSurface: surface)
        let ciContext = CIContext()
        guard let cgImage =
                ciContext.createCGImage(cii,
                                        from: CGRect(origin: CGPoint(x: 0, y: surface.height - Int(scaledSize.height)),
                                                     size: scaledSize)) else {
            logger.error("Couldn't make CGImage")
            return
        }
        continuation.yield(FrameType.cropped(cgImage))
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.debug("STREAM STOPPED WITH ERROR: \(error)")
        continuation.finish()
        
    }
}


private func rectsApproxEqual(_ r1: CGSize, _ r2: CGSize) -> Bool{
    return (abs(r1.width - r2.width) + abs(r1.height - r2.height)) < 5 //+/- ~ 2 pixels in each dimension seems fine
}

let FrameScaling = 2

private func getStreamConfig(_ streamDimensions: CGSize) -> SCStreamConfiguration {
    let conf = SCStreamConfiguration()
    conf.capturesAudio = false
    conf.width = FrameScaling*Int(streamDimensions.width)
    conf.height = FrameScaling*Int(streamDimensions.height)
    //when false, if the window shrinks, the unused part of the frame is black
    conf.scalesToFit = true
    //60FPS
    conf.minimumFrameInterval = CMTime(value:1, timescale: 60)
    conf.queueDepth = 5 //wait to process up to 5 frames
    Logger().debug("configuration width: \(conf.width) height: \(conf.height)")
    return conf
}

private func getCurrentlySharedWindow(size: CGSize) async -> [SCWindow] {
    do {
        
        //Try to figure out window is about to get swapped out
        let allContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let allWindows = allContent.windows
        let matchingWindows = allWindows.filter {window in window.isActive && window.frame.size == size}
        return matchingWindows
        
    } catch {
        Logger().debug("failed figuring out what the old window was: \(error)")
        return []
    }
}

