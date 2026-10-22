import SwiftUI
import GUINVMCore

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "项目") {
                Button { model.toggleScan() } label: { Label(model.snapshot.scan.state == "running" ? "取消扫描" : "重新扫描", systemImage: model.snapshot.scan.state == "running" ? "stop.circle" : "arrow.clockwise") }.buttonStyle(.bordered)
                Button { model.chooseDirectory(for: "project") } label: { Label("添加项目", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 15) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondary); TextField("搜索项目…", text: $model.search).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("projectSearch") }
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.line)).frame(minWidth: 150, maxWidth: 270)
                Picker("项目状态", selection: $model.projectFilter) {
                    Text("全部 \(model.snapshot.projects.count)").tag("all")
                    Text("待配置 \(model.snapshot.projects.filter { $0.status == "unconfigured" }.count)").tag("unconfigured")
                    Text("版本缺失 \(model.snapshot.projects.filter { $0.status == "missing" }.count)").tag("missing")
                    if model.projectFilter == "attention" { Text("需关注").tag("attention") }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 370)
                Spacer(minLength: 0)
                Menu { Button("全部状态") { model.projectFilter = "all" }; Button("已停止支持 / 配置无效") { model.projectFilter = "attention" } } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).frame(width: 22).help("更多状态筛选").accessibilityLabel("更多状态筛选")
            }.padding(.horizontal, 24).padding(.bottom, 18)
            if !model.rootFilter.isEmpty {
                HStack { Label(displayPath(model.rootFilter), systemImage: "folder").font(AppTheme.mono); Button { model.rootFilter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除目录筛选"); Spacer() }.foregroundStyle(AppTheme.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if model.visibleProjects.isEmpty {
                EmptyState(title: emptyTitle, actionTitle: model.snapshot.roots.isEmpty ? "添加扫描目录" : "添加项目") { model.chooseDirectory(for: model.snapshot.roots.isEmpty ? "root" : "project") }
            } else {
                Table(model.visibleProjects, selection: $model.selectedProjectID) {
                    TableColumn("项目") { project in
                        HStack(spacing: 10) {
                            Image(systemName: "folder").font(.system(size: 19, weight: .light)).modifier(SelectionForeground(selected: model.selectedProjectID == project.id, unselected: AppTheme.secondary))
                            VStack(alignment: .leading, spacing: 5) { Text(project.name).font(.system(size: 14, weight: .medium)); Text(displayPath(project.path)).font(AppTheme.mono).modifier(SelectionForeground(selected: model.selectedProjectID == project.id, unselected: AppTheme.secondary)).lineLimit(1).truncationMode(.middle) }
                        }.padding(.vertical, 11).help(project.path)
                    }.width(min: 170, ideal: 270)
                    TableColumn("声明") { project in Text(project.requested.isEmpty ? "未声明" : project.requested).font(AppTheme.mono).lineLimit(1).help(project.requested) }.width(min: 90, ideal: 130)
                    TableColumn("解析版本") { project in Text(project.resolved ?? (project.status == "unconfigured" ? "默认" : "未解析")).font(AppTheme.mono) }.width(min: 85, ideal: 105)
                    TableColumn("状态") { project in StatusBadge(status: project.status, selected: model.selectedProjectID == project.id) }.width(min: 90, ideal: 110)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).accessibilityIdentifier("projectTable")
            }
            HStack(spacing: 12) {
                Text("\(model.visibleProjects.count) 个项目")
                if model.snapshot.scan.state == "running" { ProgressView().controlSize(.small); Text("已扫描 \(model.snapshot.scan.visited) 个目录") }
                if model.snapshot.scan.state == "limited" { Text("已达到 50,000 个目录上限") }
                if !model.snapshot.scan.errors.isEmpty { Button("\(model.snapshot.scan.errors.count) 个目录无法读取") { model.navigate(.settings) }.buttonStyle(.link) }
                Spacer()
            }.font(.system(size: 12)).foregroundStyle(AppTheme.secondary).padding(.horizontal, 24).frame(height: 40)
        }
        .onChange(of: model.focusSearchRevision) { _, _ in searchFocused = true }
        .onAppear { if model.focusSearchRevision > 0 { searchFocused = true } }
    }
    private var emptyTitle: String {
        if !model.search.isEmpty || model.projectFilter != "all" || !model.rootFilter.isEmpty { return "没有匹配的项目" }
        return model.snapshot.scan.state == "running" ? "正在扫描目录" : "尚未添加项目"
    }
}

@MainActor
final class InspectorDraft: ObservableObject {
    @Published var requested: String
    @Published var destination: String
    @Published var custom = false
    @Published var preview: ConfigPreview?
    @Published var error: String?
    @Published var saving = false
    @Published var generation = 0
    private var baseline: ProjectRecord
    private var conflict = false
    private let fallbackVersion: String
    init(project: ProjectRecord, fallbackVersion: String) {
        baseline = project; self.fallbackVersion = fallbackVersion
        requested = project.requested.isEmpty ? fallbackVersion : project.requested
        destination = project.source.isEmpty ? ".nvmrc" : project.source
    }
    var key: String { requested + "\u{0}" + destination + "\u{0}" + String(generation) }
    var changed: Bool { requested != baseline.requested || destination != baseline.source }
    func editRequested(_ value: String) { requested = value; conflict = false; preview = nil }
    func editDestination(_ value: String) { destination = value; conflict = false; preview = nil }
    func receive(_ project: ProjectRecord) {
        guard project != baseline else { return }
        let untouched = requested == baseline.requested && destination == (baseline.source.isEmpty ? ".nvmrc" : baseline.source)
        let matchesNew = requested == project.requested && destination == project.source
        if project.revision != baseline.revision || project.requested != baseline.requested || project.source != baseline.source {
            preview = nil
            if untouched || matchesNew {
                requested = project.requested.isEmpty ? fallbackVersion : project.requested
                destination = project.source.isEmpty ? ".nvmrc" : project.source
                error = nil; conflict = false; generation += 1
            } else {
                error = "配置已被外部修改，请重新预览"; conflict = true; generation += 1
            }
        }
        baseline = project
    }
    func reset() {
        requested = baseline.requested.isEmpty ? fallbackVersion : baseline.requested
        destination = baseline.source.isEmpty ? ".nvmrc" : baseline.source
        custom = false; conflict = false; error = nil; preview = nil; generation += 1
    }
    func retryPreview() { conflict = false; generation += 1 }
    func updatePreview(model: AppModel) async {
        guard !conflict, let store = model.store else { return }
        preview = nil; error = nil
        let expectedKey = key
        do {
            try await Task.sleep(for: .milliseconds(180))
            let value = try await store.preview(id: baseline.id, destination: destination, requested: requested)
            guard !Task.isCancelled, key == expectedKey, !conflict else { return }
            preview = value
        } catch is CancellationError { }
        catch { if !Task.isCancelled, key == expectedKey { self.error = error.localizedDescription } }
    }
    func save(model: AppModel) async {
        guard let preview, let store = model.store, !saving else { return }
        let submittedKey = key
        saving = true
        defer { saving = false }
        do {
            try await store.save(preview)
            if key == submittedKey {
                requested = preview.requested
                destination = preview.destination
            }
            await model.refresh()
            model.notify("配置已保存")
        }
        catch { self.error = error.localizedDescription; self.preview = nil }
    }
}

struct ProjectInspector: View {
    @ObservedObject var model: AppModel
    let project: ProjectRecord
    @StateObject private var draft: InspectorDraft
    init(model: AppModel, project: ProjectRecord) {
        self.model = model; self.project = project
        _draft = StateObject(wrappedValue: InspectorDraft(project: project, fallbackVersion: shortVersion(model.snapshot.runtime.installed.first?.version ?? "")))
    }
    private var choices: [NodeRelease] {
        model.snapshot.runtime.installed.sorted { score($0) < score($1) }
    }
    private func score(_ release: NodeRelease) -> Int { release.phase == "Current" ? 0 : release.phase.contains("LTS") ? 1 : release.lts ? 2 : 3 }
    private var recommendations: [NodeRelease] {
        let releases = model.snapshot.runtime.releases.filter { !$0.installed && $0.compatible && $0.phase != "EOL" }
        return [releases.first { $0.phase.contains("LTS") }, releases.first { $0.phase == "Current" }].compactMap { $0 }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(project.name).font(.system(size: 20, weight: .semibold)).lineLimit(1).help(project.name)
                Spacer(minLength: 0)
                Button { model.reveal(project) } label: { Image(systemName: "arrow.up.forward") }.buttonStyle(.plain).help("在访达中显示项目").accessibilityLabel("在访达中显示项目")
                Button { model.selectedProjectID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭版本配置").accessibilityLabel("关闭版本配置")
            }.padding(22).frame(height: 69).overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 8) { Text("当前版本").foregroundStyle(AppTheme.secondary); Text(project.resolved ?? "未解析").font(AppTheme.mono).help(project.file ?? project.path) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("目标版本").foregroundStyle(AppTheme.secondary)
                            Spacer()
                            Button { draft.custom.toggle() } label: { Image(systemName: draft.custom ? "list.bullet" : "pencil") }.buttonStyle(.plain).help(draft.custom ? "选择已安装版本" : "自定义版本或别名").accessibilityLabel("自定义版本或别名")
                        }
                        if draft.custom {
                            TextField(draft.destination == "package.json" ? ">=22 <23" : "22.22.3 / lts/*", text: Binding(get: { draft.requested }, set: { draft.editRequested($0) })).font(AppTheme.mono).textFieldStyle(.roundedBorder).accessibilityIdentifier("customVersion")
                        } else {
                            Menu {
                                ForEach(choices) { release in
                                    Button("\(release.version)  ·  \(phaseLabel(release)) · \(release.description)") { draft.editRequested(shortVersion(release.version)) }
                                }
                                Divider()
                                Button("自定义版本或别名…") { draft.custom = true }
                                Button("浏览版本库…") { model.navigate(.versions) }
                            } label: {
                                HStack { Text(draft.requested.isEmpty ? "选择版本" : draft.requested).font(AppTheme.mono); Spacer() }
                            }.menuStyle(.borderedButton).controlSize(.large).accessibilityLabel("目标版本")
                        }
                        if let target = model.snapshot.runtime.installed.first(where: { $0.version == draft.preview?.resolved || shortVersion($0.version) == shortVersion(draft.requested) }) {
                            Text("\(phaseLabel(target)) · \(target.description)").font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("写入文件").foregroundStyle(AppTheme.secondary)
                            Spacer()
                            Picker("写入文件", selection: Binding(get: { draft.destination }, set: { draft.editDestination($0) })) { ForEach([".nvmrc", ".node-version", "package.json"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 160)
                        }
                        HStack { Text("文件预览").font(.system(size: 12)).foregroundStyle(AppTheme.secondary); Spacer(); if draft.changed { Text("待保存").font(.system(size: 11)).foregroundStyle(AppTheme.secondary) } }
                        codePreview
                        if project.inherited { Text("写入当前项目 · \(draft.destination)").font(.system(size: 12)).foregroundStyle(AppTheme.secondary) }
                        if let error = draft.error { InlineMessage(text: error, isError: true, actionTitle: "重新预览") { draft.retryPreview() } }
                        if let error = project.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                        HStack { Spacer(); Button("取消") { draft.reset() }.disabled(draft.saving); Button(draft.saving ? "保存中…" : "保存配置") { Task { await draft.save(model: model) } }.buttonStyle(PrimaryButtonStyle()).disabled(draft.preview == nil || !draft.changed || draft.saving).accessibilityIdentifier("saveConfiguration") }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("可安装").font(.system(size: 14, weight: .semibold))
                        ForEach(recommendations) { release in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) { Text(release.version).font(AppTheme.mono); Text("\(phaseLabel(release)) · \(release.description)").font(.system(size: 12)).foregroundStyle(AppTheme.secondary) }
                                Spacer()
                                Button("安装") { model.confirmInstall(release) }.disabled(model.hasRunningInstall)
                            }
                        }
                        Button("浏览版本库…") { model.navigate(.versions) }.buttonStyle(.link)
                    }
                }.padding(22).font(.system(size: 13))
            }
        }.background(Color.white)
            .task(id: draft.key) { await draft.updatePreview(model: model) }
            .onChange(of: project) { _, value in draft.receive(value) }
    }
    private var codePreview: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 15) {
                let text = draft.preview?.after ?? (draft.destination == "package.json" ? "\"node\": \"\(draft.requested)\"" : draft.requested)
                let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
                VStack(alignment: .trailing, spacing: 4) { ForEach(lines.indices, id: \.self) { index in Text(String(index + 1)).foregroundStyle(.tertiary) } }
                VStack(alignment: .leading, spacing: 4) { ForEach(lines.indices, id: \.self) { index in Text(lines[index].isEmpty ? " " : lines[index]) } }.textSelection(.enabled)
                Spacer(minLength: 0)
            }.font(AppTheme.mono).padding(12)
        }.frame(minHeight: 70, maxHeight: 220).background(Color.white).overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.line)).accessibilityLabel("文件预览")
    }
}
