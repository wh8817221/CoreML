//
//  CoreMLManager.swift
//  TinyYOLO-CoreML
//
//  Created by 王浩 on 2019/5/21.
//  Copyright © 2019 MachineThink. All rights reserved.
//

import UIKit

@available(iOS 11.0, *)
class CoreMLManager {
    
    var callback: ((_ rect: CGRect) -> Void)?
    let yolo = YOLO()
    let ciContext = CIContext()
    var resizedPixelBuffer: CVPixelBuffer?
    let semaphore = DispatchSemaphore(value: 2)
    
    func setUpCoreImage() {
        let status = CVPixelBufferCreate(nil, YOLO.inputWidth, YOLO.inputHeight,
                                         kCVPixelFormatType_32BGRA, nil,
                                         &resizedPixelBuffer)
        if status != kCVReturnSuccess {
            print("Error: could not create resized pixel buffer", status)
        }
    }
    
    func predict(pixelBuffer: CVPixelBuffer) {
        
        // Measure how long it takes to predict a single video frame.
        let startTime = CACurrentMediaTime()
        if resizedPixelBuffer == nil {
            setUpCoreImage()
        }
        // Resize the input with Core Image to 416x416.
        guard let resizedPixelBuffer = resizedPixelBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(YOLO.inputWidth) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sy = CGFloat(YOLO.inputHeight) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let scaleTransform = CGAffineTransform(scaleX: sx, y: sy)
        let scaledImage = ciImage.transformed(by: scaleTransform)
        ciContext.render(scaledImage, to: resizedPixelBuffer)
        
        // Resize the input to 416x416 and give it to our model.
        if let boundingBoxes = try? yolo.predict(image: resizedPixelBuffer) {
            let elapsed = CACurrentMediaTime() - startTime
            showOnMainThread(boundingBoxes, elapsed)
        }
    }
    
    func showOnMainThread(_ boundingBoxes: [YOLO.Prediction], _ elapsed: CFTimeInterval) {
        weak var welf = self
        DispatchQueue.main.async {
            welf?.show(predictions: boundingBoxes)
        }
    }
    
    func show(predictions: [YOLO.Prediction]) {
        for i in 0..<YOLO.maxBoundingBoxes {
            if i < predictions.count {
                let prediction = predictions[i]
                // The predicted bounding box is in the coordinate space of the input
                // image, which is a square image of 416x416 pixels. We want to show it
                // on the video preview, which is as wide as the screen and has a 16:9
                // aspect ratio. The video preview also may be letterboxed at the top
                // and bottom.
                
                let width = UIScreen.main.bounds.width
                let height = UIScreen.main.bounds.height
                let scaleX = width / CGFloat(YOLO.inputWidth)
                let scaleY = height / CGFloat(YOLO.inputHeight)
                //                let top = (screenHeight - height) / 2
                //                // Translate and scale the rectangle to our own coordinate system.
                var rect = prediction.rect
                //                print(rect)
                rect.origin.x *= scaleX
                rect.origin.y *= scaleY
                //                rect.origin.y += top
                rect.size.width *= scaleX
                rect.size.height *= scaleY
                self.callback?(rect)
            }
        }
    }
    
}
