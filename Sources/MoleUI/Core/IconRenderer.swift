import AppKit

/// `MoleUI --icon <path.png>` — draws the app icon, which `build.sh` then
/// converts to .icns. Same arrangement as the author's other apps: the icon is generated from
/// code rather than checked in as a binary, so it stays editable.
///
/// The design is the app's own visual language rather than a generic glyph: soil
/// strata in the same amber and purple as the size bars, cut through by a
/// burrow. Reads as a Mac utility icon at 32pt and still says something at 1024.
enum IconRenderer {

    static func run(path: String) -> Bool {
        let side = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            print("could not allocate bitmap")
            return false
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(side: CGFloat(side))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("could not encode PNG")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(data.count) bytes)")
            return true
        } catch {
            print("write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >> 8) & 0xFF) / 255,
                blue:    CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func draw(side: CGFloat) {
        // macOS icons sit inset inside their canvas with a rounded-rect mask.
        let inset = side * 0.09
        let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = rect.width * 0.2237   // Big Sur-era corner ratio

        let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        body.addClip()

        // Soil, darker toward the bottom.
        NSGradient(colors: [rgb(0x2A231D), rgb(0x14110F)])?
            .draw(in: rect, angle: -90)

        // The burrow, placed first so the strata can be laid out around it.
        let d = rect.width * 0.34
        let hole = NSRect(x: rect.minX + rect.width * 0.53,
                          y: rect.minY + rect.height * 0.36,
                          width: d, height: d)

        // Strata: the same flat bands the app uses for every size breakdown.
        // Bands level with the burrow stop short of it, so the tunnel reads as a
        // cutaway through the ground rather than a circle stamped on top of a
        // list. Bands above and below it run long.
        let strata: [(y: CGFloat, h: CGFloat, w: CGFloat, color: NSColor, alpha: CGFloat)] = [
            (0.79, 0.030, 0.70, rgb(0xE0A756), 0.95),
            (0.72, 0.020, 0.46, rgb(0xE0A756), 0.50),
            (0.62, 0.026, 0.34, rgb(0x8B5CF6), 0.90),
            (0.54, 0.020, 0.28, rgb(0x8B5CF6), 0.45),
            (0.45, 0.026, 0.36, rgb(0xE0A756), 0.70),
            (0.27, 0.032, 0.74, rgb(0x8B5CF6), 0.85),
            (0.19, 0.020, 0.52, rgb(0xE0A756), 0.55),
        ]
        for band in strata {
            let bandRect = NSRect(x: rect.minX + rect.width * 0.12,
                                  y: rect.minY + rect.height * band.y,
                                  width: rect.width * band.w,
                                  height: rect.height * band.h)
            band.color.withAlphaComponent(band.alpha).setFill()
            NSBezierPath(roundedRect: bandRect,
                         xRadius: bandRect.height / 2,
                         yRadius: bandRect.height / 2).fill()
        }

        // Lit from within, so the icon has one focal point instead of seven
        // stripes competing for attention.
        NSGradient(colors: [rgb(0x0A0807), rgb(0x241E1A)])?
            .draw(in: NSBezierPath(ovalIn: hole), angle: -90)

        rgb(0x8B5CF6).setStroke()
        let ring = NSBezierPath(ovalIn: hole.insetBy(dx: -rect.width * 0.010,
                                                     dy: -rect.width * 0.010))
        ring.lineWidth = rect.width * 0.020
        ring.stroke()
    }
}
