import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Rating Composite Service

class RatingCompositeService {
    struct Layout {
        let totalWidth: CGFloat
        let imageWidth: CGFloat
        let panelWidth: CGFloat
        let padding: CGFloat
        let lineSpacing: CGFloat
        let sectionSpacing: CGFloat
        let font: NSFont
        let boldFont: NSFont
        static let `default` = Layout(
            totalWidth: 3200,
            imageWidth: 2000,
            panelWidth: 1200,
            padding: 64,
            lineSpacing: 16,
            sectionSpacing: 28,
            font: NSFont.systemFont(ofSize: 90),
            boldFont: NSFont.boldSystemFont(ofSize: 100)
        )
    }

    func renderComposite(original image: NSImage,
                         rating: ImageRating,
                         fileName: String) throws -> NSImage {
        let layout = Layout.default

        // Compute scaled height for image preserving aspect
        let aspect = image.size.height == 0 ? 1 : (image.size.width / image.size.height)
        let imageHeight = layout.imageWidth / max(aspect, 0.01)

        // Precompute panel height based on text
        let panelHeight = measuredPanelHeight(layout: layout, rating: rating, fileName: fileName)
        let totalHeight = max(imageHeight, panelHeight)
        let totalSize = CGSize(width: layout.totalWidth, height: ceil(totalHeight))

        let composite = NSImage(size: totalSize)
        composite.lockFocus()

        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: totalSize)).fill()

        // Draw original scaled into left rect (centered vertically within total height)
        let imageRect = CGRect(x: 0, y: 0, width: layout.imageWidth, height: totalHeight)
        draw(image: image, in: imageRect)

        // Draw rating panel on right with full available height
        let panelRect = CGRect(x: layout.imageWidth, y: 0, width: layout.panelWidth, height: totalHeight)
        drawPanel(in: panelRect, layout: layout, rating: rating, fileName: fileName)

        composite.unlockFocus()
        return composite
    }

    func writeJPEG(_ image: NSImage, to url: URL, quality: CGFloat = 0.95) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw PhotoWorkflowError.unableToWriteFile(path: url.path, underlyingError: nil)
        }
        try data.write(to: url)
    }

    // MARK: - Private

    private func draw(image: NSImage, in rect: CGRect) {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return }
        let scale = min(rect.width / srcSize.width, rect.height / srcSize.height)
        let drawSize = CGSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let x = rect.origin.x + (rect.width - drawSize.width) / 2
        let y = rect.origin.y + (rect.height - drawSize.height) / 2
        image.draw(in: CGRect(x: x, y: y, width: drawSize.width, height: drawSize.height))
    }

    private func drawPanel(in rect: CGRect, layout: Layout, rating: ImageRating, fileName: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: layout.boldFont,
            .foregroundColor: NSColor.black
        ]
        let scoreAttrs: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: NSColor.black
        ]
        let notesAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 90),
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: paragraph
        ]
        let criteriaAttrs: [NSAttributedString.Key: Any] = [
            .font: italicFont(ofSize: 50),
            .foregroundColor: NSColor.gray,
            .paragraphStyle: paragraph
        ]
        let overallAttrs: [NSAttributedString.Key: Any] = [
            .font: layout.boldFont,
            .foregroundColor: NSColor.systemBlue
        ]

        var cursorY = rect.maxY - layout.padding

        // Categories
        for entry in rating.entries {
            // Category name
            let nameHeight = heightFor(text: entry.categoryName, attributes: nameAttrs, width: rect.width - 2 * layout.padding)
            let nameRect = CGRect(x: rect.minX + layout.padding, y: cursorY - nameHeight, width: rect.width - 2 * layout.padding, height: nameHeight)
            entry.categoryName.draw(in: nameRect, withAttributes: nameAttrs)
            cursorY = nameRect.minY - layout.lineSpacing

            // Criteria
            let criteriaText = criteriaFor(categoryName: entry.categoryName, mode: rating.mode)
            if !criteriaText.isEmpty {
                let critFull = "Evaluation Criteria: " + criteriaText
                let critHeight = heightFor(text: critFull, attributes: criteriaAttrs, width: rect.width - 2 * layout.padding)
                let critRect = CGRect(x: rect.minX + layout.padding, y: cursorY - critHeight, width: rect.width - 2 * layout.padding, height: critHeight)
                critFull.draw(in: critRect, withAttributes: criteriaAttrs)
                cursorY = critRect.minY - layout.lineSpacing
            }

            // Score
            let scoreText = "Score: \(entry.score ?? 0)/5"
            let scoreHeight = heightFor(text: scoreText, attributes: scoreAttrs, width: rect.width - 2 * layout.padding)
            let scoreRect = CGRect(x: rect.minX + layout.padding, y: cursorY - scoreHeight, width: rect.width - 2 * layout.padding, height: scoreHeight)
            scoreText.draw(in: scoreRect, withAttributes: scoreAttrs)
            cursorY = scoreRect.minY - layout.lineSpacing

            // Notes
            let notesText = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notesText.isEmpty {
                let fullNotes = "Notes:\n" + notesText
                let notesHeight = heightFor(text: fullNotes, attributes: notesAttrs, width: rect.width - 2 * layout.padding)
                let notesRect = CGRect(x: rect.minX + layout.padding, y: cursorY - notesHeight, width: rect.width - 2 * layout.padding, height: notesHeight)
                fullNotes.draw(in: notesRect, withAttributes: notesAttrs)
                cursorY = notesRect.minY - layout.sectionSpacing
            } else {
                cursorY -= layout.sectionSpacing
            }
        }

        // Overall score
        let earned = rating.entries.reduce(0) { $0 + ($1.score ?? 0) }
        let possible = max(rating.entries.count * 5, 1)
        let percent = Int((Double(earned) / Double(possible) * 100.0).rounded())
        let overallText = "Overall Image Score: \(earned)/\(possible)  (\(percent)%)"
        let overallHeight = heightFor(text: overallText, attributes: overallAttrs, width: rect.width - 2 * layout.padding)
        let overallRect = CGRect(x: rect.minX + layout.padding, y: max(rect.minY + layout.padding, cursorY - overallHeight), width: rect.width - 2 * layout.padding, height: overallHeight)
        overallText.draw(in: overallRect, withAttributes: overallAttrs)
    }

    private func measuredPanelHeight(layout: Layout, rating: ImageRating, fileName: String) -> CGFloat {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: layout.boldFont,
            .foregroundColor: NSColor.black
        ]
        let scoreAttrs: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: NSColor.black
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let notesAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 90),
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: paragraph
        ]
        let criteriaAttrs: [NSAttributedString.Key: Any] = [
            .font: italicFont(ofSize: 50),
            .foregroundColor: NSColor.gray,
            .paragraphStyle: paragraph
        ]
        let contentWidth = layout.panelWidth - 2 * layout.padding
        var height: CGFloat = layout.padding
        for entry in rating.entries {
            height += heightFor(text: entry.categoryName, attributes: nameAttrs, width: contentWidth)
            height += layout.lineSpacing
            let criteriaText = criteriaFor(categoryName: entry.categoryName, mode: rating.mode)
            if !criteriaText.isEmpty {
                let critFull = "Evaluation Criteria: " + criteriaText
                height += heightFor(text: critFull, attributes: criteriaAttrs, width: contentWidth)
                height += layout.lineSpacing
            }
            let scoreText = "Score: \(entry.score ?? 0)/5"
            height += heightFor(text: scoreText, attributes: scoreAttrs, width: contentWidth)
            height += layout.lineSpacing
            let notesText = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notesText.isEmpty {
                let fullNotes = "Notes:\n" + notesText
                height += heightFor(text: fullNotes, attributes: notesAttrs, width: contentWidth)
                height += layout.sectionSpacing
            } else {
                height += layout.sectionSpacing
            }
        }
        let earned = rating.entries.reduce(0) { $0 + ($1.score ?? 0) }
        let possible = max(rating.entries.count * 5, 1)
        let percent = Int((Double(earned) / Double(possible) * 100.0).rounded())
        let overallText = "Overall Image Score: \(earned)/\(possible)  (\(percent)%)"
        height += heightFor(text: overallText, attributes: nameAttrs, width: contentWidth)
        height += layout.padding
        return height
    }

    private func heightFor(text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> CGFloat {
        let nsText = text as NSString
        let rect = nsText.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return ceil(rect.height)
    }

    private func criteriaFor(categoryName: String, mode: AdminModeType) -> String {
        let categories: [RatingCategory]
        switch mode {
        case .sports:
            categories = RatingPresets.sportsCategories
        case .school:
            categories = RatingPresets.schoolCategories
        }
        return categories.first(where: { $0.name == categoryName })?.criteria ?? ""
    }

    private func italicFont(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
}


