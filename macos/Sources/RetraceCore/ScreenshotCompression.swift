import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps the original pixel geometry for computer-use coordinates and readable small controls.
public enum ScreenshotCompression {
    public static let targetBytes = 512 * 1024

    public static func jpeg(_ image: CGImage, quality: Double = 0.78) -> Data? {
        var smallest: Data?
        let initial = min(1, max(0.55, quality))
        for q in [initial, min(initial, 0.68), min(initial, 0.55)] {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if smallest == nil || data.length < smallest!.count { smallest = data as Data }
            if data.length <= targetBytes { return data as Data }
        }
        // shortcut: complex images may exceed the target; retain detail rather than shrink UI text.
        return smallest
    }
}
