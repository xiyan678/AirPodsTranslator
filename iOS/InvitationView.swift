import SwiftUI
import StoreKit
import UIKit

struct InvitationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var referrals: ReferralManager
    @State private var code = ""
    @State private var copied = false
    private let orange = Color(red: 1, green: 0.55, blue: 0.13)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.black).frame(width: 44, height: 44)
                        .background(.white, in: Circle())
                        .overlay(Circle().stroke(Color.gray.opacity(0.18)))
                }.accessibilityLabel("返回设置")
                Text("邀请好友").font(.system(size: 34, weight: .bold))
                VStack(spacing: 16) {
                    Image(systemName: "gift.fill").font(.system(size: 50)).foregroundStyle(orange)
                        .padding(.top, 12)
                    Text("邀请好友，双方获益").font(.title3.bold())
                    Text("分享你的邀请码给朋友，对方激活后双方各得 1 天无限制使用。\n对方完成订阅后你再得 3 天！")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineSpacing(3)
                }.frame(maxWidth: .infinity).padding(.bottom, 2)

                card {
                    if let generated = referrals.status?.code {
                        VStack(spacing: 12) {
                            Text(generated).font(.title2.monospaced().bold()).textSelection(.enabled)
                            HStack(spacing: 24) {
                                Button(copied ? "已复制" : "复制邀请码") {
                                    UIPasteboard.general.string = generated; copied = true
                                }
                                ShareLink(item: "邀请你使用声译，输入邀请码 \(generated)，我们各得 1 天无限制使用。") {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                            }.font(.subheadline).foregroundStyle(orange)
                        }.frame(maxWidth: .infinity)
                    } else {
                        Button { Task { await referrals.generate() } } label: {
                            HStack(spacing: 9) {
                                if referrals.busy { ProgressView().tint(.white) }
                                else { Image(systemName: "plus.circle.fill") }
                                Text("生成我的邀请码").fontWeight(.semibold)
                            }.foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 17)
                                .background(orange, in: Capsule())
                        }.disabled(referrals.busy).accessibilityIdentifier("referral-generate")
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("输入邀请码").font(.subheadline.bold())
                        HStack(spacing: 14) {
                            TextField("输入朋友的邀请码", text: $code)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.18)))
                                .disabled(referrals.status?.activated == true)
                                .accessibilityIdentifier("referral-code-input")
                            Button(referrals.status?.activated == true ? "已激活" : "激活") {
                                Task { await referrals.activate(code) }
                            }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || referrals.busy || referrals.status?.activated == true)
                            .accessibilityIdentifier("referral-activate")
                        }
                    }
                }
                card {
                    VStack(spacing: 20) {
                        HStack {
                            Text("邀请统计").font(.subheadline.bold())
                            Spacer()
                            Button { Task { await referrals.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(referrals.busy).accessibilityLabel("刷新邀请统计")
                        }
                        HStack(spacing: 0) {
                            statistic("person.badge.plus", value: referrals.status.map { String($0.friendsActivated) }, title: "好友激活")
                            statistic("star.fill", value: referrals.status.map { String($0.friendsSubscribed) }, title: "好友订阅")
                            statistic("calendar", value: referrals.status.map { "\($0.rewardDays) 天" }, title: "累计奖励")
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
        }
        .background(.white).toolbar(.hidden, for: .navigationBar)
        .task { await referrals.refresh() }
        .alert("提示", isPresented: Binding(get: { referrals.message != nil }, set: { if !$0 { referrals.message = nil } })) {
            Button("知道了") { referrals.message = nil }
        } message: { Text(referrals.message ?? "") }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(20).frame(maxWidth: .infinity)
            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 18))
    }
    private func statistic(_ icon: String, value: String?, title: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 23)).foregroundStyle(orange)
            Text(value ?? "—").font(.system(size: 26, weight: .semibold))
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct SubscriptionSettingsSection: View {
    @ObservedObject var subscriptions: SubscriptionManager
    @ObservedObject var usage: UsageMeter
    @State private var showRedeemCode = false
    @State private var showManage = false
    private var version: String {
        subscriptions.isPro ? "Pro" : subscriptions.referrals.rewardActive ? "活动体验版" : "免费版"
    }
    var body: some View {
        Section("订阅") {
            Label {
                LabeledContent("当前版本", value: version)
            } icon: { Image(systemName: "checkmark.seal").foregroundStyle(.blue) }
            LabeledContent("免费额度", value: "10 分钟/天")
            LabeledContent("今日剩余", value: subscriptions.hasUnlimitedAccess ? "无限制" : "\(usage.remainingLiveSeconds / 60)m \(usage.remainingLiveSeconds % 60)s")
            LabeledContent("对话额度", value: "20 句/天")
            LabeledContent("对话今日剩余", value: subscriptions.hasUnlimitedAccess ? "无限制" : "\(usage.remainingDialogueLines) 句")
            purchaseRow("月度 Pro", subtitle: "按月订阅，解锁无限同传", icon: "calendar.badge.clock",
                        id: SubscriptionManager.monthlyID, fallback: "¥68.00", period: "月")
            purchaseRow("年度 Pro", subtitle: "按年订阅，解锁无限同传", icon: "calendar.badge.checkmark",
                        id: SubscriptionManager.yearlyID, fallback: "¥498.00", period: "年")
            Button { showRedeemCode = true } label: { Label("兑换码", systemImage: "giftcard") }
                .accessibilityIdentifier("subscription-redeem")
            NavigationLink {
                InvitationView(referrals: subscriptions.referrals)
            } label: {
                Label("限时活动：邀请好友得免费时长", systemImage: "gift")
                    .foregroundStyle(.blue)
            }.accessibilityIdentifier("subscription-invite")
        }
        Section {
            Button("恢复购买") { Task { await subscriptions.restore() } }
            Button("管理订阅") { showManage = true }
        }
        .manageSubscriptionsSheet(isPresented: $showManage)
        .offerCodeRedemption(isPresented: $showRedeemCode) { result in
            if case .failure(let error) = result { subscriptions.errorMessage = error.localizedDescription }
            Task { await subscriptions.refresh(); await subscriptions.refreshRewards() }
        }
        .alert("购买提示", isPresented: Binding(get: { subscriptions.errorMessage != nil }, set: { if !$0 { subscriptions.errorMessage = nil } })) {
            Button("知道了") { subscriptions.errorMessage = nil }
        } message: { Text(subscriptions.errorMessage ?? "") }
        .task { usage.refreshDay(); await subscriptions.loadProducts(); await subscriptions.refreshRewards() }
    }
    private func purchaseRow(_ title: String, subtitle: String, icon: String, id: String, fallback: String, period: String) -> some View {
        Button { Task { await subscriptions.purchase(id) } } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(.blue).frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(subscriptions.price(for: id, fallback: fallback) + "/" + period)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6)
        }.disabled(subscriptions.purchasing)
    }
}
