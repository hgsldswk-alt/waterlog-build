import SwiftUI
import UIKit

enum ExportFiles {
    static func write(_ data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(filename)
        do {
            try data.write(to: path, options: .atomic)
            return path
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

struct SharedItems: Identifiable {
    let id = UUID()
    let values: [Any]
    var temporaryFile: URL?
}

struct SharePresentation {
    struct Request {
        let type: String
        let byteCount: Int
    }

    var items: SharedItems?
    var request: Request?

    mutating func present(_ items: SharedItems, type: String, uiTesting: Bool) throws {
        guard uiTesting else {
            self.items = items
            return
        }

        let byteCount: Int
        if let file = items.temporaryFile {
            defer { ExportFiles.remove(file) }
            byteCount = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } else {
            byteCount = (items.values.first as? String)?.utf8.count ?? 0
        }
        guard byteCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        request = Request(type: type, byteCount: byteCount)
    }
}

extension View {
    func sharePresentation(_ presentation: Binding<SharePresentation>) -> some View {
        sheet(item: presentation.items) { ActivitySheet(items: $0) }
            .overlay(alignment: .bottom) {
                if let request = presentation.wrappedValue.request {
                    Button {
                        presentation.request.wrappedValue = nil
                    } label: {
                        Label(L.f("已准备分享：%@", request.type), systemImage: "xmark.circle")
                    }
                    .buttonStyle(WaterButton(kind: .outline))
                    .accessibilityHint(Text(L.t("关闭")))
                    .accessibilityValue(Text(String(request.byteCount)))
                    .accessibilityIdentifier("share.requested")
                    .padding()
                }
            }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    var items: SharedItems

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items.values, applicationActivities: nil)
        if let file = items.temporaryFile {
            controller.completionWithItemsHandler = { _, _, _, _ in
                Task.detached { ExportFiles.remove(file) }
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
