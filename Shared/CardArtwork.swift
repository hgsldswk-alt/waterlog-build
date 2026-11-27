import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum QRCode {
    static func make(_ url: URL, side: Int = 300) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let scale = side / (image.width + 8)
        guard scale > 0 else { return nil }
        let extent = image.width * scale
        let inset = (side - extent) / 2
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: inset, y: inset, width: extent, height: extent))
        return context.makeImage()
    }
}

struct CardDay: Equatable {
    let shortName: String
    let name: String
    let recorded: Bool
}

struct CardContent {
    let days: [CardDay]
    let milestone: Int?
    var count: Int { days.filter(\.recorded).count }
    var hashtags: String { L.t("#饮水记录 #生活习惯") }
    var headline: String { milestone.map { L.f("已记录 %@ 天", String($0)) } ?? L.daysLogged(count) }
    var caption: String {
        let text = milestone.map { L.f("喝水这件小事，已经记了 %@ 天。", String($0)) }
            ?? L.f("过去 7 天，有 %@ 天记下了喝水。", String(count))
        return text + "\n" + hashtags
    }

    init(week: [WeekDay], zone: TimeZone, milestone: Int?, locale: Locale = .current) {
        self.milestone = milestone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        let calendar = Days.calendar(in: zone)
        let letters = (locale.language.languageCode?.identifier == "zh" ? formatter.veryShortWeekdaySymbols : formatter.shortWeekdaySymbols) ?? []
        let names = formatter.weekdaySymbols ?? []
        days = week.map { item in
            let index = calendar.component(.weekday, from: item.date) - 1
            return CardDay(shortName: letters.indices.contains(index) ? letters[index] : "", name: names.indices.contains(index) ? names[index] : "",
                           recorded: item.recorded)
        }
    }
}

struct CardArtwork: View {
    static let width: CGFloat = 360
    static let height: CGFloat = 480

    var content: CardContent
    var qr: CGImage?
    var placeholder = false

    private let ink = Color(red: 21/255, green: 36/255, blue: 58/255)
    private let accent = Color(red: 14/255, green: 66/255, blue: 151/255)
    private let blue = Color(red: 18/255, green: 82/255, blue: 186/255)
    private let tint = Color(red: 232/255, green: 240/255, blue: 1)
    private let line = Color(red: 198/255, green: 215/255, blue: 245/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(content.milestone == nil ? L.t("近 7 天") : L.t("饮水里程碑"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
                if let milestone = content.milestone {
                    Text(L.f("已记录 %@ 天", String(milestone))).font(.system(size: 48, weight: .bold))
                        .minimumScaleFactor(0.6)
                } else {
                    Text(content.count == 1 ? L.t("1 天") : L.f("%@ 天", String(content.count)))
                        .font(.system(size: 54, weight: .bold)).foregroundStyle(accent)
                    Text(L.t("有记录")).font(.system(size: 44, weight: .bold))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.headline)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(Array(content.days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 8) {
                        Text(day.shortName)
                            .lineLimit(1).minimumScaleFactor(0.6).font(.system(size: 13, weight: .semibold))
                        ZStack {
                            RoundedRectangle(cornerRadius: 9).fill(day.recorded ? blue : .white)
                            if day.recorded {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            } else {
                                RoundedRectangle(cornerRadius: 9).strokeBorder(line)
                            }
                        }
                        .frame(height: 36)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.recorded ? L.f("%@，有记录", day.name) : L.f("%@，无记录", day.name))
                }
            }
            .foregroundStyle(accent)
            Spacer(minLength: 0)
            Rectangle().fill(line).frame(height: 1).accessibilityHidden(true)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("饮水记录")).font(.system(size: 16, weight: .bold))
                    Text(content.hashtags).font(.system(size: 12)).foregroundStyle(accent)
                    Text(placeholder ? L.t("下载二维码样例") : L.t("扫码下载")).font(.system(size: 11)).foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                if let qr {
                    Image(uiImage: UIImage(cgImage: qr))
                        .interpolation(.none).resizable()
                        .frame(width: 100, height: 100)
                        .accessibilityLabel(L.t("下载二维码"))
                        .accessibilityIdentifier("share.qr")
                }
            }
        }
        .padding(24)
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(ink)
        .background(tint)
    }

    @MainActor static func png(content: CardContent, url: URL) -> Data? {
        guard let qr = QRCode.make(url) else { return nil }
        let renderer = ImageRenderer(content: Self(content: content, qr: qr).environment(\.colorScheme, .light))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }
}
