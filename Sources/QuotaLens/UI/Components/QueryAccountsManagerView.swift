import SwiftUI
import UniformTypeIdentifiers

struct QueryAccountsManagerView: View {
    @ObservedObject var state: AppState
    @ObservedObject var accounts: CodexAccountsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var importing = false
    @State private var json = ""
    @State private var authorizationCode = ""
    @State private var removing: String?
    @State private var renaming: String?
    @State private var name = ""
    @State private var exportKeys: [String]?
    @State private var exporting = false
    @State private var exportDocument: QueryAccountExportDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(accounts.provider.localizedName + " · " + L10n.text("账号管理", "Account management")).font(.title2.bold())
                Spacer()
                Button(L10n.text("关闭", "Close")) { dismiss() }
            }
            Text(L10n.text("仅切换查询身份，不改变工具登录。", "Only the query identity changes, not the tool login."))
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("浏览器授权", "Browser authorization")) { accounts.authorize() }
                Button(L10n.text("导入本机账号", "Import local account")) { Task { await accounts.discoverLocal(force: true) } }
                Button(L10n.text("导入凭据文件", "Import credential file")) { importing = true }
                Button(L10n.text("导出账号", "Export accounts")) { exportKeys = accounts.accounts.map(\.accountKey) }
                    .disabled(accounts.accounts.isEmpty)
                if accounts.isRefreshing || accounts.isAuthorizing { ProgressView().controlSize(.small) }
            }
            .disabled(accounts.isRefreshing || accounts.isAuthorizing)
            if accounts.isAuthorizing {
                HStack {
                    Text(L10n.text("请在浏览器中完成账号授权。", "Complete account authorization in your browser."))
                    Button(L10n.text("取消", "Cancel")) { Task { await accounts.cancelAuthorization() } }
                }
                if accounts.provider == .claude {
                    HStack {
                        SecureField(L10n.text("粘贴浏览器返回的授权码", "Paste the authorization code from your browser"), text: $authorizationCode)
                        Button(L10n.text("完成授权", "Complete authorization")) {
                            let code = authorizationCode
                            authorizationCode = ""
                            Task { await accounts.completeBrowserAuthorization(code) }
                        }.disabled(authorizationCode.isEmpty)
                    }
                }
            }
            Text(L10n.text("有刷新令牌的账号会自动续期。导入的共享令牌可能被轮换，影响其他客户端后续刷新。", "Accounts with refresh tokens renew automatically. Renewing imported shared tokens may affect other clients' subsequent refreshes."))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Token / JSON") {
                VStack(alignment: .leading) {
                    SecureField(L10n.text("凭据 JSON", "Credential JSON"), text: $json)
                    Button(L10n.text("验证并添加", "Verify and add")) {
                        let data = Data(json.utf8)
                        json = ""
                        Task { await accounts.importCredential(data) }
                    }.disabled(json.isEmpty || accounts.isRefreshing || accounts.isAuthorizing)
                }
            }
            if let message = accounts.operationMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            if accounts.isRefreshing, accounts.importTotal > 0, accounts.importProgress < accounts.importTotal {
                ProgressView(value: Double(accounts.importProgress), total: Double(accounts.importTotal))
            }
            if let error = accounts.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if accounts.importFailures.count > 1 {
                DisclosureGroup(L10n.text("导入失败详情", "Import failure details")) {
                    ScrollView { Text(accounts.importFailures.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 80)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if accounts.accounts.isEmpty {
                        Text(L10n.text("添加并验证账号后查看实时额度", "Add and verify an account to view live quota")).foregroundStyle(.secondary)
                    }
                    ForEach(accounts.accounts) { account in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(account.name).font(.headline).textSelection(.enabled)
                            Text(account.source == .independent || account.source == nil
                                 ? L10n.text("浏览器授权", "Browser authorization")
                                 : account.source == .local ? L10n.text("导入本机账号", "Import local account")
                                 : L10n.text("导入凭据文件", "Import credential file"))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(status(account)).foregroundStyle(account.status == .available ? Color.green : Color.orange)
                                if let date = account.verifiedAt {
                                    Text(L10n.text("最近验证", "Last verified"))
                                    Text(date, format: .dateTime).foregroundStyle(.secondary)
                                }
                            }.font(.caption)
                            if let expiry = account.accessExpiresAt {
                                HStack {
                                    Text(L10n.text("访问令牌到期", "Access token expiry"))
                                    Text(expiry, format: .dateTime)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            if account.hasRefreshToken == true {
                                Text(L10n.text("自动续期已启用", "Automatic renewal enabled"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(L10n.text("查看账号", "Viewing account")) { accounts.select(account.accountKey); dismiss() }
                                    .disabled(!account.canQuery)
                                Button(L10n.text("验证", "Verify")) { Task { await accounts.validate(account.accountKey) } }
                                Button(L10n.text("备注", "Rename")) { renaming = account.accountKey; name = account.name }
                                Button(L10n.text("导出", "Export")) { exportKeys = [account.accountKey] }
                                Spacer()
                                Button(L10n.text("移除凭据", "Remove credentials"), role: .destructive) { removing = account.accountKey }
                            }.disabled(accounts.isRefreshing || accounts.isAuthorizing)
                        }
                        .padding(14)
                        .background(AppTheme.insetSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(24).frame(width: 680, height: 580)
        .foregroundStyle(AppTheme.textPrimary(for: colorScheme))
        .background(AppTheme.canvasGradient(for: colorScheme))
        .buttonStyle(AppActionButtonStyle())
        .tint(AppTheme.accentCyan(for: colorScheme))
        .onDisappear {
            json = ""
            authorizationCode = ""
            exportDocument = nil
            if accounts.isAuthorizing { Task { await accounts.cancelAuthorization() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= QueryCredentialTransfer.maximumBytes else { throw QueryAccountError.tooLarge }
                let data = try Data(contentsOf: url)
                Task { await accounts.importCredential(data) }
            } catch {
                accounts.error = (error as? QueryAccountError)?.userMessage ?? L10n.text("无法读取凭据文件", "Cannot read credential file")
            }
        }
        .confirmationDialog(L10n.text("导出账号", "Export accounts"),
            isPresented: Binding(get: { exportKeys != nil }, set: { if !$0 { exportKeys = nil } }), titleVisibility: .visible) {
            Button(L10n.text("确认导出", "Confirm export")) {
                guard let keys = exportKeys else { return }
                do {
                    exportDocument = QueryAccountExportDocument(data: try accounts.exportCredentials(keys))
                    exporting = true
                } catch { accounts.error = (error as? QueryAccountError)?.userMessage ?? QueryAccountError.storage.userMessage }
                exportKeys = nil
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) { exportKeys = nil }
        } message: {
            Text(L10n.text("导出文件包含明文 Token，可用于访问账号。请勿上传、公开分享或发送给他人。", "The export contains plaintext tokens that grant account access. Do not upload, publish, or share it with others."))
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "QuotaLens-\(accounts.provider.rawValue)-accounts") { result in
            defer { exportDocument = nil }
            switch result {
            case .success(let url):
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    accounts.operationMessage = L10n.text("账号已导出，请妥善保管文件。", "Accounts exported. Keep the file secure.")
                    accounts.error = nil
                } catch { accounts.error = QueryAccountError.storage.userMessage }
            case .failure(let failure):
                if (failure as NSError).domain == NSCocoaErrorDomain,
                   (failure as NSError).code == CocoaError.userCancelled.rawValue { return }
                accounts.error = L10n.text("导出未完成。", "Export did not complete.")
            }
        }
        .alert(L10n.text("备注", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.text("备注", "Rename"), text: $name)
            Button(L10n.text("保存", "Save")) { if let key = renaming { accounts.rename(key, to: name, state: state) }; renaming = nil }
            Button(L10n.text("取消", "Cancel"), role: .cancel) { renaming = nil }
        }
        .alert(L10n.text("移除凭据", "Remove credentials"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.text("移除凭据", "Remove credentials"), role: .destructive) {
                if let key = removing { accounts.removeCredential(key) }
                removing = nil
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(L10n.text("仅移除 QuotaLens 保存的凭据，保留全部历史数据和工具登录。", "Remove only QuotaLens credentials. All history and tool logins are preserved."))
        }
    }

    private func status(_ account: ManagedCodexAccount) -> String {
        account.statusMessage
    }
}

struct QueryAccountExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw QueryAccountError.format }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        makeFileWrapper()
    }
    func makeFileWrapper() -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        var attributes = wrapper.fileAttributes
        attributes[FileAttributeKey.type.rawValue] = FileAttributeType.typeRegular.rawValue
        attributes[FileAttributeKey.size.rawValue] = data.count
        attributes[FileAttributeKey.posixPermissions.rawValue] = 0o600
        wrapper.fileAttributes = attributes
        return wrapper
    }
}

struct QueryAccountSettingsEntry: View {
    @ObservedObject var state: AppState
    @ObservedObject var accounts: CodexAccountsStore
    @State private var showingManager = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("账号管理", "Account management")).font(.headline)
            Text(L10n.text("仅切换查询身份，不改变工具登录。", "Only the query identity changes, not the tool login."))
                .foregroundStyle(.secondary)
            Button(L10n.text("账号管理", "Account management")) { showingManager = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cyberCard(cornerRadius: 16, padding: 18)
        .sheet(isPresented: $showingManager) { QueryAccountsManagerView(state: state, accounts: accounts) }
    }
}

struct QueryAccountSummaryBadges: View {
    @ObservedObject var accounts: CodexAccountsStore
    var body: some View {
        let available = accounts.accounts.filter(\.canQuery)
        HStack(spacing: 4) {
            Text(L10n.format("%lld accounts", zhHans: "%lld 个账号", Int64(available.count)))
            ForEach(available.prefix(3)) { account in
                Text(account.name).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }.font(.system(size: 9, weight: .semibold))
    }
}
