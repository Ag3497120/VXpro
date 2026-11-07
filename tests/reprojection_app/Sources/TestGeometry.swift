// SPDX-License-Identifier: MIT
import Foundation
import simd
import Metal
import CoreText
import CoreGraphics

struct TestVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var uv = SIMD2<Float>(-1, -1)
}

func testSceneOrigin(_ head: simd_float4x4) -> simd_float4x4 {
    let horizontal = SIMD3<Float>(-head.columns.2.x,0,-head.columns.2.z)
    let forward = simd_length(horizontal) > 0.01 ? simd_normalize(horizontal) : SIMD3<Float>(0,0,-1)
    let right = simd_cross(forward,SIMD3<Float>(0,1,0))
    return simd_float4x4(SIMD4<Float>(right,0),.init(0,1,0,0),SIMD4<Float>(-forward,0),head.columns.3)
}

struct TestMesh {
    var vertices: [TestVertex] = []
    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       _ color: SIMD4<Float>, textured: Bool = false) {
        let positions = [a,b,c,a,c,d]
        let uv: [SIMD2<Float>] = [.init(0,1),.init(1,1),.init(1,0),.init(0,1),.init(1,0),.init(0,0)]
        for i in 0..<6 {
            vertices.append(TestVertex(position: SIMD4<Float>(positions[i],1), color: color,
                                       uv: textured ? uv[i] : .init(-1,-1)))
        }
    }
    mutating func rect(x: Float, y: Float, z: Float, w: Float, h: Float, color: SIMD4<Float>) {
        quad(.init(x,y,z),.init(x+w,y,z),.init(x+w,y+h,z),.init(x,y+h,z),color)
    }
    static func grid() -> TestMesh {
        var m = TestMesh()
        m.rect(x: -4, y: -2.5, z: -3.1, w: 8, h: 5, color: .init(0.025,0.035,0.05,1))
        for i in -20...20 {
            let x = Float(i) * 0.2
            m.rect(x: x-0.006, y: -2.5, z: -3, w: 0.012, h: 5, color: .init(0.2,0.36,0.4,1))
        }
        for i in -12...12 {
            let y = Float(i) * 0.2
            m.rect(x: -4, y: y-0.006, z: -3, w: 8, h: 0.012, color: .init(0.2,0.36,0.4,1))
        }
        // Two depths expose positional reprojection as well as rotational correction.
        for x: Float in [-0.6,0.6] {
            m.rect(x: x-0.018, y: -0.4, z: -1.1, w: 0.036, h: 0.8, color: .init(0.85,0.7,0.25,1))
        }
        m.rect(x: -0.012, y: -0.15, z: -2.9, w: 0.024, h: 0.3, color: .init(0.85,0.9,0.95,1))
        m.rect(x: -0.15, y: -0.012, z: -2.9, w: 0.3, h: 0.024, color: .init(0.85,0.9,0.95,1))
        return m
    }
    static func sphere() -> TestMesh {
        var m = TestMesh()
        func p(_ a: Float, _ b: Float) -> SIMD3<Float> { .init(cos(a)*sin(b),cos(b),sin(a)*sin(b)) }
        for j in 0..<12 { for i in 0..<24 {
            let a = Float(i)*2*Float.pi/24, aa = Float(i+1)*2*Float.pi/24
            let b = Float(j)*Float.pi/12, bb = Float(j+1)*Float.pi/12
            let n = p((a+aa)/2,(b+bb)/2)
            let light = 0.35 + 0.65 * max(0,simd_dot(n,simd_normalize(SIMD3<Float>(-1,1,1))))
            m.quad(p(a,b),p(aa,b),p(aa,bb),p(a,bb),.init(0.2*light,0.85*light,0.95*light,1))
        } }
        return m
    }
    mutating func digits(_ number: UInt64, count: Int, x: Float, y: Float, scale: Float) {
        let bits = [0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f]
        let bars: [(Float,Float,Float,Float)] = [(0.1,0.9,0.5,0.1),(0.6,0.5,0.1,0.4),(0.6,0.1,0.1,0.4),
            (0.1,0,0.5,0.1),(0,0.1,0.1,0.4),(0,0.5,0.1,0.4),(0.1,0.45,0.5,0.1)]
        var n = number
        for k in (0..<count).reversed() {
            let digit = Int(n % 10); n /= 10
            for b in 0..<7 where bits[digit] & (1 << b) != 0 {
                let q = bars[b]
                rect(x: x+(Float(k)*0.9+q.0)*scale, y: y+q.1*scale,z: -1.8,
                     w: q.2*scale,h: q.3*scale,color: .init(0.75,0.8,0.85,1))
            }
        }
    }
    static func labelPlane() -> TestMesh {
        var m = TestMesh()
        m.quad(.init(-0.92,0.48,-2.5),.init(0.92,0.48,-2.5),.init(0.92,0.98,-2.5),.init(-0.92,0.98,-2.5),
               .init(1,1,1,1),textured: true)
        return m
    }
    func buffer(_ device: MTLDevice) -> MTLBuffer {
        vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    }
}

func testLabel(device: MTLDevice, title: String, instruction: String) -> MTLTexture {
    let w = 1024, h = 256
    var bytes = [UInt8](repeating:0,count:w*h*4)
    bytes.withUnsafeMutableBytes { raw in
        let color = CGColorSpace(name:CGColorSpace.sRGB)!
        let ctx = CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                            space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red:0.025,green:0.035,blue:0.05,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h))
        for (text,size,y) in [(title,48.0,158.0),(instruction,35.0,78.0)] {
            let font = CTFontCreateWithName("HiraginoSans-W4" as CFString,size,nil)
            let s = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.92,alpha:1)])
            ctx.textPosition = CGPoint(x:30,y:y);CTLineDraw(CTLineCreateWithAttributedString(s),ctx)
        }
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:w,height:h,mipmapped:false)
    desc.storageMode = .shared;desc.usage = .shaderRead
    let t = device.makeTexture(descriptor:desc)!
    bytes.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4) }
    return t
}
