import BackgroundTasks
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import OiseauCore

/// Photos before upload (Android: data/PhotoPrep.kt): at most PhotoPrep.maxDim on the
/// long side, the EXIF rotation applied to the pixels, JPEG at PhotoPrep.quality. A
/// small, upright JPEG is sent as it is.
struct ImagePhotoPreparer: PhotoPreparer {
    func prepare(_ original: Data) async -> Data {
        await Task.detached(priority: .userInitiated) { Self.prepareSync(original) }.value
    }

    static func prepareSync(_ original: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return original }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let type = CGImageSourceGetType(source) as String?
        let plan = PhotoPrep.plan(width: width, height: height, rotationDegrees: PhotoPrep.rotationDegrees(exifOrientation: orientation), byteCount: original.count)
        if plan == .keep, type == UTType.jpeg.identifier { return original }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF rotation into the pixels
            kCGImageSourceThumbnailMaxPixelSize: PhotoPrep.maxDim,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: CGFloat(PhotoPrep.quality) / 100) else { return original }
        return jpeg
    }
}

/// The offline queue drained in the background (Android: WorkManager). iOS gives no
/// guarantee of when: the queue also drains at launch, in the foreground and as soon
/// as the server answers again.
@MainActor
enum BackgroundSync {
    static let identifier = "ch.oiseaupourri.sync"
    static weak var app: AppModel?

    /// Once, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                schedule() // the next one, in case some stay parked
                await app?.drain()
                task.setTaskCompleted(success: true)
            }
        }
    }

    static func schedule() {
        guard !AppConfig.stubApi else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
