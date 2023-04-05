import Accelerate
import CoreVideo
import Foundation

extension CVPixelBuffer {
    enum Error: Swift.Error {
        case failedToMakevImage_Buffer(_ error: vImage_Error)
    }

    static var format = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        colorSpace: nil,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent)

    public var width: Int {
        CVPixelBufferGetWidth(self)
    }

    public var height: Int {
        CVPixelBufferGetHeight(self)
    }

    @discardableResult
    public func over(_ pixelBuffer: CVPixelBuffer?, regionOfInterest roi: CGRect = .zero, radius: CGFloat = 0.0) -> Self {
        guard var inputImageBuffer = try? pixelBuffer?.makevImage_Buffer(format: &Self.format) else {
            return self
        }
        defer {
            inputImageBuffer.free()
        }
        guard var srcImageBuffer = try? makevImage_Buffer(format: &Self.format) else {
            return self
        }
        defer {
            srcImageBuffer.free()
        }
        let xScale = Float(roi.width) / Float(inputImageBuffer.width)
        let yScale = Float(roi.height) / Float(inputImageBuffer.height)
        let scaleFactor = (xScale < yScale) ? xScale : yScale
        var scaledInputImageBuffer = inputImageBuffer.scale(scaleFactor)
        var shape = ShapeFactory.shared.cornerRadius(CGSize(width: CGFloat(scaledInputImageBuffer.width), height: CGFloat(scaledInputImageBuffer.height)), cornerRadius: radius)
        vImageSelectChannels_ARGB8888(&shape, &scaledInputImageBuffer, &scaledInputImageBuffer, 0x8, vImage_Flags(kvImageNoFlags))
        defer {
            scaledInputImageBuffer.free()
        }
        srcImageBuffer.over(&scaledInputImageBuffer, origin: roi.origin)
        srcImageBuffer.copy(to: self, format: &Self.format)
        return self
    }

    @discardableResult
    public func split(_ pixelBuffer: CVPixelBuffer?, direction: ImageTransform) -> Self {
        guard var inputImageBuffer = try? pixelBuffer?.makevImage_Buffer(format: &Self.format) else {
            return self
        }
        defer {
            inputImageBuffer.free()
        }
        guard var sourceImageBuffer = try? makevImage_Buffer(format: &Self.format) else {
            return self
        }
        defer {
            sourceImageBuffer.free()
        }
        let scaleX = Float(width) / Float(inputImageBuffer.width)
        let scaleY = Float(height) / Float(inputImageBuffer.height)
        var scaledInputImageBuffer = inputImageBuffer.scale(min(scaleY, scaleX))
        defer {
            scaledInputImageBuffer.free()
        }
        sourceImageBuffer.split(&scaledInputImageBuffer, direction: direction)
        sourceImageBuffer.copy(to: self, format: &Self.format)
        return self
    }

    @discardableResult
    public func reflectHorizontal() -> Self {
        guard var imageBuffer = try? makevImage_Buffer(format: &Self.format) else {
            return self
        }
        defer {
            imageBuffer.free()
        }
        guard
            vImageHorizontalReflect_ARGB8888(
                &imageBuffer,
                &imageBuffer,
                vImage_Flags(kvImageLeaveAlphaUnchanged)) == kvImageNoError else {
            return self
        }
        imageBuffer.copy(to: self, format: &Self.format)
        return self
    }

    public func makevImage_Buffer(format: inout vImage_CGImageFormat) throws -> vImage_Buffer {
        var buffer = vImage_Buffer()
        let cvImageFormat = vImageCVImageFormat_CreateWithCVPixelBuffer(self).takeRetainedValue()
        vImageCVImageFormat_SetColorSpace(cvImageFormat, CGColorSpaceCreateDeviceRGB())
        let error = vImageBuffer_InitWithCVPixelBuffer(
            &buffer,
            &format,
            self,
            cvImageFormat,
            nil,
            vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError {
            throw Error.failedToMakevImage_Buffer(error)
        }
        return buffer
    }

    @discardableResult
    public func lockBaseAddress(_ lockFlags: CVPixelBufferLockFlags = CVPixelBufferLockFlags.readOnly) -> CVReturn {
        return CVPixelBufferLockBaseAddress(self, lockFlags)
    }

    @discardableResult
    public func unlockBaseAddress(_ lockFlags: CVPixelBufferLockFlags = CVPixelBufferLockFlags.readOnly) -> CVReturn {
        return CVPixelBufferUnlockBaseAddress(self, lockFlags)
    }
    
    public class func resizePixelBuffer(from srcPixelBuffer: CVPixelBuffer,
                                  to dstPixelBuffer: CVPixelBuffer,
                                  cropX: Int,
                                  cropY: Int,
                                  cropWidth: Int,
                                  cropHeight: Int,
                                  scaleWidth: Int,
                                  scaleHeight: Int) {

      assert(CVPixelBufferGetWidth(dstPixelBuffer) >= scaleWidth)
      assert(CVPixelBufferGetHeight(dstPixelBuffer) >= scaleHeight)

      let srcFlags = CVPixelBufferLockFlags.readOnly
      let dstFlags = CVPixelBufferLockFlags(rawValue: 0)

      guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(srcPixelBuffer, srcFlags) else {
        print("Error: could not lock source pixel buffer")
        return
      }
      defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, srcFlags) }

      guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(dstPixelBuffer, dstFlags) else {
        print("Error: could not lock destination pixel buffer")
        return
      }
      defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, dstFlags) }

      guard let srcData = CVPixelBufferGetBaseAddress(srcPixelBuffer),
            let dstData = CVPixelBufferGetBaseAddress(dstPixelBuffer) else {
        print("Error: could not get pixel buffer base address")
        return
      }

      let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPixelBuffer)
      let offset = cropY*srcBytesPerRow + cropX*4
      var srcBuffer = vImage_Buffer(data: srcData.advanced(by: offset),
                                    height: vImagePixelCount(cropHeight),
                                    width: vImagePixelCount(cropWidth),
                                    rowBytes: srcBytesPerRow)

      let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstPixelBuffer)
      var dstBuffer = vImage_Buffer(data: dstData,
                                    height: vImagePixelCount(scaleHeight),
                                    width: vImagePixelCount(scaleWidth),
                                    rowBytes: dstBytesPerRow)

      let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(0))
      if error != kvImageNoError {
        print("Error:", error)
      }
    }

    /**
      First crops the pixel buffer, then resizes it.
      This allocates a new destination pixel buffer that is Metal-compatible.
    */
    public class func resizePixelBuffer(_ srcPixelBuffer: CVPixelBuffer,
                                  cropX: Int,
                                  cropY: Int,
                                  cropWidth: Int,
                                  cropHeight: Int,
                                  scaleWidth: Int,
                                  scaleHeight: Int) -> CVPixelBuffer? {

      let pixelFormat = CVPixelBufferGetPixelFormatType(srcPixelBuffer)
      let dstPixelBuffer = createPixelBuffer(width: scaleWidth, height: scaleHeight,
                                             pixelFormat: pixelFormat)

      if let dstPixelBuffer = dstPixelBuffer {
        CVBufferPropagateAttachments(srcPixelBuffer, dstPixelBuffer)

        resizePixelBuffer(from: srcPixelBuffer, to: dstPixelBuffer,
                          cropX: cropX, cropY: cropY,
                          cropWidth: cropWidth, cropHeight: cropHeight,
                          scaleWidth: scaleWidth, scaleHeight: scaleHeight)
      }

      return dstPixelBuffer
    }

    /**
      Resizes a CVPixelBuffer to a new width and height.
      This function requires the caller to pass in both the source and destination
      pixel buffers. The dimensions of destination pixel buffer should be at least
      `width` x `height` pixels.
    */
    public class func resizePixelBuffer(from srcPixelBuffer: CVPixelBuffer,
                                  to dstPixelBuffer: CVPixelBuffer,
                                  width: Int, height: Int) {
      resizePixelBuffer(from: srcPixelBuffer, to: dstPixelBuffer,
                        cropX: 0, cropY: 0,
                        cropWidth: CVPixelBufferGetWidth(srcPixelBuffer),
                        cropHeight: CVPixelBufferGetHeight(srcPixelBuffer),
                        scaleWidth: width, scaleHeight: height)
    }

    /**
      Resizes a CVPixelBuffer to a new width and height.
      This allocates a new destination pixel buffer that is Metal-compatible.
    */
    public class func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                  width: Int, height: Int) -> CVPixelBuffer? {
      return resizePixelBuffer(pixelBuffer, cropX: 0, cropY: 0,
                               cropWidth: CVPixelBufferGetWidth(pixelBuffer),
                               cropHeight: CVPixelBufferGetHeight(pixelBuffer),
                               scaleWidth: width, scaleHeight: height)
    }

    /**
      Resizes a CVPixelBuffer to a new width and height, using Core Image.
    */
    public func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                  width: Int, height: Int,
                                  output: CVPixelBuffer, context: CIContext) {
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      let sx = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
      let sy = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
      let scaleTransform = CGAffineTransform(scaleX: sx, y: sy)
      let scaledImage = ciImage.transformed(by: scaleTransform)
      context.render(scaledImage, to: output)
    }
    
    fileprivate class func metalCompatiblityAttributes() -> [String: Any] {
      let attributes: [String: Any] = [
        String(kCVPixelBufferMetalCompatibilityKey): true,
        String(kCVPixelBufferOpenGLCompatibilityKey): true,
        String(kCVPixelBufferIOSurfacePropertiesKey): [
          String(kCVPixelBufferIOSurfaceOpenGLESTextureCompatibilityKey): true,
          String(kCVPixelBufferIOSurfaceOpenGLESFBOCompatibilityKey): true,
          String(kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey): true
        ]
      ]
      return attributes
    }

    /**
      Creates a pixel buffer of the specified width, height, and pixel format.
      - Note: This pixel buffer is backed by an IOSurface and therefore can be
        turned into a Metal texture.
    */
    public class func createPixelBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
      let attributes = metalCompatiblityAttributes() as CFDictionary
        
        let outputOptions = [kCVPixelBufferOpenGLESCompatibilityKey as String: NSNumber(value: true),
                                     kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as [String : Any]
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, outputOptions as CFDictionary?, &pixelBuffer)
      if status != kCVReturnSuccess {
        print("Error: could not create pixel buffer", status)
        return nil
      }
      return pixelBuffer
    }

    /**
      Creates a RGB pixel buffer of the specified width and height.
    */
    public class func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
      createPixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
    }

    /**
      Creates a pixel buffer of the specified width, height, and pixel format.
      You probably shouldn't use this one!
      - Note: The new CVPixelBuffer is *not* backed by an IOSurface and therefore
        cannot be turned into a Metal texture.
    */
    public func _createPixelBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
      let bytesPerRow = width * 4
      guard let data = malloc(height * bytesPerRow) else {
        print("Error: out of memory")
        return nil
      }

      let releaseCallback: CVPixelBufferReleaseBytesCallback = { _, ptr in
        if let ptr = ptr {
          free(UnsafeMutableRawPointer(mutating: ptr))
        }
      }

      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreateWithBytes(nil, width, height,
                                                pixelFormat, data,
                                                bytesPerRow, releaseCallback,
                                                nil, nil, &pixelBuffer)
      if status != kCVReturnSuccess {
        print("Error: could not create new pixel buffer")
        free(data)
        return nil
      }

      return pixelBuffer
    }
    
   /*Copies a CVPixelBuffer to a new CVPixelBuffer that is compatible with Metal.
     - Tip: If CVMetalTextureCacheCreateTextureFromImage is failing, then call
       this method first!
   */
   public func copyToMetalCompatible() -> CVPixelBuffer? {
       return deepCopy(withAttributes: CVPixelBuffer.metalCompatiblityAttributes())
   }

   /**
     Copies a CVPixelBuffer to a new CVPixelBuffer.
     This lets you specify new attributes, such as whether the new CVPixelBuffer
     must be IOSurface-backed.
     See: https://developer.apple.com/library/archive/qa/qa1781/_index.html
   */
    func deepCopy(withAttributes attributes: [String: Any] = [:]) -> CVPixelBuffer? {
     let srcPixelBuffer = self
     let srcFlags: CVPixelBufferLockFlags = .readOnly
     guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(srcPixelBuffer, srcFlags) else {
       return nil
     }
     defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, srcFlags) }

     var combinedAttributes: [String: Any] = [:]

     // Copy attachment attributes.
     if let attachments = CVBufferGetAttachments(srcPixelBuffer, .shouldPropagate) as? [String: Any] {
       for (key, value) in attachments {
         combinedAttributes[key] = value
       }
     }

     // Add user attributes.
     combinedAttributes = combinedAttributes.merging(attributes) { $1 }

     var maybePixelBuffer: CVPixelBuffer?
     let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                      CVPixelBufferGetWidth(srcPixelBuffer),
                                      CVPixelBufferGetHeight(srcPixelBuffer),
                                      CVPixelBufferGetPixelFormatType(srcPixelBuffer),
                                      combinedAttributes as CFDictionary,
                                      &maybePixelBuffer)

     guard status == kCVReturnSuccess, let dstPixelBuffer = maybePixelBuffer else {
       return nil
     }

     let dstFlags = CVPixelBufferLockFlags(rawValue: 0)
     guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(dstPixelBuffer, dstFlags) else {
       return nil
     }
     defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, dstFlags) }

     for plane in 0...max(0, CVPixelBufferGetPlaneCount(srcPixelBuffer) - 1) {
       if let srcAddr = CVPixelBufferGetBaseAddressOfPlane(srcPixelBuffer, plane),
          let dstAddr = CVPixelBufferGetBaseAddressOfPlane(dstPixelBuffer, plane) {
         let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(srcPixelBuffer, plane)
         let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dstPixelBuffer, plane)

         for h in 0..<CVPixelBufferGetHeightOfPlane(srcPixelBuffer, plane) {
           let srcPtr = srcAddr.advanced(by: h*srcBytesPerRow)
           let dstPtr = dstAddr.advanced(by: h*dstBytesPerRow)
           dstPtr.copyMemory(from: srcPtr, byteCount: srcBytesPerRow)
         }
       }
     }
     return dstPixelBuffer
   }
    
    /**
      Rotates a CVPixelBuffer by the provided factor of 90 counterclock-wise.
      This function requires the caller to pass in both the source and destination
      pixel buffers. The width and height of destination pixel buffer should be the
      opposite of the source's dimensions if rotating by 90 or 270 degrees.
    */
    public class func rotate90PixelBuffer(from srcPixelBuffer: CVPixelBuffer,
                                    to dstPixelBuffer: CVPixelBuffer,
                                    factor: UInt8) {
      let srcFlags = CVPixelBufferLockFlags.readOnly
      let dstFlags = CVPixelBufferLockFlags(rawValue: 0)

      guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(srcPixelBuffer, srcFlags) else {
        print("Error: could not lock source pixel buffer")
        return
      }
      defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, srcFlags) }

      guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(dstPixelBuffer, dstFlags) else {
        print("Error: could not lock destination pixel buffer")
        return
      }
      defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, dstFlags) }

      guard let srcData = CVPixelBufferGetBaseAddress(srcPixelBuffer),
            let dstData = CVPixelBufferGetBaseAddress(dstPixelBuffer) else {
        print("Error: could not get pixel buffer base address")
        return
      }

      let srcWidth = CVPixelBufferGetWidth(srcPixelBuffer)
      let srcHeight = CVPixelBufferGetHeight(srcPixelBuffer)

      let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPixelBuffer)
      var srcBuffer = vImage_Buffer(data: srcData,
                                    height: vImagePixelCount(srcHeight),
                                    width: vImagePixelCount(srcWidth),
                                    rowBytes: srcBytesPerRow)

      let dstWidth = CVPixelBufferGetWidth(dstPixelBuffer)
      let dstHeight = CVPixelBufferGetHeight(dstPixelBuffer)
      let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dstPixelBuffer)
      var dstBuffer = vImage_Buffer(data: dstData,
                                    height: vImagePixelCount(dstHeight),
                                    width: vImagePixelCount(dstWidth),
                                    rowBytes: dstBytesPerRow)

      var color = UInt8(0)
      let error = vImageRotate90_ARGB8888(&srcBuffer, &dstBuffer, factor, &color, vImage_Flags(0))
      if error != kvImageNoError {
        print("Error:", error)
      }
    }

    /**
      Rotates a CVPixelBuffer by the provided factor of 90 counterclock-wise.
      This allocates a new destination pixel buffer that is Metal-compatible.
    */
    public class func rotate90PixelBuffer(_ srcPixelBuffer: CVPixelBuffer, factor: UInt8) -> CVPixelBuffer? {
      var dstWidth = CVPixelBufferGetWidth(srcPixelBuffer)
      var dstHeight = CVPixelBufferGetHeight(srcPixelBuffer)
      if factor % 2 == 1 {
        swap(&dstWidth, &dstHeight)
      }

      let pixelFormat = CVPixelBufferGetPixelFormatType(srcPixelBuffer)
      let dstPixelBuffer = createPixelBuffer(width: dstWidth, height: dstHeight, pixelFormat: pixelFormat)

      if let dstPixelBuffer = dstPixelBuffer {
        CVBufferPropagateAttachments(srcPixelBuffer, dstPixelBuffer)
        rotate90PixelBuffer(from: srcPixelBuffer, to: dstPixelBuffer, factor: factor)
      }
      return dstPixelBuffer
    }
    
    public static func pixelBuffer (forImage image:CGImage) -> CVPixelBuffer? {
            
            
            let frameSize = CGSize(width: image.width, height: image.height)
            
            var pixelBuffer:CVPixelBuffer? = nil
            let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(frameSize.width), Int(frameSize.height), kCVPixelFormatType_32BGRA , nil, &pixelBuffer)
            
            if status != kCVReturnSuccess {
                return nil
                
            }
            
            CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags.init(rawValue: 0))
            let data = CVPixelBufferGetBaseAddress(pixelBuffer!)
            let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            let context = CGContext(data: data, width: Int(frameSize.width), height: Int(frameSize.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: bitmapInfo.rawValue)
            
            
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            
            CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
            
            return pixelBuffer
            
        }
}
