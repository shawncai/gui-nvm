import SwiftUI
import GUINVMCore

struct VersionsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "installed"
    @State private var channel = "latest"
    @State private var limit = 50
    @FocusState private var searchFocused: Bool
    private var available: [NodeRelease] { model.snapshot.runtime.releases.filter { $0.compatible && !$0.installed } }
    private var rows: [NodeRelease] {
        let source = tab == "installed" ? model.snapshot.runtime.installed : available
        let matching = source.filter { model.search.isEmpty || "\($0.version) \($0.phase) \($0.description)".localizedCaseInsensitiveContains(model.search) }
        if tab == "installed" || channel == "all" { return matching }
        var majors = Set<String>()
        return matching.filter { majors.insert(String($0.version.split(separator: ".").first ?? "")).inserted }
    }
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Node 版本") {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondary); TextField("搜索版本…", text: $model.search).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("versionSearch"); Text("⌘ K").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    .padding(8).overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.line)).frame(width: 230)
                Button { model.syncCatalog() } label: { Label(model.snapshot.runtime.syncing || model.catalogSyncRequested ? "同步中" : "同步版本库", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).disabled(model.snapshot.runtime.syncing || model.catalogSyncRequested)
            }
            HStack(spacing: 18) {
                Picker("版本类型", selection: $tab) { Text("已安装 \(model.snapshot.runtime.installed.count)").tag("installed"); Text("可安装 \(available.count)").tag("available") }.pickerStyle(.segmented).frame(width: 300)
                if tab == "available" { Picker("显示版本范围", selection: $channel) { Text("各主版本最新").tag("latest"); Text("全部历史版本").tag("all") }.labelsHidden().frame(width: 170) }
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 18)
            if let error = model.snapshot.runtime.catalogError { InlineMessage(text: error + (model.snapshot.runtime.catalogAt == nil ? "" : " · 显示缓存"), isError: true) }
            if rows.isEmpty {
                EmptyState(title: model.snapshot.runtime.syncing || model.catalogSyncRequested ? "正在同步版本库" : "没有匹配的版本", symbol: "hexagon", actionTitle: model.snapshot.runtime.releases.isEmpty && tab == "available" ? "同步版本库" : nil) { model.syncCatalog() }
            } else {
                Table(Array(rows.prefix(limit))) {
                    TableColumn("版本") { release in
                        HStack(spacing: 8) { Image(systemName: "hexagon").foregroundStyle(AppTheme.secondary); Text(release.version).font(.system(size: 13, weight: .medium, design: .monospaced)); if isDefault(release) { Text("默认").font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 2).background(Color(white: 0.92), in: RoundedRectangle(cornerRadius: 3)) } }.padding(.vertical, 13)
                    }.width(min: 140, ideal: 185)
                    TableColumn("发布通道") { release in Text(phaseLabel(release)).font(.system(size: 12)).foregroundStyle(release.phase == "EOL" ? AppTheme.secondary : .primary) }.width(min: 80, ideal: 105)
                    TableColumn("支持状态") { release in
                        VStack(alignment: .leading, spacing: 4) { Text(release.description).font(.system(size: 13)); if let end = release.supportEnd { Text(end).font(.system(size: 11)).foregroundStyle(AppTheme.secondary) } }
                    }.width(min: 130, ideal: 180)
                    TableColumn(tab == "installed" ? "项目引用" : "发布日期") { release in Text(tab == "installed" ? String(model.snapshot.projects.filter { $0.resolved == release.version }.count) : release.date).font(AppTheme.mono).foregroundStyle(AppTheme.secondary) }.width(min: 90, ideal: 110)
                    TableColumn("操作") { release in
                        if tab == "installed" {
                            HStack(spacing: 8) {
                                Button("管理全局包") { model.showPackages(for: release.version) }.controlSize(.small).accessibilityLabel("管理 \(release.version) 的全局包")
                                if isDefault(release) { Text("默认版本").font(.system(size: 12)).foregroundStyle(AppTheme.secondary) }
                                else { Button("设为默认") { model.confirmDefault(release.version) }.controlSize(.small) }
                            }
                        } else { Button("安装") { model.confirmInstall(release) }.controlSize(.small).disabled(model.hasRunningInstall).help(model.hasRunningInstall ? "已有任务正在运行" : "安装 \(release.version)") }
                    }.width(min: 205, ideal: 220)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).accessibilityIdentifier("versionsTable")
                if rows.count > limit { Button("加载更多 · \(rows.count - limit)") { limit += 100 }.buttonStyle(.bordered).padding(.vertical, 10) }
            }
            HStack { Text("\(rows.count) 个版本"); if let date = catalogDate { Text("同步于 \(date.formatted(date: .numeric, time: .shortened))") }; Spacer() }.font(.system(size: 12)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 24).frame(height: 40)
        }
        .onChange(of: tab) { _, _ in model.search = ""; limit = 50 }
        .onChange(of: channel) { _, _ in limit = 50 }
        .onChange(of: model.search) { _, _ in limit = 50 }
        .onChange(of: model.focusSearchRevision) { _, _ in searchFocused = true }
        .onAppear { if model.focusSearchRevision > 0 { searchFocused = true } }
    }
    private func isDefault(_ release: NodeRelease) -> Bool { shortVersion(model.snapshot.runtime.defaultVersion.value) == shortVersion(release.version) }
    private var catalogDate: Date? {
        guard let value = model.snapshot.runtime.catalogAt else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct TasksView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "任务") { Text(String(model.snapshot.runtime.tasks.count)).foregroundStyle(AppTheme.secondary) }
            if model.snapshot.runtime.tasks.isEmpty { EmptyState(title: "暂无任务", symbol: "list.bullet.rectangle", actionTitle: "浏览版本库") { model.navigate(.versions) } }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.snapshot.runtime.tasks) { task in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 13) {
                                    Image(systemName: task.kind == "packageRemove" ? "trash" : task.kind == "packageChangeVersion" ? "shippingbox" : "arrow.down.circle").font(.system(size: 20)).foregroundStyle(AppTheme.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.packageName ?? task.version).font(.system(size: 14, weight: .medium, design: .monospaced))
                                        if task.kind != "nodeInstall" { Text("\(task.kind == "packageRemove" ? "删除全局包" : "调整版本") · Node \(task.version)\(task.targetVersion.map { " · 目标 \($0)" } ?? "")").font(.system(size: 12)).foregroundStyle(AppTheme.secondary) }
                                    }
                                    Text(["running": "进行中", "complete": "已完成", "failed": "失败", "cancelled": "已取消"][task.state] ?? task.state).font(.system(size: 12)).foregroundStyle(task.state == "failed" ? Color.red : task.state == "complete" ? Color.green : AppTheme.secondary)
                                    Text(task.startedAt, format: .dateTime.hour().minute().second()).font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                                    Spacer()
                                    if task.state == "running" { Button("取消任务") { model.cancelInstall(task) }.disabled(model.busy) }
                                }
                                HStack(spacing: 8) { if task.state == "running" { ProgressView().controlSize(.small) }; Text(task.phase).textSelection(.enabled) }.font(.system(size: 13)).foregroundStyle(AppTheme.secondary)
                                DisclosureGroup("任务日志") {
                                    ScrollView([.horizontal, .vertical]) { Text(task.log.isEmpty ? "等待输出" : task.log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(minHeight: 130, maxHeight: 320).background(Color(white: 0.97)).padding(.top, 8)
                                }.font(.system(size: 12))
                            }.padding(.vertical, 21)
                            Divider()
                        }
                    }.padding(.horizontal, 24)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var defaultChoice = ""
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    Text("Node 环境").font(.system(size: 15, weight: .semibold))
                    Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 22) {
                        GridRow {
                            Text("安装目录").foregroundStyle(AppTheme.secondary).frame(width: 95, alignment: .leading)
                            HStack(spacing: 10) {
                                Text(displayPath(model.snapshot.nvmDir)).font(AppTheme.mono).textSelection(.enabled)
                                Button { model.copy(model.snapshot.nvmDir) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制安装目录").accessibilityLabel("复制安装目录")
                                Spacer(minLength: 0)
                                Button("更改…") { model.chooseDirectory(for: "nvm") }.disabled(model.hasRunningInstall || model.busy).help(model.hasRunningInstall ? "任务结束后可更改目录" : "选择 nvm 安装目录")
                            }
                        }
                        GridRow { Text("本机架构").foregroundStyle(AppTheme.secondary); Text(model.architecture) }
                        GridRow {
                            Text("默认版本").foregroundStyle(AppTheme.secondary)
                            HStack(spacing: 12) {
                                Picker("默认 Node 版本", selection: $defaultChoice) {
                                    Text(model.snapshot.runtime.defaultVersion.value.isEmpty ? "未设置" : model.snapshot.runtime.defaultVersion.value).tag(model.snapshot.runtime.defaultVersion.value)
                                    ForEach(model.snapshot.runtime.installed.filter { $0.version != model.snapshot.runtime.defaultVersion.value }) { release in Text(release.version).tag(release.version) }
                                }.labelsHidden().frame(width: 210)
                                Button("应用") { model.confirmDefault(defaultChoice) }.disabled(defaultChoice.isEmpty || defaultChoice == model.snapshot.runtime.defaultVersion.value)
                            }
                        }
                    }
                    Divider().padding(.vertical, 5)
                    HStack { Text("扫描目录").font(.system(size: 15, weight: .semibold)); Spacer(); Button { model.chooseDirectory(for: "root") } label: { Label("添加目录", systemImage: "plus") } }
                    if model.snapshot.roots.isEmpty { Text("尚未添加扫描目录").foregroundStyle(AppTheme.secondary) }
                    ForEach(model.snapshot.roots, id: \.self) { root in HStack(spacing: 10) { Image(systemName: "folder").foregroundStyle(AppTheme.secondary); Text(displayPath(root)).font(AppTheme.mono).textSelection(.enabled); Spacer() } }
                    Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 15) {
                        GridRow { Text("扫描状态").foregroundStyle(AppTheme.secondary).frame(width: 95, alignment: .leading); HStack { Text(["idle": "未开始", "running": "扫描中", "complete": "已完成", "limited": "达到目录上限", "cancelled": "已取消", "failed": "失败"][model.snapshot.scan.state] ?? model.snapshot.scan.state); if model.snapshot.scan.state == "running" { ProgressView().controlSize(.small) } } }
                        GridRow { Text("已扫描目录").foregroundStyle(AppTheme.secondary); Text(String(model.snapshot.scan.visited)).monospacedDigit() }
                        GridRow { Text("发现项目").foregroundStyle(AppTheme.secondary); Text(String(model.snapshot.scan.found)).monospacedDigit() }
                    }
                    if let error = model.snapshot.scan.error { InlineMessage(text: error, isError: true) }
                    if !model.snapshot.scan.errors.isEmpty {
                        DisclosureGroup("无法读取的目录 · \(model.snapshot.scan.errors.count)") {
                            VStack(alignment: .leading, spacing: 7) { ForEach(model.snapshot.scan.errors) { issue in Text("\(issue.code)  \(issue.path)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                        }
                    }
                }.font(.system(size: 13)).frame(maxWidth: 790, alignment: .leading).padding(.horizontal, 26).padding(.bottom, 35).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.onAppear { defaultChoice = model.snapshot.runtime.defaultVersion.value }
            .onChange(of: model.snapshot.runtime.defaultVersion.value) { old, new in if defaultChoice == old || defaultChoice.isEmpty { defaultChoice = new } }
    }
}
