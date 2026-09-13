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
    @State private var showingManager = false

    var body: some View {
        HStack {
            ViewingAccountPicker(
                selection: Binding(get: { accounts.selectedKey }, set: { accounts.select($0) }),
                accountNames: accounts.keys(state: state).map { ($0, accounts.name(for: $0, state: state)) }
            )
            Button { showingManager = true } label: {
                Image(systemName: "person.2.badge.gearshape")
            }
            .help(L10n.text("账号管理", "Account management"))
            .accessibilityLabel(L10n.text("账号管理", "Account management"))
        }
        .sheet(isPresented: $showingManager) {
            QueryAccountsManagerView(state: state, accounts: accounts)
        }
    }
}
