import Foundation
import simd
import XCTest
@testable import LiveWallpaper

final class SceneBoneScriptTests: XCTestCase {
    private func makeRig() -> SceneBonePose {
        var parent = matrix_identity_float4x4, child = matrix_identity_float4x4
        parent.columns.3 = SIMD4(20, 10, 0, 1)
        child.columns.3 = SIMD4(7, 3, 0, 1)
        return SceneBonePose(bones: [
            .init(name: "support", parent: -1, bind: parent),
            .init(name: "小风铃", parent: 0, bind: child,
                  physics: .init(["t": true, "r": true, "m": 2, "ts": 120, "tf": 12])),
        ])
    }

    func testNamedBoneThroughScriptUsesParentAndLayerSpace() throws {
        let rig = makeRig()
        rig.layerToScene = simd_float4x4(columns: (SIMD4(0,2,0,0), SIMD4(-3,0,0,0), SIMD4(0,0,1,0), SIMD4(80,70,0,1)))
        let runtime = try XCTUnwrap(WEScript(script: """
            let index;
            export function init() { index = thisLayer.getBoneIndex('小风铃'); }
            export function update() { return thisLayer.getBoneCount() + thisLayer.getBoneParentIndex(index); }
            export function cursorClick(e) {
                thisLayer.setBoneTransform(index, thisLayer.getBoneTransform(index).translation(e.worldPosition));
                shared.localX = thisLayer.getLocalBoneOrigin(index).x;
                const layer = thisLayer.getTransformMatrix();
                shared.mesh = layer.inverse().transformPoint(e.worldPosition).x;
                shared.uniform = Mat4.fromScale(2).determinant();
                shared.roundTrip = layer.inverse().multiply(layer).equals(Mat4.identity());
            }
            """, propertyOverrides: [:], tag: "unrelated author"))
        runtime.setTemplateLayerIdentity(id: 71, name: "toy", parentId: nil, visible: true, alpha: 1, color: SIMD4(repeating: 1))
        XCTAssertNil(runtime.runScalar(current: 0, simTime: 0))
        runtime.bindBones([71: rig])
        XCTAssertEqual(runtime.runScalar(current: 0, simTime: 0), 2)
        runtime.dispatchCursor(.click, world: SIMD2(50, 150), local: SIMD2(0,0))
        let result = try XCTUnwrap(rig.transform(1, inScene: true))
        XCTAssertEqual(result.columns.3.x, 50, accuracy: 1e-4)
        XCTAssertEqual(result.columns.3.y, 150, accuracy: 1e-4)
        XCTAssertEqual(rig.transform(1, inScene: false)!.columns.3.x, 20, accuracy: 1e-4)
        let shared = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(runtime.sharedJSON().utf8)) as? [String: Any])
        XCTAssertEqual(shared["mesh"] as? Double, 40)
        XCTAssertEqual(shared["uniform"] as? Double, 8)
        XCTAssertEqual(shared["roundTrip"] as? Bool, true)
        XCTAssertFalse(runtime.didFail)
    }

    func testTargetedImpulseResetAndSpringStayLocalToInstance() throws {
        let rig = makeRig(), other = makeRig()
        let original = rig.world[1].columns.3
        rig.impulse(1, direction: SIMD3(100, 30, 0), angular: SIMD3(0, 0, 1))
        rig.advance(frameTime: 1.0/60, animatedLocal: nil)
        XCTAssertGreaterThan(rig.world[1].columns.3.x, original.x)
        XCTAssertNotEqual(rig.world[1].columns.0.y, 0)
        XCTAssertEqual(rig.world[0].columns.3.x, 20)
        XCTAssertEqual(other.world[1].columns.3, original)
        for _ in 0..<240 { rig.advance(frameTime: 1.0/60, animatedLocal: nil) }
        XCTAssertEqual(rig.world[1].columns.3.x, original.x, accuracy: 0.01)
        rig.reset(nil)
        XCTAssertEqual(rig.world[1].columns.3, original)
    }

    func testScriptCanAddressAnotherLayerAndCannotWriteNonfinitePose() throws {
        let rig = makeRig()
        let s = try XCTUnwrap(WEScript(script: """
            export function cursorClick() {
                const puppet = thisScene.getLayer('chimes');
                shared.count = puppet.getBoneCount();
                puppet.setLocalBoneOrigin('小风铃', new Vec3(14,5,0));
                puppet.applyBonePhysicsImpulse(1, new Vec3(2,0,0));
            }
            """, propertyOverrides: [:], tag: "controller"))
        s.setSceneLayers([.init(id: 9, name: "chimes", parentId: nil, visible: true, alpha: 1,
                               color: SIMD4(repeating: 1), origin: .zero, scale: .one, angles: .zero, size: .zero)])
        s.bindBones([9: rig])
        s.dispatchCursor(.click, world: .zero, local: .zero)
        XCTAssertEqual(rig.transform(1, inScene: false)?.columns.3.x, 14)
        var invalid = matrix_identity_float4x4
        invalid.columns.3.x = .nan
        rig.setTransform(invalid, 1, inScene: true)
        XCTAssertEqual(rig.transform(1, inScene: false)?.columns.3.x, 14)
    }

    /// A static, unanimated triangle with a translated child bone and rigid, blended and unweighted vertices.
    func testStaticPuppetScriptDeformsOnlyWeightedVertices() throws {
        var mdl = Data("MDLV0023\0".utf8)
        func uint(_ n: UInt32) {
            var value = n.littleEndian
            withUnsafeBytes(of: &value) { mdl.append(contentsOf: $0) }
        }
        uint(0); uint(3 * 80)
        for i in 0..<3 {
            let coords: [Float] = [Float(i * 12), Float(i * 4)]
            coords.forEach { uint($0.bitPattern) }
            mdl.append(Data(repeating: 0, count: 32)) // normals/tangent
            [0, 1, 0, 0].forEach { uint($0) }
            let weight = Float(i) / 2
            [1 - weight, weight, 0, 0, 0.25, 0.5].forEach { uint($0.bitPattern) }
        }
        uint(6); mdl.append(contentsOf: [0, 0, 1, 0, 2, 0])
        mdl.append(Data("MDLS0004\0".utf8)); uint(0); uint(2)
        for (i,name) in ["hanger", "wind-chime-鈴"].enumerated() {
            mdl.append(Data(name.utf8)); mdl.append(0)
            uint(UInt32(50 + i)); uint(i == 0 ? UInt32.max : 0); uint(64)
            var m = matrix_identity_float4x4
            m.columns.3.x = Float(i * 8)
            m.columnMajor.forEach { uint($0.bitPattern) }
            mdl.append(0)
        }
        let mesh = try XCTUnwrap(PuppetMesh.parse(mdl, size: .init(100, 100), readScriptBones: true))
        XCTAssertFalse(mesh.hasSkin) // no MDLA section or authored animation
        let rig = SceneBonePose(bones: mesh.scriptBones)
        let s = try XCTUnwrap(WEScript(script: """
            export function cursorDown(event) {
                const index = thisLayer.getBoneIndex("wind-chime-鈴");
                thisLayer.setBoneTransform(index, thisLayer.getBoneTransform(index).translation(event.worldPosition));
            }
            """, propertyOverrides: [:], tag: "unpublished animated triangle"))
        s.setTemplateLayerIdentity(id: 17, name: "mobile", parentId: nil, visible: true, alpha: 1, color: .one)
        s.bindBones([17: rig])
        s.dispatchCursor(.down, world: .init(28, 10), local: .zero)
        let result = mesh.skinVerts(world: rig.world)
        for i in 0..<3 {
            let offset = 4 * i
            let w = Float(i) / 2
            XCTAssertEqual(result[offset] - mesh.bindVerts[offset], 0.2 * w, accuracy: 1e-5)
            XCTAssertEqual(result[offset+1] - mesh.bindVerts[offset+1], 0.1 * w, accuracy: 1e-5)
            XCTAssertEqual(Array(result[(offset+2)...(offset+3)]), [0.25, 0.5])
        }
    }
}
