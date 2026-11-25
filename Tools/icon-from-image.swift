// Turns a square logo picture (on a white background) into a 1024 px macOS icon:
// finds the rounded square, cuts away the white around it and centres it on the icon grid.
import AppKit
let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!
var rect = CGRect(origin: .zero, size: src.size)
let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y*w + x)*4
    if max(p[i], p[i+1], p[i+2]) < 120 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) }
}}
maxY = minY + (maxX - minX)  // ignore the drop shadow under the square
let inset = 8
let crop = CGRect(x: minX+inset, y: minY+inset, width: maxX-minX-2*inset, height: maxY-minY-2*inset)
print("shape bounds", minX, minY, maxX, maxY)
let body = cg.cropping(to: crop)!
let S = 1024, content = CGFloat(824), off = (CGFloat(S) - content)/2
let out = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let box = CGRect(x: off, y: off, width: content, height: content)
// soft shadow like system icons
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
let path = CGPath(roundedRect: box, cornerWidth: content*0.27, cornerHeight: content*0.27, transform: nil)
out.addPath(path); out.setFillColor(NSColor.black.cgColor); out.fillPath()
out.restoreGState()
out.addPath(path); out.clip()
out.draw(body, in: box)
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
