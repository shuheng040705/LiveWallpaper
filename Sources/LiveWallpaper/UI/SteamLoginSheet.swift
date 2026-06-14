import SwiftUI

/// Steam 登录弹窗。两步流程(steamcmd 的限制):
/// 1. 输账号+密码 → Steam 给绑定的邮箱/手机发验证码 → steamcmd 报需要 Steam Guard
/// 2. 输验证码 → 登录成功,steamcmd 缓存令牌,之后工坊下载免密
///
/// 仅用于让 steamcmd 拿到登录态以下载匿名下不了的新壁纸。密码只传给 steamcmd,本应用不保存。
struct SteamLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void

    @State private var account = PreferencesStore.shared.steamAccount ?? ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var phase: Phase = .credentials
    @State private var busy = false
    @State private var message = ""

    enum Phase { case credentials, guardCode, success }
    private let accent = Color.accentColor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "person.badge.key.fill").font(.system(size: 16)).foregroundStyle(accent)
                Text("登录 Steam").font(.system(size: 15, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("登录后可下载匿名下载不了的新壁纸。密码只用于 SteamCMD 登录,不会保存在本应用里。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch phase {
                case .credentials:
                    labeled("Steam 账号", "person.fill") {
                        TextField("账号名", text: $account).textFieldStyle(.roundedBorder)
                    }
                    labeled("密码", "lock.fill") {
                        SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                    }
                case .guardCode:
                    Label("验证码已发送到你的 Steam 绑定邮箱/手机", systemImage: "envelope.fill")
                        .font(.system(size: 12)).foregroundStyle(accent)
                    labeled("Steam 令牌验证码", "number") {
                        TextField("如 ABCDE", text: $guardCode).textFieldStyle(.roundedBorder)
                    }
                case .success:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("登录成功!现在可以下载新壁纸了").font(.system(size: 13))
                    }
                }

                if !message.isEmpty {
                    Text(message).font(.system(size: 11))
                        .foregroundStyle(message.contains("成功") ? .green : .orange)
                }

                HStack {
                    Spacer()
                    if phase == .success {
                        Button("完成") { onDone(); dismiss() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(phase == .credentials ? "登录" : "验证") { submit() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || (phase == .credentials ? (account.isEmpty || password.isEmpty) : guardCode.isEmpty))
                    }
                    if busy { ProgressView().controlSize(.small).scaleEffect(0.8).padding(.leading, 6) }
                }
            }
            .padding(16)
        }
        .frame(width: 380)
        .background(VisualEffectView(material: .windowBackground).ignoresSafeArea())
    }

    private func labeled<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
            content()
        }
    }

    private func submit() {
        busy = true; message = ""
        let code: String? = phase == .guardCode ? guardCode : nil
        WorkshopDownloader.shared.login(account: account, password: password, guardCode: code) { success, needGuard, msg in
            busy = false
            message = msg
            if success { phase = .success }
            else if needGuard { phase = .guardCode }
        }
    }
}
