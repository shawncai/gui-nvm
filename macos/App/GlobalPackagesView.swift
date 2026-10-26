import SwiftUI
import GUINVMCore

struct GlobalPackagesView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    private var packages: GlobalPackageSnapshot { model.snapshot.runtime.globalPackages }
    private var scanning: Bool { packages.scanning || model.packageRefreshRequested }
    private var emptyTitle: String {
        if scanning { return "正在读取全局包" }
        if !model.search.isEmpty || !model.packageNodeFilter.isEmpty { return "没有匹配的全局包" }
        if model.snapshot.runtime.installed.isEmpty { return "尚未安装 Node 版本" }
        return "没有已安装的全局包"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "全局包") {
                Button { model.refreshPackages() } label: {
                    Label(scanning ? "读取中" : "刷新", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered).disabled(scanning).accessibilityIdentifier("refreshGlobalPackages")
            }
            HStack(spacing: 14) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondary)
                    TextField("搜索包名…", text: $model.search).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("globalPackageSearch")
                }.padding(8).background(.white, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.line)).frame(minWidth: 130, maxWidth: 270)
                Picker("Node 版本", selection: $model.packageNodeFilter) {
                    Text("全部 Node 版本").tag("")
                    ForEach(model.snapshot.runtime.installed) { release in Text(release.version).tag(release.version) }
                }.labelsHidden().frame(width: 175).accessibilityIdentifier("globalPackageNodeFilter")
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).padding(.bottom, 18)
            if !packages.errors.isEmpty {
                DisclosureGroup("\(packages.errors.count) 个目录无法读取") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(packages.errors) { issue in Text("\(issue.code)  \(displayPath(issue.path))").font(AppTheme.mono).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.frame(maxHeight: 110)
                }.font(.system(size: 13)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 24).padding(.bottom, 14)
            }
            if model.visiblePackages.isEmpty {
                EmptyState(title: emptyTitle, symbol: "shippingbox", actionTitle: model.snapshot.runtime.installed.isEmpty ? "浏览版本库" : nil) { model.navigate(.versions) }
            } else {
                Table(model.visiblePackages, selection: $model.selectedPackageID) {
                    TableColumn("包名") { package in
                        HStack(spacing: 9) {
                            Image(systemName: "shippingbox").modifier(SelectionForeground(selected: model.selectedPackageID == package.id, unselected: AppTheme.secondary))
                            Text(package.name).font(.system(size: 14, weight: .medium)).lineLimit(1).help(package.name)
                        }.padding(.vertical, 13)
                    }.width(min: 145, ideal: 230)
                    TableColumn("包版本") { package in Text(package.version.isEmpty ? "未知" : package.version).font(AppTheme.mono).lineLimit(1).help(package.version) }.width(min: 85, ideal: 120)
                    TableColumn("Node 版本") { package in Text(package.nodeVersion).font(AppTheme.mono) }.width(min: 105, ideal: 115)
                    TableColumn("状态") { package in
                        Text(package.editable ? "可管理" : "只读").font(.system(size: 13))
                            .modifier(SelectionForeground(selected: model.selectedPackageID == package.id, unselected: AppTheme.secondary))
                            .help(package.issue ?? "可调整版本或删除")
                    }.width(min: 65, ideal: 75)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).accessibilityIdentifier("globalPackagesTable")
            }
            HStack(spacing: 10) {
                Text("\(model.visiblePackages.count) 个全局包")
                if scanning { ProgressView().controlSize(.small); Text("读取中") }
                else if let scannedAt = packages.scannedAt { Text("更新于 \(scannedAt.formatted(date: .omitted, time: .shortened))") }
                Spacer()
            }.font(.system(size: 12)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 24).frame(height: 40)
        }
        .onChange(of: model.packageNodeFilter) { _, _ in clearHiddenSelection() }
        .onChange(of: model.search) { _, _ in clearHiddenSelection() }
        .onChange(of: model.focusSearchRevision) { _, _ in searchFocused = true }
        .onAppear {
            if model.focusSearchRevision > 0 { searchFocused = true }
            if packages.scannedAt == nil && !scanning { model.refreshPackages() }
        }
    }
    private func clearHiddenSelection() {
        if let id = model.selectedPackageID, !model.visiblePackages.contains(where: { $0.id == id }) { model.selectedPackageID = nil }
    }
}

struct GlobalPackageInspector: View {
    @ObservedObject var model: AppModel
    let package: GlobalPackageRecord
    @State private var targetVersion = ""
    private var blocked: Bool { model.busy || model.hasRunningInstall || !package.editable }
    private var exactTarget: Bool {
        let number = "(0|[1-9][0-9]*)"
        let prerelease = "(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
        let pattern = "^\(number)\\.\(number)\\.\(number)(-\(prerelease)(\\.\(prerelease))*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"
        return targetVersion.range(of: pattern, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(package.name).font(.system(size: 20, weight: .semibold)).lineLimit(1).help(package.name)
                Spacer(minLength: 0)
                Button { model.selectedPackageID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭全局包详情").accessibilityLabel("关闭全局包详情")
            }.padding(22).frame(height: 69).overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                        GridRow { Text("Node 版本").foregroundStyle(AppTheme.secondary); Text(package.nodeVersion).font(AppTheme.mono) }
                        GridRow { Text("当前版本").foregroundStyle(AppTheme.secondary); Text(package.version.isEmpty ? "未知" : package.version).font(AppTheme.mono).textSelection(.enabled) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("安装位置").foregroundStyle(AppTheme.secondary); Spacer(); Button { model.copy(package.path) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制包路径").accessibilityLabel("复制包路径") }
                        Text(displayPath(package.path)).font(AppTheme.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    if !package.editable {
                        Label("只读", systemImage: "lock").font(.system(size: 14, weight: .medium))
                        Text(package.issue ?? "此包不支持修改").font(.system(size: 13)).foregroundStyle(AppTheme.secondary).textSelection(.enabled)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("目标版本").foregroundStyle(AppTheme.secondary)
                            TextField("例如 5.9.3", text: $targetVersion).font(AppTheme.mono).textFieldStyle(.roundedBorder).disabled(blocked).accessibilityIdentifier("globalPackageTargetVersion")
                                .onSubmit { previewVersionChange() }
                            Text("输入精确版本，可升级或降级。").font(.system(size: 13)).foregroundStyle(AppTheme.secondary)
                            if !targetVersion.isEmpty && !exactTarget { Text("请输入完整版本号，如 5.9.3。").font(.system(size: 13)).foregroundStyle(Color(red: 0.65, green: 0.22, blue: 0.14)) }
                            HStack { Spacer(); Button("预览调整") { previewVersionChange() }.buttonStyle(PrimaryButtonStyle()).disabled(blocked || !exactTarget || targetVersion == package.version).accessibilityIdentifier("previewGlobalPackageChange") }
                        }
                        Divider()
                        HStack { Text("删除此 Node 版本中的包").font(.system(size: 13)).foregroundStyle(AppTheme.secondary); Spacer(); Button("删除…", role: .destructive) { Task { await model.previewPackageChange(package, action: .remove) } }.disabled(blocked).accessibilityIdentifier("previewGlobalPackageRemove") }
                        if model.hasRunningInstall { Text("等待当前任务完成后可修改。").font(.system(size: 13)).foregroundStyle(AppTheme.secondary) }
                    }
                }.font(.system(size: 14)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func previewVersionChange() {
        guard !blocked, exactTarget, targetVersion != package.version else { return }
        Task { await model.previewPackageChange(package, action: .changeVersion, targetVersion: targetVersion) }
    }
}

struct GlobalPackageConfirmationView: View {
    @ObservedObject var model: AppModel
    let preview: GlobalPackagePreview
    @State private var allowScripts = false
    private var removing: Bool { preview.action == .remove }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(removing ? "删除全局包" : "调整全局包版本").font(.system(size: 20, weight: .semibold))
            Text(preview.package.name).font(.system(size: 20, weight: .medium, design: .monospaced)).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow { Text("Node 版本").foregroundStyle(AppTheme.secondary); Text(preview.package.nodeVersion).font(AppTheme.mono) }
                GridRow { Text("当前版本").foregroundStyle(AppTheme.secondary); Text(preview.package.version).font(AppTheme.mono) }
                if let target = preview.targetVersion { GridRow { Text("目标版本").foregroundStyle(AppTheme.secondary); Text(target).font(AppTheme.mono) } }
                GridRow { Text("安装位置").foregroundStyle(AppTheme.secondary); Text(displayPath(preview.package.path)).font(AppTheme.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }.font(.system(size: 13))
            if removing {
                Text("删除后，该 Node 版本将无法使用此包提供的命令。").font(.system(size: 13)).foregroundStyle(AppTheme.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("从当前 npm registry 安装指定版本。").font(.system(size: 13)).foregroundStyle(AppTheme.secondary)
                    Toggle("仅本次允许运行安装脚本", isOn: $allowScripts).toggleStyle(.checkbox).disabled(model.busy).accessibilityIdentifier("allowGlobalPackageScripts")
                    Text("默认关闭，需脚本构建或下载组件的包可能无法使用。启用后脚本将在本机运行。").font(.system(size: 13)).foregroundStyle(AppTheme.secondary)
                }
            }
            HStack {
                Spacer()
                Button("取消") { model.packageConfirmation = nil }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button(model.busy ? "处理中…" : removing ? "执行删除" : "执行调整") {
                    var confirmed = preview
                    confirmed.allowScripts = !removing && allowScripts
                    Task { await model.executePackageChange(confirmed) }
                }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy || model.hasRunningInstall).keyboardShortcut(.defaultAction).accessibilityIdentifier("executeGlobalPackageChange")
            }
        }.padding(26).frame(width: 540).interactiveDismissDisabled(model.busy)
    }
}
