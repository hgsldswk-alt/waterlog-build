import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var price: String? {
        if model.config.uiTesting { return L.t("US$2.99") }
        return model.products.first { $0.id == Launch.proID }?.displayPrice
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "drop.circle").font(.system(size: 52, weight: .light)).foregroundStyle(Palette.blue)
                    .accessibilityHidden(true)
                Text(L.t("一次买断，解锁高级功能")).font(.largeTitle.weight(.bold))
                    .accessibilityIdentifier("paywall.title")
                Text(L.t("用小组件记一杯、切换多套杯量组，查看近 7 天周报。"))
                    .foregroundStyle(Palette.muted)
                Text(model.purchaseStatus).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.darkBlue)
                    .accessibilityIdentifier("paywall.status")
                if !model.entitlement.purchasedPro {
                    if let price {
                        Button {
                            Task { await model.purchase(Launch.proID) }
                        } label: {
                            Text(L.f("买断 %@", price)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(WaterButton(kind: .primary))
                        .accessibilityIdentifier("paywall.buy")
                    } else if model.loadingProducts {
                        ProgressView(L.t("正在加载商品"))
                    } else {
                        Button(L.t("重新加载商品")) { Task { await model.loadProducts() } }
                            .buttonStyle(WaterButton(kind: .outline)).accessibilityIdentifier("paywall.reload")
                    }
                    if model.entitlement.trialClaimedAt == nil && model.hasPro {
                        Button(L.t("领取 30 天试用")) { Task { await model.purchase(Launch.trialID) } }
                            .buttonStyle(WaterButton(kind: .outline))
                            .disabled(!model.config.uiTesting && !model.products.contains { $0.id == Launch.trialID })
                            .accessibilityIdentifier("paywall.trial")
                    }
                }
                Button(L.t("恢复购买")) { Task { await model.restorePurchases() } }
                    .buttonStyle(WaterButton()).accessibilityIdentifier("paywall.restore")
                if let message = model.purchaseMessage {
                    Text(message).font(.footnote).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("paywall.message")
                }
                Text(L.t("试用从首次打开收费版起算。无订阅，到期继续记账、改记录和导出。"))
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            .disabled(model.purchaseBusy)
            .padding(22)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("关闭")) { dismiss() }.accessibilityIdentifier("paywall.close")
            }
        }
        .task { await model.loadProducts() }
    }

}
