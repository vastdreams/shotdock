// Media helpers: read text in a shot (Vision), blur sensitive text, shrink for sending, before/after diff,
// record a short clip and pull frames with freeze detection, stitch a scrolling capture.

import AVFoundation
import Cocoa
import CoreImage
import Vision

enum Media {
    // MARK: text in the shot

    struct TextBox { let text: String; let rect: CGRect }   // rect in image pixels, origin top-left

    static func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func recognize(_ url: URL) -> [TextBox] {
        guard let img = cgImage(url) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let w = CGFloat(img.width), h = CGFloat(img.height)
        return (req.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return TextBox(text: top.string, rect: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }

    /// The text in the shot, top to bottom, for the agent.
    static func text(_ url: URL) -> String {
        recognize(url).sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
            .map(\.text).joined(separator: "\n")
    }

    // MARK: blur

    static let sensitive: [NSRegularExpression] = [
        "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",                 // email
        "\\$\\s?[0-9][0-9,]*(\\.[0-9]+)?[KkMm]?",                  // money
        "\\b(\\+?61|0)[2-478]( ?[0-9]){8}\\b",                     // AU phone
        "\\b[0-9]{3} ?[0-9]{3} ?[0-9]{3}\\b",                      // ABN/ACN-like
        "\\b(sk|glpat|crsr|AKIA)[-_A-Za-z0-9]{8,}",                // keys
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Boxes of text that look like emails, money, phone numbers, company numbers or keys.
    static func sensitiveBoxes(_ url: URL) -> [CGRect] {
        recognize(url).filter { box in
            sensitive.contains { $0.firstMatch(in: box.text, range: NSRange(box.text.startIndex..., in: box.text)) != nil }
        }.map { $0.rect.insetBy(dx: -4, dy: -3) }
    }

    /// Pixelate the given rects (image pixels, top-left origin) in place.
    @discardableResult
    static func blur(_ url: URL, rects: [CGRect]) -> Bool {
        guard !rects.isEmpty, let img = cgImage(url) else { return false }
        let ci = CIImage(cgImage: img)
        let h = CGFloat(img.height)
        var out = ci
        for r in rects {
            let flipped = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height).integral
            let pix = ci.cropped(to: flipped).clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, flipped.height / 2)]).cropped(to: flipped)
            out = pix.composited(over: out)
        }
        return write(out, extent: ci.extent, to: url)
    }

    static func write(_ ci: CIImage, extent: CGRect, to url: URL) -> Bool {
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: extent) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    // MARK: smaller for sending

    /// A copy no wider than 1600 px, JPEG 85%, for pasting into chats. The original stays as it was.
    static func sendable(_ url: URL) -> URL {
        guard let img = NSImage(contentsOf: url), let rep = img.representations.first else { return url }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, 1600 / max(w, 1))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let r2 = NSBitmapImageRep(data: tiff),
              let jpg = r2.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return url }
        let dest = url.deletingPathExtension().appendingPathExtension("send.jpg")
        return (try? jpg.write(to: dest)) != nil ? dest : url
    }

    // MARK: before and after

    /// Side by side, with changed pixels outlined in red on the "after" half.
    static func beforeAfter(before: URL, after: URL) -> URL? {
        guard let a = cgImage(before), let b = cgImage(after) else { return nil }
        let w = CGFloat(max(a.width, b.width)), h = CGFloat(max(a.height, b.height))
        let ca = CIImage(cgImage: a), cb = CIImage(cgImage: b)
        let diff = cb.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: ca])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 4])
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.45)).cropped(to: cb.extent)
        let mask = diff.applyingFilter("CIMaskToAlpha")
        let marked = red.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                             kCIInputMaskImageKey: mask]).composited(over: cb)
        let canvas = marked.transformed(by: CGAffineTransform(translationX: w + 24, y: 0)).composited(over: ca)
            .composited(over: CIImage(color: CIColor(red: 0.08, green: 0.09, blue: 0.12)).cropped(to: CGRect(x: 0, y: 0, width: w * 2 + 24, height: h)))
        let url = newShotURL().deletingPathExtension().appendingPathExtension("compare.png")
        return write(canvas, extent: CGRect(x: 0, y: 0, width: w * 2 + 24, height: h), to: url) ? url : nil
    }

    // MARK: scrolling capture

    /// Stack frames top to bottom, dropping the rows each frame repeats from the one before.
    static func stitch(_ urls: [URL]) -> URL? {
        let imgs = urls.compactMap { cgImage($0) }
        guard let first = imgs.first else { return nil }
        let w = first.width
        var pieces: [(CGImage, Int)] = [(first, 0)]   // image, rows to skip at its top
        for i in 1..<imgs.count {
            let prev = imgs[i - 1], cur = imgs[i]
            pieces.append((cur, overlap(prev, cur)))
        }
        let total = pieces.reduce(0) { $0 + $1.0.height - $1.1 }
        guard let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for (img, skip) in pieces {
            let keep = img.height - skip
            guard let part = img.cropping(to: CGRect(x: 0, y: skip, width: img.width, height: keep)) else { continue }
            y -= keep
            ctx.draw(part, in: CGRect(x: 0, y: y, width: img.width, height: keep))
        }
        guard let out = ctx.makeImage() else { return nil }
        let url = newShotURL().deletingPathExtension().appendingPathExtension("scroll.png")
        let rep = NSBitmapImageRep(cgImage: out)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    /// How many top rows of `cur` repeat the bottom of `prev` (compares a band of rows by sampled pixels).
    static func overlap(_ prev: CGImage, _ cur: CGImage) -> Int {
        func rows(_ img: CGImage) -> [[UInt8]] {
            guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return [] }
            let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
            return (0..<img.height).map { r in stride(from: 0, to: img.width, by: max(1, img.width / 64)).map { p[r * bpr + $0 * bpp] } }
        }
        let a = rows(prev), b = rows(cur)
        guard a.count > 40, b.count > 40 else { return 0 }
        let band = 24
        for shift in stride(from: min(a.count, b.count) - band, through: band, by: -1) {
            // top `shift` rows of b equal the bottom `shift` rows of a?
            var same = true
            for k in stride(from: 0, to: band, by: 3) where a[a.count - shift + k] != b[k] { same = false; break }
            if same { return shift }
        }
        return 0
    }

    // MARK: record a bug

    /// Record `seconds` of the rect, then pull a frame every half second and find frozen stretches.
    static func record(rect: CGRect, seconds: Int, done: @escaping (_ frames: [URL], _ report: String) -> Void) {
        let movie = newShotURL().deletingPathExtension().appendingPathExtension("mov")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-v", "-V", "\(seconds)", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", movie.path]
            try? p.run()
            p.waitUntilExit()
            let asset = AVURLAsset(url: movie)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let length = CMTimeGetSeconds(asset.duration)
            var stills: [(Double, CGImage)] = []
            var t = 0.0
            while t < max(length, 0.5) {
                if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) { stills.append((t, img)) }
                t += 0.5
            }
            // Frozen: consecutive frames with no visible change.
            func sig(_ img: CGImage) -> [UInt8] {
                guard let d = img.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return [] }
                let n = CFDataGetLength(d)
                return stride(from: 0, to: n, by: max(1, n / 4000)).map { p[$0] }
            }
            var frozen: [(Double, Double)] = []
            var runStart: Double?
            for i in 1..<max(stills.count, 1) where stills.count > 1 {
                let same = sig(stills[i].1) == sig(stills[i - 1].1)
                if same && runStart == nil { runStart = stills[i - 1].0 }
                if (!same || i == stills.count - 1), let s = runStart {
                    let end = same ? stills[i].0 : stills[i - 1].0
                    if end - s >= 1.0 { frozen.append((s, end)) }
                    runStart = nil
                }
            }
            // Keep up to 6 frames: evenly spread, plus the start of each frozen stretch.
            var pick = Set<Int>()
            if !stills.isEmpty { for k in 0..<min(4, stills.count) { pick.insert(k * (stills.count - 1) / max(1, min(4, stills.count) - 1)) } }
            for f in frozen.prefix(2) { if let i = stills.firstIndex(where: { $0.0 >= f.0 }) { pick.insert(i) } }
            var urls: [URL] = []
            for i in pick.sorted().prefix(6) {
                let u = movie.deletingPathExtension().appendingPathExtension(String(format: "t%04.1f.png", stills[i].0))
                if let png = NSBitmapImageRep(cgImage: stills[i].1).representation(using: .png, properties: [:]), (try? png.write(to: u)) != nil {
                    urls.append(u)
                }
            }
            let fmt = { (s: Double) in String(format: "0:%04.1f", s) }
            let report = "Screen recording, \(String(format: "%.1f", length)) s, frames at " +
                pick.sorted().prefix(6).map { fmt(stills[$0].0) }.joined(separator: ", ") + ". " +
                (frozen.isEmpty ? "No frozen stretch seen." : "Frozen (no change on screen): " + frozen.map { "\(fmt($0.0))–\(fmt($0.1))" }.joined(separator: ", ") + ".") +
                " Clip: \(movie.path)"
            DispatchQueue.main.async { done(urls, report) }
        }
    }
}
