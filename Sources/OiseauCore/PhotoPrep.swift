import Foundation

/// Shrinks a photo before it travels (Android: data/PhotoPrep.kt; web: imageResize.ts):
/// long edge at most [maxDim] px, JPEG [quality], EXIF orientation baked into the
/// pixels (the re-encode drops the metadata, so a portrait shot would come out
/// sideways — and the GPS tags go with it). The server re-encodes to WebP anyway;
/// this is about upload size on a mobile connection, so a small original is kept as is.
///
/// The decisions are here; the decoding and encoding (ImageIO) are the app's
/// [PhotoPreparer].
public enum PhotoPrep {
    public static let maxDim = 1600
    /// JPEG quality, 0–100 (ImageIO wants 0.82).
    public static let quality = 82
    /// Kept untouched below this size if it also fits [maxDim] (web: 1 MB).
    public static let smallBytes = 1_000_000

    /// What to do with one photo.
    public enum Plan: Equatable, Sendable {
        /// Upload the original bytes: small, upright, or not an image (the server will say).
        case keep
        /// Decode at 1/[sampleSize] (a power of two: a 50 MP photo never sits in memory at
        /// full size), rotate by [rotationDegrees], and encode at [width]×[height].
        case reencode(sampleSize: Int, rotationDegrees: Int, width: Int, height: Int)
    }

    /// [width]×[height]: the stored pixels (before the EXIF rotation); 0 when it isn't an image.
    public static func plan(width: Int, height: Int, rotationDegrees: Int, byteCount: Int, maxDim: Int = maxDim) -> Plan {
        guard width > 0, height > 0 else { return .keep }
        let longEdge = max(width, height)
        if longEdge <= maxDim && rotationDegrees == 0 && byteCount < smallBytes { return .keep }
        var sample = 1
        while longEdge / (sample * 2) >= maxDim { sample *= 2 }
        let decodedW = width / sample, decodedH = height / sample
        let scale = min(1, Double(maxDim) / Double(max(decodedW, decodedH)))
        var w = Int((Double(decodedW) * scale).rounded()), h = Int((Double(decodedH) * scale).rounded())
        let quarterTurn = (rotationDegrees % 180 + 180) % 180 == 90
        if quarterTurn { swap(&w, &h) }
        return .reencode(sampleSize: sample, rotationDegrees: rotationDegrees, width: w, height: h)
    }

    /// A re-encode that grew (rare: an already tiny, unrotated JPEG) isn't worth it.
    public static func keepsReencoded(rotationDegrees: Int, reencodedBytes: Int, originalBytes: Int) -> Bool {
        rotationDegrees != 0 || reencodedBytes < originalBytes
    }

    /// EXIF orientation (1–8) → clockwise degrees to turn the pixels by.
    public static func rotationDegrees(exifOrientation: Int) -> Int {
        switch exifOrientation {
        case 3, 4: return 180
        case 5, 6: return 90
        case 7, 8: return 270
        default: return 0
        }
    }
}

/// Turns a picked or shot image into the JPEG bytes to upload, following [PhotoPrep]
/// (ImageIO in the app; the identity in tests).
public protocol PhotoPreparer: Sendable {
    func prepare(_ original: Data) async -> Data
}
