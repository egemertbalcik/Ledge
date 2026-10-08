import SwiftUI
import Testing
@testable import LedgeUI

/// Writes a filmstrip of the island's deforming silhouette to /tmp, so the
/// shape can be looked at rather than reasoned about.
@Suite("Sag filmstrip", .disabled(if: ProcessInfo.processInfo.environment["LEDGE_SAG_SHEET"] != "1"))
@MainActor
struct NotesSagSheetTests {

    @Test("Render the sag filmstrip")
    func render() throws {
        struct Sheet: View {
            var body: some View {
                HStack(alignment: .top, spacing: 20) {
                    ForEach([0.0, 0.10, 0.20, 0.30, 0.38, 0.46], id: \.self) { t in
                        VStack(spacing: 6) {
                            LedgeShape(
                                bottomRadius: 22, gutterRadius: 11,
                                cornerSmoothing: 0.6, trailingInset: 0,
                                cornerSag: NotesBirthView.sag(at: t)
                            )
                            .fill(.black)
                            .frame(width: 240, height: 180)
                            Spacer(minLength: 0)
                            Text(String(format: "%.2f", t))
                                .font(.system(size: 12)).foregroundStyle(.black)
                        }
                        .frame(height: 300)
                    }
                }
                .padding(20)
                .background(.white)
            }
        }
        let renderer = ImageRenderer(content: Sheet())
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/sagsheet.png"))
    }
}
