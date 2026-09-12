import SwiftUI

/// 只控制数据浏览范围；不触发登录、授权或账号数据迁移。
struct ViewingAccountPicker: View {
    @Binding var selection: String
    let accountNames: [(String, String)]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            ForEach(accountNames, id: \.0) { key, name in
                Button { selection = key } label: {
                    if selection == key {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Label(accountNames.first { $0.0 == selection }?.1 ?? L10n.text("查看账号", "Viewing account"),
                  systemImage: "person.crop.circle")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: 330, alignment: .leading)
        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(AppTheme.insetBorder(for: colorScheme), lineWidth: 0.5))
        .accessibilityLabel(L10n.text("查看账号", "Viewing account"))
        .accessibilityValue(accountNames.first { $0.0 == selection }?.1 ?? "")
        .disabled(accountNames.isEmpty)
    }
}

struct CodexViewingAccountPicker: View {
    @ObservedObject var state: AppState
    @ObservedObject var accounts: CodexAccountsStore

    var body: some View {
        ViewingAccountPicker(
            selection: Binding(
                get: { accounts.selectedKey == state.account?.accountKey ? "" : accounts.selectedKey },
                set: { accounts.select($0) }
            ),
            accountNames: [("", L10n.text("Codex 当前账号", "Current Codex account"))]
                + accounts.keys(state: state).filter { $0 != state.account?.accountKey }
                    .map { ($0, accounts.name(for: $0, state: state)) }
        )
        .help(L10n.text("这里只切换查看账号，不会更改 Codex 登录；菜单栏仍显示当前使用的账号。",
                       "Viewing another account does not change the Codex login. The menu bar follows the active account."))
        .onChange(of: state.account?.accountKey, initial: true) { _, key in
            if let key, accounts.selectedKey == key { accounts.select("") }
        }
    }
}
