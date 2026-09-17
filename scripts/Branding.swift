// Grove's marks: the app icon in all ten sizes, the volume icon on the mounted
// disk image, and the installer window's artwork.
//
// The logo itself is not drawn here — it is `Branding/app-icon-source.png`,
// which this script crops, cuts to the icon shape and scales. Everything around
// it is drawn in code, because it carries the version number and would go stale
// one release after it was right.
//
// Run through scripts/branding.sh, never directly — that script is what turns
// the iconset into an .icns and the two background PNGs into a Retina TIFF.

import AppKit
import QuartzCore

// MARK: - The logo

enum Artwork {

    /// The square taken out of `Branding/app-icon-source.png`.
    ///
    /// The source is a 1254px canvas with the icon on a flat backdrop. The icon
    /// as drawn is 997×976 — near enough to square to look right, not square
    /// enough to use — so this is the widest centred square inside it. The
    /// twenty-one columns that go are the left and right edges of a rounded
    /// corner that gets recut here anyway.
    ///
    /// Measured off the file rather than guessed, and stated rather than
    /// detected, because a crop that is a few pixels out fails silently: it
    /// just yields a slightly off-centre icon, which nobody notices until it is
    /// sitting next to another one in the Dock.
    static let tile = CGRect(x: 139, y: 129, width: 976, height: 976)

    /// Apple's continuous corner. The source artwork is drawn to it, so the cut
    /// follows the shape that is already there rather than imposing a new one.
    static let cornerRatio: CGFloat = 0.2246

    /// How far inside the measured edge to cut, in source pixels.
    ///
    /// The artwork's edge is anti-aliased against its backdrop, so those pixels
    /// are part backdrop. Masking exactly on the edge keeps them and they read
    /// as a dark rim — obvious the moment the icon sits on anything pale.
    private static let bleed: CGFloat = 2.5

    /// The logo, cropped out of the source and cut to the icon shape, at
    /// 1024px with everything outside the shape transparent.
    static func master(root: String) -> CGImage {
        let path = "\(root)/Branding/app-icon-source.png"
        guard let source = NSImage(contentsOfFile: path),
            let full = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let cropped = full.cropping(to: tile)
        else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            exit(1)
        }

        let side: CGFloat = 1024
        let overscan = side / tile.width * bleed
        let image = NSImage(cgImage: cropped, size: tile.size)

        return render(width: Int(side), height: Int(side)) { ctx in
            // Drawn a touch larger than the canvas, so the rim lands outside
            // the mask instead of inside it.
            image.draw(
                in: CGRect(
                    x: -overscan, y: -overscan,
                    width: side + overscan * 2, height: side + overscan * 2))

            cut(ctx, to: CGRect(x: 0, y: 0, width: side, height: side))
        }.cgImage!
    }

    /// Clips what has already been drawn to the icon's rounded square.
    ///
    /// The shape is rendered to its own bitmap and then composited, rather than
    /// drawn straight into the context: `CALayer.render(in:)` resets the blend
    /// mode it is handed, so compositing the layer directly leaves the corners
    /// exactly as they were. Drawing the resulting image does respect it.
    private static func cut(_ ctx: CGContext, to rect: CGRect) {
        ctx.saveGState()
        ctx.setBlendMode(.destinationIn)
        ctx.draw(shape(side: rect.width), in: rect)
        ctx.restoreGState()
    }

    /// The icon's outline, opaque inside and transparent outside.
    ///
    /// A `CALayer` because `cornerCurve = .continuous` is the only API that
    /// draws Apple's actual corner; a plain rounded rectangle is circular-arc
    /// cornered and reads as pinched next to every other icon in the Dock.
    private static func shape(side: CGFloat) -> CGImage {
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = side * cornerRatio
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        return render(width: Int(side), height: Int(side)) { ctx in
            layer.render(in: ctx)
        }.cgImage!
    }
}

// MARK: - Colours

/// The window around the logo. Greens are read off the artwork so the installer
/// and the icon are the same green, not two greens that nearly match.
enum Brand {
    static let accent = NSColor(hex: 0x5C_B85C)
    static let connector = NSColor(hex: 0xC2_E2C2)

    // DMG window, light appearance.
    static let canvasTop = NSColor(hex: 0xFF_FFFF)
    static let canvasBottom = NSColor(hex: 0xEF_F2F6)
    static let card = NSColor(hex: 0xFF_FFFF)
    static let hairline = NSColor(hex: 0xE1_E6EC)
    static let ink = NSColor(hex: 0x1F_2328)
    static let inkMuted = NSColor(hex: 0x6E_7781)
}

// MARK: - App icon

enum AppIcon {

    /// Apple's icon grid: the artwork body is 824/1024 of the canvas, leaving a
    /// margin the system expects to be empty. Filling the canvas edge to edge
    /// is what makes a third-party icon look a size too large in the Dock.
    private static let bodyRatio: CGFloat = 824.0 / 1024.0

    static func image(pixels: Int, master: CGImage) -> NSBitmapImageRep {
        let side = CGFloat(pixels)

        // A 16px icon that keeps the 1024px proportions spends two of its
        // sixteen pixels on margin and another two on the corners. Apple's own
        // small sizes are drawn tighter for the same reason; this is theirs.
        let body = (side * (pixels <= 32 ? 0.875 : bodyRatio)).rounded()
        let origin = ((side - body) / 2).rounded()
        let image = NSImage(cgImage: master, size: CGSize(width: body, height: body))

        return render(width: pixels, height: pixels) { _ in
            image.draw(in: CGRect(x: origin, y: origin, width: body, height: body))
        }
    }
}

// MARK: - Disk image window

enum DiskImageArt {

    /// The Finder window the installer opens in, in points. The two icon slots
    /// and this size have to agree with the `--window-size` and `--icon`
    /// coordinates in scripts/release.sh, which is why both are stated here.
    static let size = CGSize(width: 660, height: 400)
    static let appSlot = CGPoint(x: 180, y: 196)
    static let applicationsSlot = CGPoint(x: 480, y: 196)

    static func background(version: String, scale: CGFloat) -> NSBitmapImageRep {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)

        return render(width: width, height: height) { ctx in
            ctx.scaleBy(x: scale, y: scale)

            gradient(
                ctx, from: Brand.canvasTop, to: Brand.canvasBottom,
                in: CGRect(origin: .zero, size: size))

            // A card under both slots, for a reason that is not decoration:
            // Finder draws the icon labels itself, in black under the light
            // appearance and white under the dark one. Keeping them over white
            // is what stops "Applications" from disappearing on a dark desktop.
            let card = CGRect(x: 56, y: 112, width: 548, height: 200)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -3), blur: 14,
                color: NSColor(white: 0.45, alpha: 0.13).cgColor)
            ctx.setFillColor(Brand.card.cgColor)
            ctx.addPath(
                CGPath(
                    roundedRect: card, cornerWidth: 20, cornerHeight: 20,
                    transform: nil))
            ctx.fillPath()
            ctx.restoreGState()

            ctx.addPath(
                CGPath(
                    roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                    cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setStrokeColor(Brand.hairline.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()

            connector(ctx)
            header(ctx, version: version)

            text(
                "Drag Grove into your Applications folder",
                font: .systemFont(ofSize: 12.5, weight: .regular),
                color: Brand.inkMuted, centeredAt: CGPoint(x: size.width / 2, y: 348))
        }
    }

    /// The line between the two slots: a commit node, a lane, an arrow — the
    /// same three shapes the logo is built from, which is the whole reason the
    /// window needs no further ornament.
    private static func connector(_ ctx: CGContext) {
        let y = appSlot.y
        let start = CGPoint(x: 272, y: y)
        let end = CGPoint(x: 388, y: y)

        ctx.setStrokeColor(Brand.connector.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: start.x + 10, y: y))
        ctx.addLine(to: CGPoint(x: end.x - 9, y: y))
        ctx.strokePath()

        ctx.setFillColor(Brand.accent.cgColor)
        ctx.fillEllipse(in: CGRect(x: start.x - 4.5, y: y - 4.5, width: 9, height: 9))

        ctx.setStrokeColor(Brand.accent.cgColor)
        ctx.setLineWidth(2.4)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: end.x - 9, y: y - 7))
        ctx.addLine(to: CGPoint(x: end.x, y: y))
        ctx.addLine(to: CGPoint(x: end.x - 9, y: y + 7))
        ctx.strokePath()
    }

    /// Wordmark and version, and deliberately no logo: the icon is about to
    /// appear at 128px in the card below, and a 36px copy of it above only
    /// competes with the thing the window is asking you to drag.
    private static func header(_ ctx: CGContext, version: String) {
        text(
            "Grove", font: .systemFont(ofSize: 27, weight: .semibold), color: Brand.ink,
            centeredAt: CGPoint(x: size.width / 2, y: 64))

        text(
            version, font: .systemFont(ofSize: 11, weight: .medium),
            color: Brand.inkMuted, tracking: 0.9,
            centeredAt: CGPoint(x: size.width / 2, y: 90))
    }
}

// MARK: - Drawing helpers

/// Renders into a bitmap whose origin is **top left**, so every coordinate in
/// this file reads the way the layout does.
func render(width: Int, height: Int, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: CGFloat(height))
    cg.scaleBy(x: 1, y: -1)
    cg.setAllowsAntialiasing(true)
    cg.interpolationQuality = .high

    // AppKit drawing needs to be told the context is already flipped; without
    // this every string and every image comes out upside down.
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    body(cg)
    NSGraphicsContext.current = previous

    return rep
}

func gradient(_ ctx: CGContext, from top: NSColor, to bottom: NSColor, in rect: CGRect) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top.cgColor, bottom.cgColor] as CFArray,
        locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: [])
    ctx.restoreGState()
}

func attributed(
    _ string: String, font: NSFont, color: NSColor, tracking: CGFloat
)
    -> NSAttributedString
{
    NSAttributedString(
        string: string,
        attributes: [.font: font, .foregroundColor: color, .kern: tracking])
}

func measure(_ string: String, font: NSFont, tracking: CGFloat = 0) -> CGFloat {
    attributed(string, font: font, color: .black, tracking: tracking).size().width
}

func text(
    _ string: String, font: NSFont, color: NSColor, tracking: CGFloat = 0, at point: CGPoint
) {
    attributed(string, font: font, color: color, tracking: tracking).draw(at: point)
}

func text(
    _ string: String, font: NSFont, color: NSColor, tracking: CGFloat = 0,
    centeredAt point: CGPoint
) {
    let line = attributed(string, font: font, color: color, tracking: tracking)
    let size = line.size()
    line.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
}

extension NSColor {
    /// `0xRRGGBB` in sRGB, matching Sources/DesignSystem/Palette.swift.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Output

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(
        Data("usage: Branding.swift <root> <version> <build-dir>\n".utf8))
    exit(2)
}
let root = arguments[1]
let version = arguments[2]
let build = arguments[3]

let files = FileManager.default
let iconset = "\(build)/Grove.iconset"
try? files.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let master = Artwork.master(root: root)

// The ten entries the Asset Catalog wants, and the names `iconutil` insists on.
let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let appIconSet = "\(root)/Sources/App/Assets.xcassets/AppIcon.appiconset"
var manifest: [[String: String]] = []

for entry in entries {
    let pixels = entry.size * entry.scale
    let rep = AppIcon.image(pixels: pixels, master: master)
    let suffix = entry.scale == 1 ? "" : "@2x"
    let name = "AppIcon-\(entry.size)\(suffix).png"

    write(rep, to: "\(appIconSet)/\(name)")
    write(rep, to: "\(iconset)/icon_\(entry.size)x\(entry.size)\(suffix).png")

    manifest.append([
        "idiom": "mac", "size": "\(entry.size)x\(entry.size)",
        "scale": "\(entry.scale)x", "filename": name,
    ])
}

let contents: [String: Any] = [
    "images": manifest,
    "info": ["author": "grove", "version": 1],
]
try! JSONSerialization
    .data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(appIconSet)/Contents.json"))

// The logo on its own, transparent outside the icon shape — what README, the
// GitHub release page and anything else showing the mark should use.
write(
    render(width: 1024, height: 1024) { _ in
        NSImage(cgImage: master, size: CGSize(width: 1024, height: 1024))
            .draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    },
    to: "\(root)/Branding/grove-icon.png")

write(
    DiskImageArt.background(version: version, scale: 1),
    to: "\(build)/dmg-background.png")
write(
    DiskImageArt.background(version: version, scale: 2),
    to: "\(build)/dmg-background@2x.png")

print("branding: icons and \(version) disk image artwork written")
