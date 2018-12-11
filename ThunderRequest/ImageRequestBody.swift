//
//  ImageRequestBody.swift
//  ThunderRequest
//
//  Created by Simon Mitchell on 11/12/2018.
//  Copyright © 2018 threesidedcube. All rights reserved.
//

#if os(macOS)
import AppKit
public typealias Image = NSImage
#else
import UIKit
public typealias Image = UIImage
#endif

extension Image {
    
    /// Image format (jpeg/png/gif e.t.c)
    enum Format {
        case jpeg
        case png
        #if os(macOS)
        case jpeg2000
        case gif
        case bmp
        case tiff
        #endif
        var contentType: String {
            switch self {
            case .jpeg:
                return "image/jpeg"
            case .png:
                return "image/png"
            #if os(macOS)
            case .jpeg2000:
                return "image/jpeg"
            case .gif:
                return "image/gif"
            case .bmp:
                return "image/bmp"
            case .tiff:
                return "image/tiff"
            #endif
            }
        }
        
        #if os(macOS)
        var fileType: NSBitmapImageRep.FileType {
            switch self {
            case .jpeg:
                return .JPEG
            case .jpeg2000:
                return .JPEG2000
            case .png:
                return .PNG
            case .gif:
                return .GIF
            case .bmp:
                return .BMP
            case .tiff:
                return .TIFF
            }
        }
        #endif
    }
    
    func dataFor(format: Format) -> Data? {
        
        #if os(macOS)
        
        guard let bitmapRepresentation = representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep else {
            return nil
        }
        
        return bitmapRepresentation.representation(using: format.fileType, properties: [:])
        #else
        switch format {
        case .jpeg:
            return jpegData(compressionQuality: 2.0)
        default:
            return pngData()
        }
        #endif
    }
}

/// A request body struct which can be used to represent the payload of an
/// image upload
public struct ImageRequestBody: RequestBody {
    
    /// The image that should be uploaded
    let image: Image
    
    /// The image format of the image
    let format: Image.Format
    
    /// Creates a new image upload request body
    ///
    /// - Parameters:
    ///   - image: The image to upload
    ///   - format: The format to apply to the image
    init(image: Image, format: Image.Format) {
        self.image = image
        self.format = format
    }
    
    var contentType: String? {
        return format.contentType
    }
    
    func data() -> Data? {
        return image.dataFor(format: format)
    }
}
