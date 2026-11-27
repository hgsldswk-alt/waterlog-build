import SwiftUI
import UIKit

struct ShareCardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let week: [WeekDay]
    let milestone: Int?
    let storeURL: URL?

    @State private var qr: CGImage?
    @State private var sharing = SharePresentation()
    @State private var busy = false
    @State private var copied = false
    @State private var issue: String?

    private var content: CardContent { CardContent(week: week, zone: model.zone, milestone: milestone) }
    private var previewURL: URL {
        storeURL ?? URL(string: "https://hgsldswk-alt.github.io/waterlog-support/")!
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L.t("分享记录卡")).font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 6)
                    Button(L.t("关闭")) { dismiss() }
                        .buttonStyle(WaterButton(kind: .outline))
                        .accessibilityIdentifier("share.close")
                }
                .padding(.bottom, 6)
                GeometryReader { proxy in
                    let scale = proxy.size.width / CardArtwork.width
                    CardArtwork(content: content, qr: qr, placeholder: storeURL == nil)
                        .scaleEffect(scale, anchor: .topLeading)
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("share.card")

                Text(L.t("卡片只显示记录天数和星期。"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                Text(content.caption).font(.subheadline)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(Panel(radius: 15))
                FieldError(message: issue)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { copy; share }
                    VStack(spacing: 8) { copy; share }
                }
            }
            .padding(22)
            .frame(maxWidth: 510)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: previewURL) {
            let url = previewURL
            qr = await Task.detached { QRCode.make(url) }.value
        }
        .sharePresentation($sharing)
    }

    private var copy: some View {
        Button {
            UIPasteboard.general.string = content.caption
            copied = true
        } label: {
            Text(copied ? L.t("已复制") : L.t("复制文案"))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(WaterButton(kind: .outline)).accessibilityIdentifier("share.copy")
    }

    private var share: some View {
        Button(action: export) {
            Text(L.t("分享图片")).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(WaterButton(kind: .primary))
        .disabled(busy)
        .accessibilityIdentifier("share.export")
    }

    private func export() {
        guard let storeURL else {
            issue = L.t("下载链接尚未配置。")
            return
        }
        guard let png = CardArtwork.png(content: content, url: storeURL) else {
            issue = L.t("无法生成记录卡，请重试。")
            return
        }
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do {
                let file = try await Task.detached {
                    try ExportFiles.write(png, filename: "waterlog-card.png")
                }.value
                try sharing.present(SharedItems(values: [file], temporaryFile: file),
                                    type: "PNG", uiTesting: model.config.uiTesting)
            } catch {
                issue = L.t("无法导出文件，请重试。")
            }
        }
    }
}
