//
//  MetalRenderer.swift
//  PixelBufferToNV12
//
//  Created by Mark Lim Pak Mun on 28/04/2024.
//  Copyright © 2024 com.incremental.innovation. All rights reserved.
//

import AppKit
import MetalKit
import Accelerate.vImage

class MetalRenderer: NSObject, MTKViewDelegate
{
    var metalView: MTKView!
    var metalDevice: MTLDevice
    var commandQueue: MTLCommandQueue!

    var renderPipelineState: MTLRenderPipelineState!
    var computePipelineState: MTLComputePipelineState!
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    var sourceCGImage: CGImage!

    var srcPixelBuffer: CVPixelBuffer!      // OSType = '420f' (0x34323066)
    var lumaTexture: MTLTexture!
    var chromaTexture: MTLTexture!
    var rgbTexture: MTLTexture!

    init?(view: MTKView, device: MTLDevice)
    {
        self.metalView = view
        self.metalDevice = device
        self.commandQueue = metalDevice.makeCommandQueue()

        super.init()
        buildResources()
        buildPipelineStates()
        texturesFromPixelBuffer(srcPixelBuffer!)
        createRGBTexture()
    }

    // a CVPixelBuffer with a pixel format 420Yp8_CbCr8
    func configureInfo() -> vImage_ARGBToYpCbCr
    {
        var info = vImage_ARGBToYpCbCr()    // filled with zeroes
        
        // full range 8-bit, clamped to full range
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: 0,
            CbCr_bias: 128,
            YpRangeMax: 255,
            CbCrRangeMax: 255,
            YpMax: 255,
            YpMin: 0,
            CbCrMax: 255,
            CbCrMin: 0)
        
        // The contents of `info` object is initialised by the call below. It
        // will be used by the function vImageConvert_ARGB8888To420Yp8_CbCr8
        vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
            &pixelRange,
            &info,
            kvImageARGB8888,
            kvImage420Yp8_CbCr8,
            vImage_Flags(kvImageDoNotTile))
        return info
     }

    func buildResources()
    {
        // Load the graphic image file ...
        guard let url = Bundle.main.urlForImageResource(NSImage.Name("sunflower.jpg"))
        else {
            fatalError("File does not exist at the url")
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            fatalError("Can't create the CGImageSource")
        }
        let options = [
            kCGImageSourceShouldCache : true,
            kCGImageSourceShouldAllowFloat : false
        ] as CFDictionary

        // ... and instantiate an instance of CGImage
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options)
        else {
            fatalError("Can't create the CGImage Object")
        }
        // bitmapInfo = 5 (noneSkipLast - RGBX)
        sourceCGImage = image
        guard let data = sourceCGImage.dataProvider!.data
        else {
            fatalError("Can't access the pixel data")
        }
        let bytes = CFDataGetBytePtr(data)

        let width = sourceCGImage.width
        let height = sourceCGImage.width

        let pixelBufferAttributes = [
            kCGImageSourceShouldCache as String : true,
            kCGImageSourceShouldAllowFloat as String : false,
            kCVPixelBufferIOSurfacePropertiesKey as String : [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String : true,
            kCVPixelBufferBytesPerRowAlignmentKey as String : 16
            ] as CFDictionary

        // Specifying the pixel format as kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // should create a CVPixelBuffer object backed by an IOSurface with 2 planes.
        let cvRet = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            pixelBufferAttributes,
            &srcPixelBuffer)
        guard cvRet == kCVReturnSuccess
        else {
            fatalError("Can't instantiate the CVPixelBuffer object")
        }

        CVPixelBufferLockBaseAddress(srcPixelBuffer!, .readOnly)
        // Notes:
        // OSType: 0x34323066 '420f'
        // Plane 0 width=640 height=640 bytesPerRow=640 (Yp)
        // Plane 1 width=320 height=320 bytesPerRow=640 (CbCr)
        // The 2 planes have the same bytesPerRow value even though
        // the size of plane 1 is a quarter than of plane 0

        // `baseAddress` is an UnsafeMutablePointer to a CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
        // Refer CVPixelBuffer.h
        guard let baseAddress = CVPixelBufferGetBaseAddress(srcPixelBuffer!)?.assumingMemoryBound(to: CVPlanarPixelBufferInfo_YCbCrBiPlanar.self)
        else {
            fatalError("Can't get base address of the source CVPixelBuffer")
        }
        // Create vImage_Buffer objects to convert the pixels from RGB color space
        // to YpCbCr color space
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: bytes),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: sourceCGImage.bytesPerRow)

        // We assume the system's CPU is Little-Endian.
        var dstBufferY = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: baseAddress).advanced(by: Int(baseAddress.pointee.componentInfoY.offset.byteSwapped)),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: Int(baseAddress.pointee.componentInfoY.rowBytes.byteSwapped))

        var dstBufferCbCr = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: baseAddress).advanced(by: Int(baseAddress.pointee.componentInfoCbCr.offset.byteSwapped)),
            height: vImagePixelCount(height / 2),
            width: vImagePixelCount(width / 2),
            rowBytes: Int(baseAddress.pointee.componentInfoCbCr.rowBytes.byteSwapped))

        var info = configureInfo()

        let permuteMap: [UInt8] = [3, 0, 1, 2]
        if vImageConvert_ARGB8888To420Yp8_CbCr8(
            &srcBuffer,
            &dstBufferY,
            &dstBufferCbCr,
            &info,
            permuteMap,         // RGBX --> XRGB
            vImage_Flags(kvImageDoNotTile)) != kvImageNoError {
            fatalError("Can't convert ARGB to YCbCr")
        }
        CVPixelBufferUnlockBaseAddress(srcPixelBuffer!, .readOnly)
    }

    func buildPipelineStates()
    {
        // Load all the shader files with a metal file extension in the project.
        guard let library = metalDevice.makeDefaultLibrary()
        else {
            fatalError("Could not load default library from main bundle")
        }

        // Use a compute shader function to convert YpCbCr colours to rgb colours.
        let kernelFunction = library.makeFunction(name: "YCbCrColorConversion")
        do {
            computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            fatalError("Unable to create compute pipeline state")
        }

        // Instantiate a new instance of MTLTexture to capture the output of kernel function.
        let mtlTextureDesc = MTLTextureDescriptor()
        mtlTextureDesc.textureType = .type2D
        mtlTextureDesc.pixelFormat = .bgra8Unorm
        mtlTextureDesc.width = sourceCGImage.width
        mtlTextureDesc.height = sourceCGImage.height
        mtlTextureDesc.usage = [.shaderRead, .shaderWrite]
        mtlTextureDesc.storageMode = .managed
        rgbTexture = metalDevice.makeTexture(descriptor: mtlTextureDesc)

        /// A compute pipeline state is created to convert the pixels back to RGB color space.
        // To speed up the colour conversion of the RGB texture, utilise all available threads.
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        threadgroupsPerGrid = MTLSizeMake((mtlTextureDesc.width+threadsPerThreadgroup.width-1) / threadsPerThreadgroup.width,
                                          (mtlTextureDesc.height+threadsPerThreadgroup.height-1) / threadsPerThreadgroup.height,
                                          1)

        /// Create the render pipeline state for the drawable render pass.
        // Set up a descriptor for creating a pipeline state object
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Render Quad Pipeline"
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "screen_vert")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "screen_frag")

        pipelineDescriptor.sampleCount = metalView.sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        // The attributes of the vertices are generated on the fly.
        pipelineDescriptor.vertexDescriptor = nil

        do {
            renderPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }

    /*
     The CVPixelBuffer object passed is backed by a biplanar IOSurface.
     It is also Metal compatible.
     Instead of getting lumaTexture and chromaTexture using the function
     CVMetalTextureCacheCreateTextureFromImage, we copy pixels from the 2 planes
     of the CVPixelBuffer to empty MTLTextures that have been properly instantiated
     to the correct dimensions.
     */
    func texturesFromPixelBuffer(_ pixelBuffer: CVPixelBuffer)
    {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        var baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        var bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: lumaWidth, height: lumaHeight,
            mipmapped: false)
        textureDescr.usage = [.shaderRead]
        textureDescr.storageMode = .managed
        lumaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        var region = MTLRegionMake2D(0, 0, lumaTexture!.width, lumaTexture!.height)
        lumaTexture!.replace(region: region,
                             mipmapLevel: 0,
                             withBytes: baseAddress!,
                             bytesPerRow: bytesPerRow)

        let cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        // Re-use the texture descriptor; just change certain properties.
        textureDescr.width = cbcrWidth
        textureDescr.height = cbcrHeight
        textureDescr.pixelFormat = .rg8Unorm
        chromaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        region = MTLRegionMake2D(0, 0, chromaTexture!.width, chromaTexture!.height)
        chromaTexture!.replace(region: region,
                               mipmapLevel: 0,
                               withBytes: baseAddress!,
                               bytesPerRow: bytesPerRow)

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    // Convert the YpCbCr textures back to RGB colorspace
    func createRGBTexture()
    {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        computeCommandEncoder.label = "Compute Encoder"

        computeCommandEncoder.setComputePipelineState(computePipelineState)
        computeCommandEncoder.setTexture(lumaTexture, index: 0)
        computeCommandEncoder.setTexture(chromaTexture, index: 1)
        // The rgbTexture will be modified by the GPU
        computeCommandEncoder.setTexture(rgbTexture, index: 2)
        computeCommandEncoder.dispatchThreadgroups(threadgroupsPerGrid,
                                                    threadsPerThreadgroup: threadsPerThreadgroup)
        computeCommandEncoder.endEncoding()

        // wait
        commandBuffer.addCompletedHandler {
            cb in
            if cb.status == .completed {
                // Managed buffer is updated and synchronized.
                //print("The RGB textures was created successfully.")
            }
            else {
                if cb.status == .error {
                    print("The textures of each face of the Cube Map could be not created")
                    print("Command Buffer Status Error")
                }
                else {
                    print("Command Buffer Status Code: ", commandBuffer.status)
                }
            }
        }
        commandBuffer.commit()
    }

    // Implementation of the MTKViewDelegate method `drawInMTKView:`
    func draw(in view: MTKView)
    {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            return
        }

        // Metal Debugger shows the rgbTexture had been composited correctly.
        //createRGBTexture()
        guard let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }
        commandBuffer.label = "Render Drawable"

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }
        renderEncoder.label = "Render Encoder"
        // Draw the luminance texture on the left side of the view
        var viewPort = MTLViewport(originX: 0.0, originY: 0.0,
                                   width: Double(view.drawableSize.width/2), height: Double(view.drawableSize.height),
                                   znear: -1.0, zfar: 1.0)
        renderEncoder.setViewport(viewPort)
        renderEncoder.setRenderPipelineState(renderPipelineState)

        renderEncoder.setFragmentTexture(lumaTexture,
                                         index : 0)

        // The attributes of the vertices are generated on the fly.
        renderEncoder.drawPrimitives(type: .triangle,
                                     vertexStart: 0,
                                     vertexCount: 3)

        // Draw the chrominance texture on the right side of the view.
        // The chroma texture is displayed as 1/4 of the size of the luma texture.
        viewPort = MTLViewport(originX: Double(view.drawableSize.width/2), originY: 0.0,
                               width: Double(view.drawableSize.width/4), height: Double(view.drawableSize.height/2),
                               znear: -1.0, zfar: 1.0)
        renderEncoder.setViewport(viewPort)

        renderEncoder.setFragmentTexture(chromaTexture,
                                         index : 0)

        renderEncoder.drawPrimitives(type: .triangle,
                                     vertexStart: 0,
                                     vertexCount: 3)

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    {
        // No need to do anything.
    }

}
