// Original vector-drawn Hall-e icon. Run with Swift on macOS, then iconutil.
import AppKit
import Foundation
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
func rounded(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size)/1024)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 64,y:64,width:896,height:896), xRadius:210,yRadius:210)
    NSGradient(starting: NSColor(srgbRed:0.04,green:0.17,blue:0.21,alpha:1), ending:NSColor(srgbRed:0.05,green:0.40,blue:0.40,alpha:1))!.draw(in: background, angle:75)
    rounded(NSRect(x:474,y:700,width:76,height:110),38,NSColor(srgbRed:0.91,green:0.89,blue:0.77,alpha:1))
    NSColor(srgbRed:1,green:0.68,blue:0.32,alpha:1).setFill()
    NSBezierPath(ovalIn:NSRect(x:458,y:788,width:108,height:108)).fill()
    let cream = NSColor(srgbRed:0.95,green:0.94,blue:0.86,alpha:1)
    rounded(NSRect(x:155,y:355,width:714,height:375),155,cream)
    rounded(NSRect(x:211,y:422,width:602,height:238),100,NSColor(srgbRed:0.025,green:0.12,blue:0.16,alpha:1))
    for x: CGFloat in [302,586] {
        rounded(NSRect(x:x,y:480,width:132,height:132),60,NSColor(srgbRed:0.38,green:0.91,blue:0.79,alpha:1))
        rounded(NSRect(x:x+20,y:560,width:25,height:25),12,.white)
    }
    let smile=NSBezierPath(); smile.move(to:NSPoint(x:405,y:287)); smile.curve(to:NSPoint(x:619,y:287),controlPoint1:NSPoint(x:475,y:232),controlPoint2:NSPoint(x:549,y:232)); smile.lineWidth=27; smile.lineCapStyle = .round; cream.setStroke(); smile.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination).appendingPathComponent(name+".png"))
}
