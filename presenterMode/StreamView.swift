//
//  StreamView.swift
//  presenterMode: UI for the mirror window
//
//  Created by Ben Jones on 6/13/24.
//

import SwiftUI
import OSLog
import AVFoundation

struct StreamView: NSViewRepresentable {
    
    
    @EnvironmentObject var pickerManager: ScreenPickerManager
    @EnvironmentObject var avDeviceManager: AVDeviceManager
    private let logger = Logger()
    
    private let contentLayer = CALayer() //layer for SCKit stuff
    private var avLayer: AVCaptureVideoPreviewLayer? //layer for AV devices
    init() {
        contentLayer.contentsGravity = .resizeAspectFill
    }
    
    mutating func streamAVDevice(streamViewImpl: StreamViewImpl, device: AVCaptureDevice, avMirroring: Bool) {
        var layer: AVCaptureVideoPreviewLayer?
        DispatchQueue.global(qos:.background).sync {
            logger.debug("starting to stream AV device!")
            layer = self.avDeviceManager.setupCaptureSession(device: device)
        }
        self.avLayer = layer
        streamViewImpl.layer = self.avLayer
        setAVMirroring(mirroring: avMirroring)
    }
    
    func setAVMirroring(mirroring: Bool){
        //https://stackoverflow.com/questions/41885927/unable-to-mirror-avcapturevideopreviewlayer-on-macos
        avLayer?.connection!.automaticallyAdjustsVideoMirroring = false
        avLayer?.connection!.isVideoMirrored = mirroring
    }
    
    mutating func streamWindow(streamViewImpl: StreamViewImpl){
        streamViewImpl.layer = self.contentLayer
    }
    
    
    func makeNSView(context: Context) -> some NSView {
        let viewImpl = StreamViewImpl(layer:contentLayer)
        pickerManager.registerView(self, viewImpl)
        return viewImpl
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        //ignored
//        let viewsize = nsView.frame.size
//        logger.debug("updatensview with its framesize: \(viewsize.width) x \(viewsize.height)")
    }

    mutating func updateFrame(_ cgImage : FrameType){
        switch(cgImage){
        case .uncropped(let iosurf):
            self.contentLayer.contents = iosurf
        case .cropped(let cgImage):
            self.contentLayer.contents = cgImage
        }
    }
}
class StreamViewImpl : NSView {
    
    init(layer: CALayer) {
        super.init(frame: .zero)
        self.layer = layer
        self.wantsLayer = true
        self.layerContentsPlacement = .scaleProportionallyToFit
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
}


