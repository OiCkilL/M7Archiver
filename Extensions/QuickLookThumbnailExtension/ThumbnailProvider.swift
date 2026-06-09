import AppKit
import QuickLookThumbnailing
import ArchiveCore

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ completionHandler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        let format = ArchiveTypeDetector().detectByExtension(fileName: request.fileURL.lastPathComponent)

        let size = request.maximumSize
        let reply = QLThumbnailReply(contextSize: size) { context in
            Self.drawThumbnail(in: context, size: size, format: format, fileURL: request.fileURL)
            return true
        }
        completionHandler(reply, nil)
    }

    private static func drawThumbnail(in context: CGContext, size: CGSize, format: ArchiveFormat?, fileURL: URL) {
        let rect = CGRect(origin: .zero, size: size)

        // Draw system file icon at the requested thumbnail size
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = size  // request high-res representation for target size
        var imageRect = CGRect(origin: .zero, size: size)
        if let cgImage = icon.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) {
            context.draw(cgImage, in: rect)
        }

        // Overlay format badge in bottom-right corner
        let label = format?.rawValue.uppercased() ?? "?"
        let badgeSize = min(size.width, size.height) * 0.45
        let badgeRect = CGRect(
            x: rect.maxX - badgeSize - 3,
            y: rect.maxY - badgeSize - 3,
            width: badgeSize,
            height: badgeSize
        )

        // Clip badge to rounded rect
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(badgePath)
        context.clip()

        // Draw gradient badge background
        let colors = Self.colors(for: format)
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [colors.top, colors.bottom] as CFArray,
            locations: nil
        )
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: badgeRect.midX, y: badgeRect.minY),
                end: CGPoint(x: badgeRect.midX, y: badgeRect.maxY),
                options: []
            )
        }

        // Draw format label in badge
        context.resetClip()
        let fontSize = badgeSize * 0.5
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: label, attributes: attr)
        let textSize = attrStr.size()
        let textOrigin = CGPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        )
        attrStr.draw(at: textOrigin)
    }

    private static func colors(for format: ArchiveFormat?) -> (top: CGColor, bottom: CGColor) {
        switch format {
        case .sevenZip:
            return (CGColor(red: 0.27, green: 0.55, blue: 0.91, alpha: 1),
                    CGColor(red: 0.18, green: 0.42, blue: 0.78, alpha: 1))
        case .zip:
            return (CGColor(red: 0.84, green: 0.65, blue: 0.25, alpha: 1),
                    CGColor(red: 0.72, green: 0.52, blue: 0.13, alpha: 1))
        case .rar:
            return (CGColor(red: 0.65, green: 0.35, blue: 0.85, alpha: 1),
                    CGColor(red: 0.52, green: 0.22, blue: 0.72, alpha: 1))
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .gzip, .bzip2, .xz, .zstd:
            return (CGColor(red: 0.35, green: 0.68, blue: 0.55, alpha: 1),
                    CGColor(red: 0.22, green: 0.55, blue: 0.42, alpha: 1))
        default:
            return (CGColor(red: 0.45, green: 0.50, blue: 0.58, alpha: 1),
                    CGColor(red: 0.32, green: 0.37, blue: 0.45, alpha: 1))
        }
    }
}
