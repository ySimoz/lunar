import AppKit
import Foundation

/// Single inline image attachment parsed from or composed into card Markdown without exposing raw base64 in editors.
public struct CardAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let dataURI: String
    public let byteCount: Int

    public init(
        id: UUID = UUID(),
        label: String,
        dataURI: String,
        byteCount: Int? = nil
    ) {
        self.id = id
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = cleanLabel.isEmpty ? "Image" : cleanLabel
        self.dataURI = dataURI
        self.byteCount = byteCount ?? CardAttachmentCodec.decodedByteCount(from: dataURI)
    }

    public var markdownTag: String {
        "![\(label)](\(dataURI))"
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, byteCount)), countStyle: .file)
    }
}

/// Atomic inline text-attachment holding a `CardAttachment` inside `NSTextView` so images can live
/// anywhere between paragraphs/LaTeX without showing raw base64 strings or breaking on Backspace.
public final class LunarImageAttachment: NSTextAttachment {
    public let cardAttachment: CardAttachment

    public init(cardAttachment: CardAttachment) {
        self.cardAttachment = cardAttachment
        super.init(data: nil, ofType: nil)
        self.image = CardAttachmentCodec.inlineBadgeImage(for: cardAttachment)
        self.bounds = CGRect(x: 0, y: -4, width: 176, height: 44)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Extracts, composes, serializes, and normalizes inline base64 Markdown image attachments
/// so editors stay clean text/LaTeX and support interleaved multi-image workflows.
public enum CardAttachmentCodec {
    public static let lunarLabelPasteboardType = NSPasteboard.PasteboardType("app.lunar.image-label")

    private static let dataURIImagePattern = #"!\[([^\]]*)\]\((data:image/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=\s]+)\)"#
    private static let maxImageDimension: CGFloat = 960
    private static let pngCompressionThresholdBytes = 280_000

    /// Extracts ordered image attachments and cleaned plain text/LaTeX from raw Markdown.
    public static func extract(from rawMarkdown: String) -> (cleanText: String, attachments: [CardAttachment]) {
        guard rawMarkdown.contains("data:image/"),
              let regex = try? NSRegularExpression(pattern: dataURIImagePattern) else {
            return (rawMarkdown, [])
        }

        let ns = rawMarkdown as NSString
        let matches = regex.matches(in: rawMarkdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return (rawMarkdown, [])
        }

        var attachments: [CardAttachment] = []
        let mutable = NSMutableString(string: rawMarkdown)

        for match in matches.reversed() {
            let att = makeAttachment(from: match, in: ns)
            attachments.insert(att, at: 0)
            mutable.replaceCharacters(in: match.range, with: "")
        }

        let collapsed = collapseBlankLines(mutable as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (collapsed, attachments)
    }

    /// Recombines plain text/LaTeX and appended image attachments into Markdown.
    public static func compose(text: String, attachments: [CardAttachment]) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageBlocks = attachments.map(\.markdownTag)

        if trimmedText.isEmpty {
            return imageBlocks.joined(separator: "\n\n")
        }
        if imageBlocks.isEmpty {
            return trimmedText
        }
        return trimmedText + "\n\n" + imageBlocks.joined(separator: "\n\n")
    }

    /// Removes only the `targetIndex`-th image tag from raw Markdown while preserving surrounding text and order.
    public static func removingAttachment(at targetIndex: Int, from rawMarkdown: String) -> String {
        guard targetIndex >= 0,
              rawMarkdown.contains("data:image/"),
              let regex = try? NSRegularExpression(pattern: dataURIImagePattern) else {
            return rawMarkdown
        }

        let ns = rawMarkdown as NSString
        let matches = regex.matches(in: rawMarkdown, range: NSRange(location: 0, length: ns.length))
        guard targetIndex < matches.count else { return rawMarkdown }

        let mutable = NSMutableString(string: rawMarkdown)
        mutable.replaceCharacters(in: matches[targetIndex].range, with: "")
        return collapseBlankLines(mutable as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts interleaved Markdown (`text` + `![alt](data:image/...)`) into an `NSAttributedString`
    /// with atomic `LunarImageAttachment` pills placed at each image's exact position.
    public static func attributedString(
        from rawMarkdown: String,
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        textColor: NSColor = .labelColor
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        guard rawMarkdown.contains("data:image/"),
              let regex = try? NSRegularExpression(pattern: dataURIImagePattern) else {
            return NSAttributedString(string: rawMarkdown, attributes: baseAttrs)
        }

        let ns = rawMarkdown as NSString
        let matches = regex.matches(in: rawMarkdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return NSAttributedString(string: rawMarkdown, attributes: baseAttrs)
        }

        let result = NSMutableAttributedString()
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let prefix = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(NSAttributedString(string: prefix, attributes: baseAttrs))
            }

            let attachment = makeAttachment(from: match, in: ns)
            let pill = LunarImageAttachment(cardAttachment: attachment)
            let pillAttr = NSMutableAttributedString(attachment: pill)
            pillAttr.addAttributes(baseAttrs, range: NSRange(location: 0, length: pillAttr.length))
            result.append(pillAttr)

            cursor = match.range.location + match.range.length
        }

        if cursor < ns.length {
            let suffix = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            result.append(NSAttributedString(string: suffix, attributes: baseAttrs))
        }

        return result
    }

    /// Serializes an `NSAttributedString` back to Markdown, replacing each inline `LunarImageAttachment`
    /// with its `![label](dataURI)` at its exact text position.
    public static func markdown(from attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else { return "" }

        var output = ""
        let fullRange = NSRange(location: 0, length: attributedString.length)

        attributedString.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if let imageAtt = value as? LunarImageAttachment {
                output += imageAtt.cardAttachment.markdownTag
            } else {
                let chunk = attributedString.attributedSubstring(from: range).string
                output += chunk.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }

        return output
    }

    /// Decodes a data-URI attachment into an `NSImage` for thumbnail display.
    public static func thumbnailImage(for attachment: CardAttachment) -> NSImage? {
        guard let commaIdx = attachment.dataURI.firstIndex(of: ",") else { return nil }
        let base64 = String(attachment.dataURI[attachment.dataURI.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return NSImage(data: data)
    }

    /// Renders a crisp monochrome inline pill thumbnail for `NSTextAttachment` display inside editors.
    public static func inlineBadgeImage(for attachment: CardAttachment) -> NSImage {
        let size = NSSize(width: 176, height: 44)
        let rendered = NSImage(size: size)
        rendered.lockFocus()

        let bounds = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 2.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor.gray.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.gray.withAlphaComponent(0.38).setStroke()
        path.lineWidth = 1
        path.stroke()

        let thumbRect = NSRect(x: 6, y: 7, width: 46, height: 30)
        if let thumb = thumbnailImage(for: attachment) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4).addClip()
            thumb.draw(in: thumbRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.gray.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4).fill()
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let maxTextWidth: CGFloat = size.width - 66
        (attachment.label as NSString).draw(
            with: NSRect(x: 58, y: 22, width: maxTextWidth, height: 15),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttrs
        )
        (attachment.formattedSize as NSString).draw(
            with: NSRect(x: 58, y: 8, width: maxTextWidth, height: 13),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: sizeAttrs
        )

        rendered.unlockFocus()
        return rendered
    }

    /// Computes a non-generic sequential image label (`Graph: ...` when provided, or `Image 1`, `Image 2`, ...).
    public static func nextImageLabel(
        preferredLabel: String? = nil,
        in existingMarkdown: String = ""
    ) -> String {
        let existingLabels = extract(from: existingMarkdown).attachments.map(\.label)
        let existingSet = Set(existingLabels)

        if let preferred = preferredLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            if !existingSet.contains(preferred) {
                return preferred
            }
            var suffix = 2
            while existingSet.contains("\(preferred) (\(suffix))") {
                suffix += 1
            }
            return "\(preferred) (\(suffix))"
        }

        var nextIndex = existingLabels.count + 1
        for label in existingLabels where label.hasPrefix("Image ") {
            if let num = Int(label.dropFirst("Image ".count)) {
                nextIndex = max(nextIndex, num + 1)
            }
        }
        while existingSet.contains("Image \(nextIndex)") {
            nextIndex += 1
        }
        return "Image \(nextIndex)"
    }

    /// Reads an image from the macOS pasteboard when no plain string takes priority (or unconditionally when requested).
    public static func readPasteboardImage(
        from pasteboard: NSPasteboard = .general,
        existingMarkdown: String = "",
        ignoreIfPlainTextPresent: Bool = true
    ) -> CardAttachment? {
        if ignoreIfPlainTextPresent,
           let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        let preferredLabel = pasteboard.string(forType: lunarLabelPasteboardType)
        let resolvedLabel = nextImageLabel(preferredLabel: preferredLabel, in: existingMarkdown)

        if let pngData = pasteboard.data(forType: .png),
           let image = NSImage(data: pngData) {
            return encodeImage(image, preferredPNGData: pngData, label: resolvedLabel)
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData) {
            return encodeImage(image, label: resolvedLabel)
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = images.first {
            return encodeImage(first, label: resolvedLabel)
        }

        return nil
    }

    /// Compresses/resizes an `NSImage` so pasted screenshots stay well under the 1 MB card payload limit.
    public static func encodeImage(
        _ image: NSImage,
        preferredPNGData: Data? = nil,
        label: String = "Image"
    ) -> CardAttachment? {
        if let preferredPNGData, preferredPNGData.count <= pngCompressionThresholdBytes {
            let uri = "data:image/png;base64,\(preferredPNGData.base64EncodedString())"
            return CardAttachment(label: label, dataURI: uri, byteCount: preferredPNGData.count)
        }

        let targetSize = clampedPixelSize(for: image)
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        if let pngData = rep.representation(using: .png, properties: [:]),
           pngData.count <= pngCompressionThresholdBytes {
            let uri = "data:image/png;base64,\(pngData.base64EncodedString())"
            return CardAttachment(label: label, dataURI: uri, byteCount: pngData.count)
        }

        if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) {
            let uri = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
            return CardAttachment(label: label, dataURI: uri, byteCount: jpegData.count)
        }

        return nil
    }

    static func decodedByteCount(from dataURI: String) -> Int {
        guard let commaIdx = dataURI.firstIndex(of: ",") else { return 0 }
        let b64Count = dataURI.distance(from: dataURI.index(after: commaIdx), to: dataURI.endIndex)
        return max(0, (b64Count * 3) / 4)
    }

    private static func makeAttachment(from match: NSTextCheckingResult, in ns: NSString) -> CardAttachment {
        let labelRange = match.range(at: 1)
        let uriRange = match.range(at: 2)
        let label = labelRange.location != NSNotFound ? ns.substring(with: labelRange) : "Image"
        let rawURI = uriRange.location != NSNotFound ? ns.substring(with: uriRange) : ""
        let compactURI = rawURI.components(separatedBy: .whitespacesAndNewlines).joined()
        return CardAttachment(label: label, dataURI: compactURI)
    }

    private static func clampedPixelSize(for image: NSImage) -> NSSize {
        let rep = image.representations.first
        let rawWidth = CGFloat(rep?.pixelsWide ?? 0) > 0 ? CGFloat(rep?.pixelsWide ?? 0) : image.size.width
        let rawHeight = CGFloat(rep?.pixelsHigh ?? 0) > 0 ? CGFloat(rep?.pixelsHigh ?? 0) : image.size.height
        guard rawWidth > 0, rawHeight > 0 else { return .zero }

        let maxDim = max(rawWidth, rawHeight)
        guard maxDim > maxImageDimension else {
            return NSSize(width: round(rawWidth), height: round(rawHeight))
        }
        let scale = maxImageDimension / maxDim
        return NSSize(width: max(1, round(rawWidth * scale)), height: max(1, round(rawHeight * scale)))
    }

    private static func collapseBlankLines(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }
}
