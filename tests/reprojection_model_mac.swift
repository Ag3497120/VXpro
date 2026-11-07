// SPDX-License-Identifier: MIT
import Foundation
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers

@main struct ReprojectionChecks {
    static func main() throws {
        for (time, mode) in [(0.0,TestPlan.full),(14.99,.full),(15,.half),(30,.third),(45,.full),(60,.full)] {
            precondition(TestPlan.automatic.phase(at:time).mode == mode)
        }
        precondition(!TestPlan.automatic.phase(at:59.99).finished && TestPlan.automatic.phase(at:60).finished)
        precondition(!TestPlan.full.phase(at:8).lookAround && TestPlan.full.phase(at:15).lookAround)
        for step in 1...3 {
            var m = CadenceMeter()
            for i in 0...120 { m.add(time:Double(i*step)/90+100,index:UInt64(i*step+1000)) }
            precondition(abs(m.submissionHz-90/Double(step))<1e-8)
            precondition(abs(m.scheduledDisplayHz-90)<1e-8)
            precondition(m.unsubmittedSlots == UInt64(120*(step-1)))
            m.add(time:.nan,index:0); m.add(time:m.lastTime,index:m.lastIndex)
            precondition(m.invalidPairs == 2 && m.count == 121)
        }
        var hundred = CadenceMeter()
        for i in 0...100 { hundred.add(time:Double(i)*0.03,index:UInt64(i*3)) }
        precondition(abs(hundred.submissionHz-100/3)<1e-8 && abs(hundred.scheduledDisplayHz-100)<1e-8)
        precondition(MemoryLayout<TestVertex>.stride == 48)
        var vertical = matrix_identity_float4x4;vertical.columns.2 = .init(0,1,0,0)
        let origin = testSceneOrigin(vertical)
        precondition(origin.columns.0.x.isFinite && origin.columns.2.z.isFinite)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal required") }
        let library = try device.makeLibrary(URL:URL(fileURLWithPath:CommandLine.arguments[1]))
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name:"test_vertex"); pd.fragmentFunction = library.makeFunction(name:"test_fragment")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb; pd.depthAttachmentPixelFormat = .depth32Float
        let pipe = try device.makeRenderPipelineState(descriptor:pd)
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .greaterEqual; dd.isDepthWriteEnabled = true
        let ds = device.makeDepthStencilState(descriptor:dd)!
        let grid = TestMesh.grid(), ball = TestMesh.sphere(), panel = TestMesh.labelPlane()
        let gb = grid.buffer(device), bb = ball.buffer(device), pb = panel.buffer(device)
        let text = testLabel(device:device,title:"30 FPS相当 ／ Apple補正の比較",instruction:"頭を止めて、左右に動く球を見る")
        let n:Float = 0.1, f:Float = 20
        let projection = simd_float4x4(.init(1,0,0,0),.init(0,1,0,0),.init(0,0,n/(f-n),-1),.init(0,0,n*f/(f-n),0))
        for (z, expected) in [(-n,Float(1)),(-f,Float(0))] {
            let p = projection * SIMD4<Float>(0,0,z,1);precondition(abs(p.z/p.w-expected)<1e-5)
        }
        func render(eye:Float, ballX:Float, gridLast:Bool) -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:512,height:512,mipmapped:false)
            desc.usage = [.renderTarget,.shaderRead];desc.storageMode = .shared
            let color = device.makeTexture(descriptor:desc)!
            desc.pixelFormat = .depth32Float;desc.storageMode = .private
            let depth = device.makeTexture(descriptor:desc)!
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = color;rp.colorAttachments[0].loadAction = .clear;rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = depth;rp.depthAttachment.loadAction = .clear;rp.depthAttachment.storeAction = .store;rp.depthAttachment.clearDepth = 0
            let cb = queue.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor:rp)!
            e.setRenderPipelineState(pipe);e.setDepthStencilState(ds);e.setCullMode(.none);e.setFragmentTexture(text,index:0)
            var view = matrix_identity_float4x4;view.columns.3.x = -eye
            func draw(_ b:MTLBuffer,_ count:Int,_ model:simd_float4x4) {
                var m = projection*view*model
                e.setVertexBuffer(b,offset:0,index:0);e.setVertexBytes(&m,length:64,index:1)
                e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:count)
            }
            if !gridLast { draw(gb,grid.vertices.count,matrix_identity_float4x4) }
            var model = matrix_identity_float4x4
            model.columns.0.x = 0.12;model.columns.1.y = 0.12;model.columns.2.z = 0.12;model.columns.3 = .init(ballX,0,-1.8,1)
            draw(bb,ball.vertices.count,model)
            if gridLast { draw(gb,grid.vertices.count,matrix_identity_float4x4) }
            draw(pb,panel.vertices.count,matrix_identity_float4x4)
            var id = TestMesh();id.digits(12345,count:5,x:0.03,y:-0.55,scale:0.07)
            draw(id.buffer(device),id.vertices.count,matrix_identity_float4x4)
            e.endEncoding();cb.commit();cb.waitUntilCompleted();precondition(cb.status == .completed)
            var pixels = [UInt8](repeating:0,count:512*512*4)
            pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!,bytesPerRow:512*4,from:MTLRegionMake2D(0,0,512,512),mipmapLevel:0) }
            return pixels
        }
        let left = render(eye:-0.032,ballX:0,gridLast:false), right = render(eye:0.032,ballX:0,gridLast:false)
        let swapped = render(eye:-0.032,ballX:0,gridLast:true)
        precondition(left == swapped, "depth must preserve near/far occlusion independent of draw order")
        func centroid(_ p:[UInt8]) -> Double {
            var count = 0, x = 0
            for y in 210..<300 { for i in 220..<300 {
                let k = (y*512+i)*4
                if p[k] > 190 && p[k+1] > 170 && p[k+2] < 110 { count += 1;x += i }
            } }
            precondition(count>40,"sphere must be visible")
            return Double(x)/Double(count)
        }
        let disparity = centroid(left)-centroid(right)
        precondition(disparity > 5 && disparity < 14,"independent eye transforms must produce stereo disparity")
        let moved = render(eye:-0.032,ballX:0.65,gridLast:false)
        precondition(moved != left,"animation must change only on new source rendering")
        let data = Data(left) as CFData
        let image = CGImage(width:512,height:512,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:2048,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
            provider:CGDataProvider(data:data)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let url = URL(fileURLWithPath:CommandLine.arguments[2])
        let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,image,nil);precondition(CGImageDestinationFinalize(dest))
        print("Cadence: 90/45/30 and 100/50/33 schedules, phase boundaries, invalid timestamps: passed")
        print("Metal: reverse-Z, depth occlusion, source animation, stereo disparity \(disparity) pixels: passed")
    }
}
