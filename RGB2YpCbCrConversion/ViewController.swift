//
//  ViewController.swift
//  PixelBufferToNV12
//
//  Created by Mark Lim Pak Mun on 28/04/2024.
//  Copyright © 2024 com.incremental.innovation. All rights reserved.
//

import Cocoa
import MetalKit

class ViewController: NSViewController
{

    var metalView: MTKView {
        return self.view as! MTKView
    }

    var metalRenderer: MetalRenderer!

    var ciContext: CIContext!
    var colorSpace: CGColorSpace!

    override func viewDidLoad()
    {
        super.viewDidLoad()
        guard let defaultDevice = MTLCreateSystemDefaultDevice()
        else {
            fatalError("No Metal-capable GPU")
        }
        metalRenderer = MetalRenderer(view: metalView, device: defaultDevice)
        metalView.device = defaultDevice
        metalView.delegate = metalRenderer
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        metalRenderer.mtkView(metalView,
                              drawableSizeWillChange: metalView.drawableSize)

        colorSpace = metalView.colorspace
        if colorSpace == nil {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        let options = [CIContextOption.outputColorSpace : colorSpace!]
        ciContext = CIContext(mtlDevice: metalView.device!,
                              options: options)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    override func viewDidAppear()
    {
        metalView.window!.makeFirstResponder(self)
    }

    func save(mtlTextures: [MTLTexture], to folderURL: URL) throws
    {
        let fmgr = FileManager.`default`
        var isDir = ObjCBool(false)
        // Check the folder at url exist.
        if !fmgr.fileExists(atPath: folderURL.path,
                            isDirectory: &isDir) {
            // The file/directory does not exist; just, create the destination folder.
            try fmgr.createDirectory(at: folderURL,
                                     withIntermediateDirectories: true,
                                     attributes: nil)
        }
        else {
            // file or folder exists
            // Make sure it is not an ordinary data file
            if !isDir.boolValue {
                print("A file exists at the location:", folderURL)
                print("Cannot save the two textures")
                return
            }
        }

        // The files "luma.jpg" and "chroma.jpg" will be written out to the destination folder.
        let lumaURL = folderURL.appendingPathComponent("luma").appendingPathExtension("jpg")
        let chromaURL = folderURL.appendingPathComponent("chroma").appendingPathExtension("jpg")
        let fileURLS = [lumaURL, chromaURL]

        for i in 0...1 {
            var ciImage = CIImage(mtlTexture: mtlTextures[i],
                                  options: [CIImageOption.colorSpace: colorSpace!])!
            var transform = CGAffineTransform(translationX: 0.0,
                                              y: ciImage.extent.height)
            // We need to flip the image vertically.
            transform = transform.scaledBy(x: 1.0, y: -1.0)
            ciImage = ciImage.transformed(by: transform)
            do {
                try ciContext.writeJPEGRepresentation(of: ciImage,
                                                      to: fileURLS[i],
                                                      colorSpace: colorSpace!,
                                                      options: [:])
            }
            catch let err {
                throw err
            }
        }
    }

    override func keyDown(with event: NSEvent)
    {
        // Press 's' or 'S'; ESC to cancel
        if event.keyCode == 0x1 {
            guard
                let   lumaTexture = metalRenderer.lumaTexture,
                let chromaTexture =  metalRenderer.chromaTexture
            else {
                super.keyDown(with: event)
                return
            }
            let sp = NSSavePanel()
            sp.canCreateDirectories = true
            sp.nameFieldLabel = "Save to Folder:"   // We are saving to a folder
            sp.nameFieldStringValue = "textures"    // Default name of the folder
            let button = sp.runModal()

            if (button == NSApplication.ModalResponse.OK) {
                var folderURL = sp.url!
                // Strip away the file extension; the program will append it later.
                let ext = folderURL.pathExtension
                if !ext.isEmpty {
                    folderURL.deletePathExtension()
                }
                do {
                    try self.save(mtlTextures: [lumaTexture, chromaTexture],
                                  to: folderURL)
                }
                catch let err {
                    Swift.print(err)
                }
            }
        }
        else {
            super.keyDown(with: event)
        }
    }

}

