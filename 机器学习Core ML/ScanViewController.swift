//
//  ScanViewController.swift
//  机器学习Core ML
//
//  Created by 王浩 on 2019/5/22.
//  Copyright © 2019 haoge. All rights reserved.

import UIKit
import AVFoundation
import Photos

class ScanViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, UINavigationControllerDelegate, UIImagePickerControllerDelegate, UIGestureRecognizerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    var _zoomingEnabled: Bool = true
    public var desiredFrameRate = 30
    fileprivate let scanWidth: CGFloat = 240.0, scanHeight: CGFloat = 240.0
    fileprivate let btnWidth: CGFloat = 100.0, btnHeight: CGFloat = 120.0
    fileprivate var loadOnce = false
    fileprivate var autoScan = true
    fileprivate var scanRect = CGRect.zero
    fileprivate var soundID: SystemSoundID = 0
    fileprivate var lineView: UIImageView!
    fileprivate var maskView: UIView!
    fileprivate var output: AVCaptureMetadataOutput!
    fileprivate var session: AVCaptureSession!
    fileprivate var preview: AVCaptureVideoPreviewLayer!
    
    fileprivate var captureVideoOutput: AVCaptureVideoDataOutput!
    fileprivate var device: AVCaptureDevice!
    fileprivate var input: AVCaptureDeviceInput!
    fileprivate var videoZoomFactor: CGFloat = 1
    fileprivate var contrast: CGFloat = 2.0
    fileprivate var _beginGestureScale: CGFloat!
    fileprivate var _effectiveScale: CGFloat = 1.0
    fileprivate var pinchGesture: UIPinchGestureRecognizer!
    // permission
    fileprivate var _cameraPermission = true
    fileprivate var _isScale = true
    public var fps = 50
    fileprivate var lastTimestamp = CMTime()
    @available(iOS 11.0, *)
    fileprivate lazy var coreMLManager: CoreMLManager = {
        return CoreMLManager()
    }()
    override func viewDidLoad() {
        super.viewDidLoad()
        initChildUI()
        
        initCaptureDevice()
        
        //pinch to zoom
        if (_zoomingEnabled) {
            self.pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
            self.pinchGesture.delegate = self
            self.maskView.addGestureRecognizer(self.pinchGesture)
        }
    }
    
    //MARK:- Pinch Delegate
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.isKind(of: UIPinchGestureRecognizer.self) {
            self._beginGestureScale = self._effectiveScale
        }
        return true
    }
    
    @objc fileprivate func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
        var allTouchesAreOnThePreviewLayer = true
        let numTouches = recognizer.numberOfTouches
        for i in 0..<numTouches {
            let location = recognizer.location(ofTouch: i, in: self.maskView)
            
            let convertedLocation = self.maskView.layer.convert(location, to: self.view.layer)
            if !self.maskView.layer.contains(convertedLocation) {
                allTouchesAreOnThePreviewLayer = false
                break
            }
        }
        
        if allTouchesAreOnThePreviewLayer {
            _effectiveScale = _beginGestureScale*recognizer.scale
            if _effectiveScale < 1.0 {
                _effectiveScale = 1.0
            }
            if _effectiveScale > self.device.activeFormat.videoMaxZoomFactor {
                _effectiveScale = self.device.activeFormat.videoMaxZoomFactor
            }
            do {
                try device?.lockForConfiguration()
            } catch {
                return
            }
            self.device.ramp(toVideoZoomFactor: _effectiveScale, withRate: 100)
            device?.unlockForConfiguration()
        }
    }
    
    //MARK: -初始化捕获和输出设备
    fileprivate func initCaptureDevice() {
        if AVCaptureDevice.authorizationStatus(for: AVMediaType.video) == .denied {
            // permission
            _cameraPermission = false
            
            showNormalAlert(.permissionCamera, cancelHandler:nil, confirmHandler: { () -> Void in
                UIApplication.shared.openURL(URL(string: UIApplication.openSettingsURLString)!)
            })
            return
        }
        
        // scanner
        do {
            device = AVCaptureDevice.default(for: AVMediaType.video)
            input = try AVCaptureDeviceInput(device: device!)
            output = AVCaptureMetadataOutput()
            session = AVCaptureSession()
            session.beginConfiguration()
            //连接输入输出
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            
            session.sessionPreset = .hd1280x720
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [AVMetadataObject.ObjectType.qr]
            
            preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = AVLayerVideoGravity.resizeAspectFill
            preview.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: view.frame.height)
            view.layer.insertSublayer(preview, at: 0)
            
            let settings: [String : Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
                ]
            //连接视频输出
            let queue = DispatchQueue(label: "net.machinethink.camera-queue")
            self.captureVideoOutput = AVCaptureVideoDataOutput()
            captureVideoOutput.videoSettings = settings
            captureVideoOutput.alwaysDiscardsLateVideoFrames = true
            captureVideoOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(captureVideoOutput) {
                session.addOutput(captureVideoOutput)
            }
            captureVideoOutput.connection(with: AVMediaType.video)?.videoOrientation = .portrait
            
            let activeDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            for vFormat in device.formats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(vFormat.formatDescription)
                let ranges = vFormat.videoSupportedFrameRateRanges as [AVFrameRateRange]
                if let frameRate = ranges.first,
                    frameRate.maxFrameRate >= Float64(desiredFrameRate) &&
                        frameRate.minFrameRate <= Float64(desiredFrameRate) &&
                        activeDimensions.width == dimensions.width &&
                        activeDimensions.height == dimensions.height &&
                        CMFormatDescriptionGetMediaSubType(vFormat.formatDescription) == 875704422 { // meant for full range 420f
                    do {
                        try device.lockForConfiguration()
                        device.activeFormat = vFormat as AVCaptureDevice.Format
                        device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(desiredFrameRate))
                        device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(desiredFrameRate))
                        device.unlockForConfiguration()
                        break
                    } catch {
                        continue
                    }
                }
            }
            
            session.commitConfiguration()
        } catch let error as NSError {
            print(error.localizedDescription)
            return
        }
        
        // sound
        let path = Bundle.main.path(forResource: "qrcode", ofType:"wav")
        let url = URL(fileURLWithPath: path!)
        AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        
    }
    
    //MARK:- 初始化布局
    fileprivate func initChildUI() {
        autoScan = true
        scanRect = CGRect(x: (view.frame.width-scanWidth)/2, y: (view.frame.height-scanHeight)/2-(scanHeight/6), width: scanWidth, height: scanHeight)
        // mask
        maskView = UIView(frame: view.bounds)
        maskView.backgroundColor = UIColor(white: 0, alpha: 0.625)
        view.addSubview(maskView)
        
        let maskLayer = CAShapeLayer()
        maskLayer.frame = maskView.layer.bounds
        
        let maskPath = CGMutablePath()
        maskPath.addRect(maskView.bounds)
        maskPath.addRect(scanRect)
        
        maskLayer.path = maskPath
        maskLayer.fillRule = CAShapeLayerFillRule.evenOdd
        maskView.layer.mask = maskLayer
        
        let border = UIImageView(frame: scanRect)
        border.image = UIImage(named: "scan_box")
        view.addSubview(border)
        
        lineView = UIImageView(frame: CGRect(x: scanRect.minX, y: scanRect.minY+40, width: scanWidth, height: 6))
        lineView.image = UIImage(named: "scan_line")
        view.addSubview(lineView)
    }
    
    deinit {
        AudioServicesDisposeSystemSoundID(soundID)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        stopScanning()
        super.viewWillDisappear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // permission
        if _cameraPermission == false { return }
        
        if !loadOnce {
            loadOnce = true
            
            let metaRect = preview.metadataOutputRectConverted(fromLayerRect: scanRect)
            output.rectOfInterest = metaRect
        }
        
        if autoScan {
            startScanning()
        }
    }
    
    // MARK: - UIApplication
    override var preferredStatusBarStyle : UIStatusBarStyle {
        return .lightContent
    }
    
    fileprivate func positionMove() {
        let fromValue = NSValue(cgPoint: CGPoint(x: view.frame.width/2, y: scanRect.origin.y))
        let toValue = NSValue(cgPoint: CGPoint(x: view.frame.width/2, y: scanRect.origin.y + scanHeight))
        let moveAnimation = CABasicAnimation(keyPath: "position")
        moveAnimation.fromValue = fromValue
        moveAnimation.toValue = toValue
        moveAnimation.duration = 2
        moveAnimation.autoreverses = true //结束是否进行逆动作
        moveAnimation.repeatCount = MAXFLOAT
        lineView.layer.add(moveAnimation, forKey: "positionMove")
    }
    
    // MARK: - Scan
    func startScanning() {
        session.startRunning()
        positionMove()
    }
    
    func stopScanning() {
        session.stopRunning()
        lineView.layer.removeAllAnimations()
    }
    
    func detectedQR(_ value: String?) {
        autoScan = true
        if let scanned = value {
            showNormalAlert(.result(scanned), cancelHandler: nil) {
                self.startScanning()
            }
        } else {
            showNormalAlert(.noQrCode, cancelHandler: nil, confirmHandler: { () -> Void in
                self.startScanning()
            })
        }
    }
    
    // MARK: - AVCaptureMetadataOutputObjectsDelegate
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        if metadataObjects.count > 0 {
            if let obj = metadataObjects[0] as? AVMetadataMachineReadableCodeObject {
                stopScanning()
                AudioServicesPlaySystemSound(soundID)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) //静音模式下震动
                detectedQR(obj.stringValue!)
            }
        }
    }
    
    //#MARK: -AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let deltaTime = timestamp - lastTimestamp
        if deltaTime >= CMTimeMake(value: 1, timescale: Int32(fps)) {
            lastTimestamp = timestamp
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            weak var welf = self
            if let pixelBuffer = imageBuffer {
                DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + 1.0) {
                    if #available(iOS 11.0, *) {
                        welf?.coreMLManager.predict(pixelBuffer: pixelBuffer)
                        welf?.coreMLManager.callback = { (rect) in
                            welf?.changeVideoScale(rect: rect)
                        }
                    } else {
                        print("不支持11.0前系统版本")
                    }
                }
            }
        }
    }
    
    //MARK:-放大缩小二维码
    fileprivate func changeVideoScale(rect: CGRect) {
        //二维码包含在扫描框内
        if scanRect.minX < rect.minX && scanRect.width > rect.width && scanRect.minY < rect.minY && scanRect.height > rect.height {
            
            let left = rect.minX - scanRect.minX
            let right = scanRect.maxX - rect.maxX
            let top = rect.minY - scanRect.minY
            let bottom = scanRect.maxY - rect.maxY
            
            //比较哪个边最小
            let compares = [left, right, top, bottom]
            let min = compares.min()
            let scale = min!/120
            if scale > 0.5 {
                self.setVideoScale(scale: scale + 0.5)
            } else if scale > 0.1 && scale < 0.5 {
                self.setVideoScale(scale: scale)
            }
        }
    }
    
    func setVideoScale(scale: CGFloat) {
        
        if _effectiveScale < 1.0 {
            _effectiveScale = 1.0
        }
        
        if _effectiveScale > self.device.activeFormat.videoMaxZoomFactor {
            _effectiveScale = self.device.activeFormat.videoMaxZoomFactor
        }
        do {
            try device?.lockForConfiguration()
        } catch {
            return
        }
        let ZoomFactor = self.device.activeFormat.videoMaxZoomFactor
        if scale < ZoomFactor {
            if self._isScale {
                self._isScale = false
                self._effectiveScale = self._effectiveScale - 1
                self._effectiveScale += scale
                self._effectiveScale = self._effectiveScale + 1
                delay(1, closure: {
                    self._isScale = true
                })
                self.device.ramp(toVideoZoomFactor: self._effectiveScale, withRate: 100)
            }
        }
        device?.unlockForConfiguration()
    }
}

enum NormalAlertType {
    case permissionCamera
    case permissionPhoto
    case permissionApns
    case otherQrCode(String)
    case noQrCode
    case result(String)
    func generate() -> (title:String?, message:String?, cancel:String?, confirm:String?, other:String?) {
        switch self {
        case .permissionCamera:
            return ("未获得授权", "请在\"设置-隐私-相机\"中打开", "取消", "设置", nil)
        case .permissionPhoto:
            return ("未获得授权", "请在\"设置-隐私-照片\"中打开", "取消", "设置", nil)
        case .permissionApns:
            return ("未获得授权", "请在\"设置-隐私-通知\"中打开", "取消", "设置", nil)
        case .otherQrCode(let text):
            return (nil, text, "关闭", "拷贝", nil)
        case .noQrCode:
            return ("提示", "未发现二维码", nil, "确定", nil)
        case .result(let text):
            return ("识别结果", text, nil, "确定", nil)
        }
    }
}

extension UIViewController {
    // MARK: - NormalAlert
    func showNormalAlert(_ type: NormalAlertType, cancelHandler: (() -> Void)?, confirmHandler: (() -> Void)?) {
        let (title, message, cancel, confirm, _) = type.generate()
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        if let c = cancel {
            let action1 = UIAlertAction(title: c, style: .cancel) { (_) -> Void in
                if let handler = cancelHandler {
                    delay(0.1, closure: { () -> () in handler() })
                }
            }
            //            action1.setValue(kTextColor2, forKey: "_titleTextColor")
            alert.addAction(action1)
        }
        
        if let c = confirm {
            let action2 = UIAlertAction(title: c, style: .default) { (_) -> Void in
                if let handler = confirmHandler {
                    delay(0.1, closure: { () -> () in handler() })
                }
            }
            alert.addAction(action2)
        }
        
        present(alert, animated: true, completion: nil)
    }
}

//MARK:-延迟执行
func delay(_ delay:Double, closure:@escaping ()->()) {
    DispatchQueue.main.asyncAfter(
        deadline: DispatchTime.now() + Double(Int64(delay * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC), execute: closure)
}
