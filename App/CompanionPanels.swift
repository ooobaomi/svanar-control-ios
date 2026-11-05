import SwiftUI
import UniformTypeIdentifiers

struct EQFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= EQLibrary.maximumBytes else { throw HeadphoneError.message("需要不超过 64 KiB 的 JSON 文件") }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct CompanionPanels: View {
    @EnvironmentObject private var headphones: HeadphoneManager
    @State private var showLibrary = false
    @State private var touchID = 0
    @State private var action = 0
    @State private var confirmWrite = false
    @State private var confirmRestore = false
    private var available: Bool { headphones.isReady && !headphones.isBusy }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("EQ 收藏与模式联动") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(headphones.library.profiles.count) 套收藏 · 联动\(headphones.linksEnabled ? "开启" : "关闭")")
                    Button("管理收藏 / 导入导出 / 模式绑定") { showLibrary = true }
                    Text("首次连接只读；开启联动后，前台检测到模式变化才应用对应曲线。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            diagnosticPanel
            touchPanel
        }.sheet(isPresented: $showLibrary) { EQLibraryView().environmentObject(headphones).preferredColorScheme(.dark) }
    }
    private var diagnosticPanel: some View {
        GroupBox("游戏模式与能力诊断") {
            VStack(alignment: .leading, spacing: 10) {
                Button("读取扩展信息") { headphones.readExtras() }.disabled(!available)
                HStack {
                    Button("开启游戏模式") { headphones.setGame(true) }
                    Button("关闭游戏模式") { headphones.setGame(false) }
                }.disabled(!available || headphones.features.supportsGame != true || headphones.features.gameEnabled == nil)
                Button("检查降噪 / 通透强度能力") { headphones.readStrength() }.disabled(!available)
                Text(headphones.features.strengthSummary).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("型号、固件、编码与原始响应") {
                    Text(headphones.features.summary).font(.caption.monospaced()).textSelection(.enabled)
                    Button("复制诊断") { UIPasteboard.general.string = headphones.features.summary }
                }
                Text("仅显示耳机报告，不更改 iOS 音频编码器，不刷写固件。").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var touchPanel: some View {
        GroupBox("触控重映射") {
            VStack(alignment: .leading, spacing: 10) {
                Button("读取触控映射") { headphones.readTouches() }.disabled(!available)
                Text(headphones.touchMessage).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("编辑映射 / 恢复备份") {
                    Picker("手势", selection: $touchID) {
                        Text("选择手势").tag(0)
                        ForEach(headphones.touches) { item in Text(item.name).tag(item.id) }
                    }
                    Picker("动作", selection: $action) {
                        ForEach(TouchBinding.actions.indices, id: \.self) { Text(TouchBinding.actions[$0]).tag($0) }
                    }
                    Button("写入所选触控") { confirmWrite = true }.disabled(!available || !headphones.touches.contains { $0.id == touchID })
                    Button("恢复首次修改前的备份") { confirmRestore = true }.disabled(!available || headphones.touches.isEmpty)
                    Text("首次写入前按耳机身份保存原映射；只开放读回确认的手势。S050 在安卓实测中未回应查询，写入保持禁用。").font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: touchID) { id in if let item = headphones.touches.first(where: { $0.id == id }) { action = item.action } }
        .onChange(of: headphones.touches) { entries in touchID = entries.first?.id ?? 0; action = entries.first?.action ?? 0 }
        .confirmationDialog("写入触控映射并回读？", isPresented: $confirmWrite, titleVisibility: .visible) {
            Button("确认写入") { if let old = headphones.touches.first(where: { $0.id == touchID }) { headphones.setTouch(TouchBinding(ear: old.ear, gesture: old.gesture, action: action)) } }
            Button("取消", role: .cancel) { }
        }
        .alert("恢复此耳机原触控备份？", isPresented: $confirmRestore) {
            Button("恢复") { headphones.restoreTouches() }; Button("取消", role: .cancel) { }
        } message: { Text("会恢复首次修改前保存的映射，并逐项回读确认。") }
    }
}

struct EQLibraryView: View {
    @EnvironmentObject private var headphones: HeadphoneManager
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var name = ""
    @State private var rename = false
    @State private var showName = false
    @State private var showDelete = false
    @State private var showOverwrite = false
    @State private var importing = false
    @State private var exporting = false
    @State private var document = EQFileDocument()
    @State private var imported: EQLibrary?
    @State private var confirmImport = false
    private var chosen: EQProfile? { headphones.library.profiles.first { $0.id == selected } }
    var body: some View {
        NavigationStack {
            Form {
                profileSection
                fileSection
                linksSection
                Section { Text(headphones.status).font(.footnote).textSelection(.enabled) }
            }
            .navigationTitle("EQ 收藏与联动")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { selected = headphones.library.profiles.first?.id ?? "" }
            .onChange(of: headphones.library.profiles.map(\.id)) { ids in if !ids.contains(selected) { selected = ids.first ?? "" } }
            .alert(rename ? "重命名收藏" : "保存当前 EQ 草稿", isPresented: $showName) {
                TextField("收藏名称（1–40 字）", text: $name)
                Button("保存") { headphones.saveProfile(name: name, replacing: rename ? chosen?.id : nil, renameOnly: rename) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("删除收藏及相关模式绑定？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { if let p = chosen { headphones.deleteProfile(p.id) } }; Button("取消", role: .cancel) { }
            }
            .confirmationDialog("用当前草稿覆盖所选收藏？", isPresented: $showOverwrite, titleVisibility: .visible) {
                Button("覆盖收藏") { if let p = chosen { headphones.saveProfile(name: p.name, replacing: p.id) } }; Button("取消", role: .cancel) { }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "svanar-eq-backup") { result in
                switch result { case .success: headphones.status = "EQ 收藏及模式绑定已导出"; case .failure(let e): headphones.status = "导出未完成：\(e.localizedDescription)" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
                do {
                    let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let bytes = try handle.read(upToCount: EQLibrary.maximumBytes + 1) ?? Data()
                    imported = try EQLibrary.decode(bytes); confirmImport = true
                } catch { headphones.status = "文件导入未完成，原收藏保留：\(error.localizedDescription)" }
            }
        }.tint(.mint)
    }
    private var profileSection: some View {
        Section("收藏 · 最多 64 套") {
            Picker("所选收藏", selection: $selected) {
                Text("选择收藏").tag("")
                ForEach(headphones.library.profiles) { p in Text(p.name).tag(p.id) }
            }
            Button("当前草稿另存为收藏") { rename = false; name = ""; showName = true }
            Button("载入所选收藏到草稿") { if let p = chosen { headphones.loadProfile(p.id) } }.disabled(chosen == nil || headphones.isBusy)
            Button("覆盖所选收藏") { showOverwrite = true }.disabled(chosen == nil)
            Button("重命名所选收藏") { rename = true; name = chosen?.name ?? ""; showName = true }.disabled(chosen == nil)
            Button("删除所选收藏", role: .destructive) { showDelete = true }.disabled(chosen == nil)
            Text("收藏、载入和导入只编辑本机数据，点击均衡器的应用按钮才写耳机。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var fileSection: some View {
        Section("跨 Android / iOS 文件") {
            Button("导出 EQ 文件") { do { document = EQFileDocument(data: try headphones.library.encoded()); exporting = true } catch { headphones.status = error.localizedDescription } }
            Button("导入 EQ 文件") { importing = true }
            Text("兼容安卓 v1.3 JSON，最大 64 KiB。导入合并、不覆盖同 ID 的不同内容，并关闭自动联动。").font(.caption).foregroundStyle(.secondary)
        }.alert("导入 \(imported?.profiles.count ?? 0) 套收藏？", isPresented: $confirmImport) {
            Button("确认导入") { if let data = imported { headphones.importLibrary(data) }; imported = nil }
            Button("取消", role: .cancel) { imported = nil }
        } message: { Text("将合入文件中的模式绑定；自动联动关闭，耳机 EQ 不会立即改变。") }
    }
    private var linksSection: some View {
        Section("模式绑定") {
            ForEach(ListeningMode.allCases) { mode in
                Picker(mode.name, selection: Binding(get: { headphones.library.links[String(mode.rawValue)] ?? "" }, set: { headphones.bindProfile($0, to: mode) })) {
                    Text("未绑定").tag("")
                    ForEach(headphones.library.profiles) { p in Text(p.name).tag(p.id) }
                }
            }
            Toggle("模式变化时应用绑定 EQ", isOn: Binding(get: { headphones.linksEnabled }, set: { headphones.setLinksEnabled($0) }))
            Text("仅前台连接期间工作；首次连接只读。耳机手动切模式约每 5 秒检查，后台不承诺持续控制。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
