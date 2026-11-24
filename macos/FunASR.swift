import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct FunASRApp: App {
    var body: some Scene {
        WindowGroup("听笺") {
            Workspace().frame(minWidth: 900, minHeight: 630)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
    }
}

private struct ModelEntry: Identifiable, Decodable {
    let id: String
    let key: String
    let title: String
    let category: String
    let legacy: Bool
    let available: Bool
    let note: String
    let recommendation: String?
    var repository: String { String(id.split(separator: "/").last ?? "") }

    static let catalog: [Self] = {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return models
    }()
}

private struct TranscriptionProgress: Decodable, Equatable {
    let stage: String
    let processed: Int
    let total: Int

    var title: String {
        switch stage {
        case "loading": "正在加载模型"
        case "converting": "正在转换音频"
        case "detecting": "正在检测语音片段"
        case "recognizing": "正在识别语音"
        case "organizing": "正在整理稿件"
        default: "正在转写"
        }
    }

    var percent: Int? {
        guard stage == "recognizing", total > 0 else { return nil }
        return Int((100 * min(1, max(0, Double(processed) / Double(total)))).rounded(.down))
    }
}

private struct SpeakerRenameRequest: Identifiable {
    let id = UUID()
    let labels: [String]
}

private struct Workspace: View {
    @AppStorage("modelRoot") private var modelRoot = Self.defaultModelRoot

    private static var defaultModelRoot: String {
        let previous = NSHomeDirectory() + "/Desktop/FunASR/model"
        if FileManager.default.fileExists(atPath: previous) { return previous }
        return NSHomeDirectory() + "/Library/Application Support/LocalFunASR/Models"
    }
    @AppStorage("asrID") private var asrID = "iic/speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
    @AppStorage("asr") private var asr = ""
    @AppStorage("vad") private var vad = ""
    @AppStorage("punc") private var punc = ""
    @AppStorage("cam") private var cam = ""
    @AppStorage("speaker") private var speaker = true
    @AppStorage("showSpeakers") private var showSpeakers = true
    @AppStorage("punctuation") private var punctuation = true
    @AppStorage("timestamps") private var timestamps = true
    @AppStorage("plain") private var plain = false
    @AppStorage("hotwords") private var hotwords = ""
    @AppStorage("saveFolder") private var saveFolder = ""
    @State private var input = ""
    @State private var typedInput = ""
    @State private var confirmedReplacementPath: String?
    @State private var draft = ""
    @State private var savedDraft: String?
    @State private var draftSource: URL?
    @State private var draftSpeakerStyle: SpeakerHeaders.Style?
    @State private var savedURL: URL?
    @State private var status = "等待选择音视频"
    @State private var process: Process?
    @State private var progressFile: URL?
    @State private var transcriptionProgress: TranscriptionProgress?
    @State private var cancelling = false
    @State private var failure: String?
    @State private var showingModels = false
    @State private var dropTarget = false
    @State private var advanced = true
    @State private var showingHotwords = false
    @State private var hotwordDraft = ""
    @State private var hotwordError: String?
    @State private var speakerRenameRequest: SpeakerRenameRequest?
    @State private var speakerDraft: [String: String] = [:]
    @State private var renamedSpeakers = Set<String>()
    @AppStorage("hotwordsUseLines") private var hotwordsUseLines = false
    @State private var libraryCategory = "全部"
    @State private var localModels: [String: URL] = [:]

    private var activeModels: [ModelEntry] {
        ModelEntry.catalog.filter { model in
            guard model.available else { return false }
            return switch model.key {
            case "paraformer-zh": model.id == asrID
            case "ct-punc": effectivePunctuation
            case "cam++": speaker
            default: true
            }
        }
    }

    private var supportsHotwords: Bool { asrID == ModelEntry.catalog.first?.id }
    private var senseVoice: Bool { asrID == "iic/SenseVoiceSmall" }
    private var effectivePunctuation: Bool { punctuation && !senseVoice }
    private var transcriptionLanguage: String {
        ModelEntry.catalog.first(where: { $0.id == asrID })?.category ?? "中文"
    }
    private var recognitionModels: [ModelEntry] {
        ModelEntry.catalog.filter { $0.available && $0.key == "paraformer-zh" }
    }
    private var missing: [ModelEntry] { activeModels.filter { localModels[$0.id] == nil } }
    private var hotwordEntries: [String] {
        if hotwordsUseLines { return parseHotwords(hotwords) }
        return parseHotwords(hotwords.split(whereSeparator: \.isWhitespace).joined(separator: "\n"))
    }
    private var dirty: Bool { draftSource != nil && draft != savedDraft }
    private var overrides: [String] { [asr, vad, punc, cam] }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 320, idealWidth: 350, maxWidth: 420)
            editor.frame(minWidth: 530, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button(action: openHotwords) { Label("热词设置", systemImage: "text.badge.plus") }
                    .disabled(process != nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { refreshModels(); showingModels = true } label: {
                    Label("模型库", systemImage: "shippingbox")
                }
                .help("选择和下载本地模型")
            }
        }
        .onAppear(perform: refreshModels)
        .task(id: progressFile) {
            guard let file = progressFile else { return }
            while !Task.isCancelled && progressFile == file {
                if let data = try? Data(contentsOf: file),
                   let update = try? JSONDecoder().decode(TranscriptionProgress.self, from: data),
                   update != transcriptionProgress {
                    transcriptionProgress = update
                }
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
            }
        }
        .onChange(of: modelRoot) { refreshModels() }
        .onChange(of: overrides) { refreshModels() }
        .sheet(isPresented: $showingModels) { modelLibrary }
        .sheet(isPresented: $showingHotwords) { hotwordSettings }
        .sheet(item: $speakerRenameRequest) { request in speakerSettings(labels: request.labels) }
        .alert("无法完成操作", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }

    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("听笺", systemImage: "waveform.path")
                            .font(.title2.weight(.semibold)).foregroundStyle(.primary)
                        Text("选择音视频，生成可编辑的文字稿。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle("音视频", icon: "waveform.circle")
                        Button(action: chooseInput) {
                            VStack(spacing: 7) {
                                Image(systemName: input.isEmpty ? "arrow.down.doc" : "waveform")
                                    .font(.title2).foregroundStyle(Color.accentColor)
                                Text(input.isEmpty ? "选择或拖入文件" : fileURL(input).lastPathComponent)
                                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity).padding(14)
                            .background(Color.accentColor.opacity(dropTarget ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                                Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            ))
                        }
                        .buttonStyle(.plain)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first, url.isFileURL, process == nil else { return false }
                            return selectInput(url.path)
                        } isTargeted: { dropTarget = $0 }
                        TextField("或粘贴文件路径，按回车确认", text: $typedInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { _ = selectInput(typedInput) }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle("识别模型", icon: "cpu")
                        Picker("识别模型", selection: $asrID) {
                            ForEach(["中文", "英文", "多语言"], id: \.self) { language in
                                Section(language) {
                                    ForEach(recognitionModels.filter { $0.category == language }) { model in
                                        Text(model.title + (model.recommendation == nil ? "" : " · 推荐")).tag(model.id)
                                    }
                                }
                            }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            readiness(missing.isEmpty, text: missing.isEmpty ? "所需模型已就绪" : "缺少 \(missing.count) 个模型")
                            Spacer()
                            Button("模型库") { refreshModels(); showingModels = true }
                                .controlSize(.small)
                        }
                        if senseVoice {
                            Label("SenseVoice 自带标点", systemImage: "text.bubble").font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Toggle("恢复标点", isOn: $punctuation)
                        }
                        Toggle("区分说话人", isOn: $speaker)
                    }
                    DisclosureGroup(isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("稿件格式", selection: $plain) {
                                Text("分段记录").tag(false)
                                Text("纯文本").tag(true)
                            }.pickerStyle(.segmented).labelsHidden()
                            Toggle("保留时间戳", isOn: $timestamps).disabled(plain)
                            Toggle("显示说话人标签", isOn: $showSpeakers).disabled(plain || !speaker)
                            formatPreview
                        }.padding(.top, 9)
                    } label: {
                        sectionTitle("稿件格式", icon: "list.bullet.rectangle")
                    }
                }.padding(20).disabled(process != nil)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if progressFile != nil && !cancelling {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(transcriptionProgress?.title ?? "正在准备转写")
                            Spacer()
                            if let percent = transcriptionProgress?.percent {
                                Text("\(percent)%").monospacedDigit()
                            }
                        }.font(.callout.weight(.medium))
                        if let percent = transcriptionProgress?.percent {
                            ProgressView(value: Double(percent), total: 100)
                                .accessibilityLabel("语音识别进度")
                            Text("语音识别剩余 \(100 - percent)%")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        if process != nil { ProgressView().controlSize(.small) }
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if process != nil {
                    Button("取消当前任务", action: cancel)
                        .frame(maxWidth: .infinity).disabled(cancelling)
                } else {
                    Button(action: requestTranscription) {
                        Label(missing.isEmpty ? "开始转写" : "准备模型", systemImage: missing.isEmpty ? "play.fill" : "shippingbox")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16)
        }
        .background(.regularMaterial)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("转写稿").font(.title2.weight(.semibold))
                    if let draftSource {
                        Text(draftSource.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button(action: copyDraft) { Label("复制", systemImage: "doc.on.doc") }
                    .disabled(draftSource == nil)
                Button(action: openSpeakerNames) {
                    Label("说话人重命名", systemImage: "person.text.rectangle")
                }
                .disabled(draftSource == nil || draftSpeakerStyle == nil || process != nil)
                Button(action: saveDraft) { Label("保存 TXT…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(draftSource == nil)
            }.padding(21)
            Divider()
            if draftSource == nil {
                ContentUnavailableView {
                    Label("还没有转写稿", systemImage: "doc.text")
                } description: {
                    Text("转写完成后，全文会显示在这里，可直接修改。")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $draft)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("可编辑转写稿")
                    .disabled(process != nil)
            }
            Divider()
            HStack {
                if draftSource != nil {
                    Text("\(draft.count) 字符")
                    Text(dirty ? (savedDraft == nil ? "未保存" : "保存后有修改") : "已保存").foregroundStyle(dirty ? Color.orange : Color.secondary)
                }
                Spacer()
                if let savedURL {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }.buttonStyle(.link)
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 21).frame(height: 36)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var modelLibrary: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("模型库").font(.title2.weight(.semibold))
                Spacer()
                Button("刷新本地状态", action: refreshModels).disabled(process != nil)
                Button("完成") { showingModels = false }.keyboardShortcut(.defaultAction)
            }
            pathField("模型目录", path: $modelRoot).disabled(process != nil)
            Picker("模型分类", selection: $libraryCategory) {
                ForEach(["全部", "中文", "英文", "多语言", "配套模型", "其他任务"], id: \.self) {
                    Text($0).tag($0)
                }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(["中文", "英文", "多语言", "配套模型", "其他任务"], id: \.self) { category in
                        if libraryCategory == "全部" || libraryCategory == category {
                            sectionTitle(category, icon: category == "配套模型" ? "slider.horizontal.3" : "globe")
                            ForEach(ModelEntry.catalog.filter { $0.category == category }) { model in
                                modelRow(model)
                            }
                        }
                    }
                }
            }
            DisclosureGroup("自定义模型路径") {
                VStack(spacing: 8) {
                    pathField("热词增强模型", path: $asr)
                    pathField("语音检测模型", path: $vad)
                    pathField("标点模型", path: $punc)
                    pathField("说话人模型", path: $cam)
                }.padding(.top, 8)
            }.disabled(process != nil)
            Divider()
            HStack(spacing: 8) {
                if process != nil { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if process != nil {
                    Button("取消当前任务", action: cancel).disabled(cancelling)
                } else {
                    Button("下载所需模型") { download(missing) }
                        .buttonStyle(.borderedProminent).disabled(missing.isEmpty)
                }
            }
        }.padding(22).frame(width: 780, height: 590)
    }

    private func modelRow(_ model: ModelEntry) -> some View {
        let location = localModels[model.id]
        return HStack(spacing: 14) {
            Image(systemName: model.key == "paraformer-zh" ? "waveform" : "slider.horizontal.3")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.title).font(.callout.weight(.semibold))
                    if let recommendation = model.recommendation {
                        Label(recommendation, systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                    }
                }
                Text(model.id).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.note.isEmpty {
                    Text(model.note).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.available || location != nil {
                readiness(location != nil, text: location == nil ? "本地缺失" : "本地已有")
                    .help(location?.path ?? "下载后可本地使用")
            }
            if model.available && model.key == "paraformer-zh" {
                if asrID == model.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        .help("当前识别模型").accessibilityLabel("当前识别模型")
                } else {
                    Button("选用") { asrID = model.id }.disabled(process != nil)
                }
            }
            if model.available {
                Button { download([model]) } label: { Label("下载", systemImage: "arrow.down.circle") }
                    .disabled(process != nil || location != nil)
            } else if let url = URL(string: "https://modelscope.cn/models/" + model.id) {
                Link("模型资料", destination: url).font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var formatPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("格式预览", systemImage: "eye").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: exampleText)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private var exampleText: String {
        let english = transcriptionLanguage == "英文"
        let lines = english ? ["Let's get started.", "I'll introduce the project."] : ["我们开始吧。", "我先介绍一下这个项目。"]
        if plain { return lines.joined(separator: english ? " " : "") }
        let ranges = ["[00:00:02 - 00:00:04]", "[00:00:05 - 00:00:08]"]
        return lines.enumerated().map { index, line in
            var heading: [String] = []
            if timestamps { heading.append(ranges[index]) }
            if speaker && showSpeakers {
                let number = String(index + 1)
                heading.append("Speaker " + number)
            }
            return heading.isEmpty ? line : heading.joined(separator: " ") + "\n" + line
        }.joined(separator: "\n\n")
    }

    private func readiness(_ ready: Bool, text: String) -> some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "arrow.down.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(ready ? Color.green : Color.orange)
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline.weight(.semibold))
    }

    private func parseHotwords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isNewline || "、，,；;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func openHotwords() {
        hotwordDraft = hotwordEntries.joined(separator: "\n")
        hotwordError = nil
        showingHotwords = true
    }

    private var hotwordSettings: some View {
        let entries = parseHotwords(hotwordDraft)
        return VStack(alignment: .leading, spacing: 14) {
            Label("热词设置", systemImage: "text.badge.plus")
                .font(.title2.weight(.semibold))
            Text("把常见的人名、项目名或术语加入转写词表。每行一条，也可以用顿号或逗号分隔。")
                .foregroundStyle(.secondary)
            if !supportsHotwords {
                Label("词表会保留，切换至 Paraformer 热词增强模型后生效。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $hotwordDraft)
                .font(.body).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 245)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                .accessibilityLabel("热词词表")
            HStack {
                Button(action: importHotwords) { Label("导入 UTF-8 TXT…", systemImage: "square.and.arrow.down") }
                Text("共 \(entries.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { showingHotwords = false }
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    hotwords = entries.joined(separator: "\n")
                    hotwordsUseLines = true
                    showingHotwords = false
                }.buttonStyle(.borderedProminent)
            }
            if let hotwordError { Text(hotwordError).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 620, height: 440)
    }

    private func importHotwords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            var imported = try String(contentsOf: file, encoding: .utf8)
            if imported.first == "\u{FEFF}" { imported.removeFirst() }
            hotwordDraft = parseHotwords(hotwordDraft + "\n" + imported).joined(separator: "\n")
            hotwordError = nil
        } catch { hotwordError = "无法读取词表，请使用 UTF-8 编码的 TXT 文件。" }
    }

    private func openSpeakerNames() {
        guard let draftSpeakerStyle else { return }
        let labels = SpeakerHeaders.labels(in: draft, style: draftSpeakerStyle, renamed: renamedSpeakers)
        speakerDraft = [:]
        speakerRenameRequest = SpeakerRenameRequest(labels: labels)
    }

    private func speakerSettings(labels speakerLabels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("说话人重命名", systemImage: "person.text.rectangle")
                .font(.title2.weight(.semibold))
            if speakerLabels.isEmpty {
                ContentUnavailableView(
                    "没有可重命名的说话人标签", systemImage: "person.text.rectangle",
                    description: Text("当前稿件里没有识别到独立的说话人标注行。")
                )
            } else {
                Text("填写新名称，「完成」后会更新当前稿件中对应的说话人标注。")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(speakerLabels, id: \.self) { label in
                            HStack {
                                Text(label).frame(width: 150, alignment: .leading).lineLimit(1)
                                TextField("保持原名", text: Binding(
                                    get: { speakerDraft[label] ?? "" },
                                    set: { speakerDraft[label] = $0 }
                                )).textFieldStyle(.roundedBorder)
                            }
                        }
                    }.padding(.vertical, 3)
                }
            }
            HStack {
                Spacer()
                if !speakerLabels.isEmpty {
                    Button("取消", role: .cancel) { speakerRenameRequest = nil }
                        .keyboardShortcut(.cancelAction)
                }
                Button("完成", action: applySpeakerNames)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 515, height: 340)
    }

    private func applySpeakerNames() {
        let replacements = speakerDraft.compactMapValues { value in
            let name = value.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        if !replacements.isEmpty, let draftSpeakerStyle {
            let updated = SpeakerHeaders.replacing(
                in: draft, style: draftSpeakerStyle, renamed: renamedSpeakers, replacements: replacements
            )
            if updated != draft {
                draft = updated
                renamedSpeakers.formUnion(replacements.values)
                status = "已更新说话人标签"
            }
        }
        speakerRenameRequest = nil
    }

    private func pathField(_ label: String, path: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            TextField(label, text: path).labelsHidden().textFieldStyle(.roundedBorder)
            Button("选择…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }

    private func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func chooseInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        if panel.runModal() == .OK, let url = panel.url { _ = selectInput(url.path) }
    }

    private func refreshModels() {
        guard !modelRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localModels = [:]
            return
        }
        let root = fileURL(modelRoot)
        let explicit = ["paraformer-zh": asr, "fsmn-vad": vad, "ct-punc": punc, "cam++": cam]
        localModels = Dictionary(uniqueKeysWithValues: ModelEntry.catalog.compactMap { model in
            var candidates = [
                root.appendingPathComponent(model.id), root.appendingPathComponent(model.repository),
                root.appendingPathComponent("hub/models").appendingPathComponent(model.id),
                root.appendingPathComponent("models").appendingPathComponent(model.id)
            ]
            if model.legacy {
                if let path = explicit[model.key], !path.isEmpty { candidates.insert(fileURL(path), at: 0) }
                candidates.append(root.appendingPathComponent(model.key))
            }
            return candidates.first(where: modelExists).map { (model.id, $0) }
        })
    }

    private func modelExists(_ directory: URL) -> Bool {
        let manager = FileManager.default
        guard ["config.yaml", "configuration.json"].contains(where: {
            manager.isReadableFile(atPath: directory.appendingPathComponent($0).path)
        }), let files = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return false }
        let extensions = Set(["pt", "pth", "bin", "safetensors"])
        for case let file as URL in files where extensions.contains(file.pathExtension.lowercased()) {
            if let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               info.isRegularFile == true, (info.fileSize ?? 0) > 0 { return true }
        }
        return false
    }

    private func download(_ models: [ModelEntry]) {
        guard !models.isEmpty else { return }
        guard !modelRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failure = "请选择模型目录。"
            return
        }
        run(["action": "download", "modelRoot": fileURL(modelRoot).path, "ids": models.map(\.id)],
            status: models.count == 1 ? "正在下载 \(models[0].title)" : "正在下载 \(models.count) 个模型") { _ in
            refreshModels()
            status = "模型下载完成"
        }
    }

    @discardableResult
    private func selectInput(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "" : fileURL(trimmed).standardizedFileURL.path
        guard normalized != input else {
            typedInput = input
            return true
        }
        if !normalized.isEmpty && needsReplacementConfirmation {
            guard confirmReplacement(detail: "新文件转写完成后会替换右侧稿件。") else {
                typedInput = input
                return false
            }
            confirmedReplacementPath = normalized
        } else {
            confirmedReplacementPath = nil
        }
        input = normalized
        typedInput = normalized
        return true
    }

    private var needsReplacementConfirmation: Bool { draftSource != nil && savedDraft == nil }

    private func confirmReplacement(detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前转写结果尚未保存"
        alert.informativeText = detail
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "继续")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func requestTranscription() {
        guard selectInput(typedInput), !input.isEmpty else { return }
        refreshModels()
        guard missing.isEmpty else { showingModels = true; return }
        if needsReplacementConfirmation && confirmedReplacementPath != input {
            guard confirmReplacement(detail: "新转写完成后会替换右侧稿件。") else { return }
        }
        startTranscription()
    }

    private func startTranscription() {
        let source = fileURL(input)
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            failure = "找不到音视频文件。"
            return
        }
        refreshModels()
        guard missing.isEmpty else { showingModels = true; return }
        let paths = Dictionary(uniqueKeysWithValues: activeModels.compactMap { model in
            localModels[model.id].map { (model.key, $0.path) }
        })
        let speakerLabelsRequested = speaker && showSpeakers && !plain
        let speakerStyle: SpeakerHeaders.Style? = speakerLabelsRequested
            ? (timestamps ? .timestamped : .labelOnly) : nil
        run([
            "input": source.path, "models": paths,
            "speaker": speaker, "showSpeakers": speakerLabelsRequested, "punctuation": effectivePunctuation,
            "senseVoice": senseVoice,
            "prefix": "Speaker ", "names": [String: String](), "timestamps": timestamps, "plain": plain,
            "hotwords": supportsHotwords ? hotwordEntries : []
        ], status: "正在转写 \(source.lastPathComponent)") { directory in
            draft = try String(contentsOf: directory.appendingPathComponent("draft.txt"), encoding: .utf8)
            draftSource = source
            draftSpeakerStyle = speakerStyle
            renamedSpeakers = []
            savedDraft = nil
            savedURL = nil
            confirmedReplacementPath = nil
            status = "转写完成，可以编辑并保存"
        }
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft, forType: .string)
        status = "已复制稿件"
    }

    private func saveDraft() {
        guard let draftSource else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = savedURL?.deletingLastPathComponent()
            ?? (saveFolder.isEmpty ? draftSource.deletingLastPathComponent() : fileURL(saveFolder))
        panel.nameFieldStringValue = savedURL?.lastPathComponent ?? draftSource.deletingPathExtension().lastPathComponent + ".txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.pathExtension.lowercased() == "txt",
              destination.resolvingSymlinksInPath() != draftSource.resolvingSymlinksInPath() else {
            failure = "请选择独立的 .txt 文件。"
            return
        }
        do {
            try draft.write(to: destination, atomically: true, encoding: .utf8)
            savedDraft = draft
            savedURL = destination
            saveFolder = destination.deletingLastPathComponent().path
            status = "已保存 \(destination.lastPathComponent)"
        } catch { failure = error.localizedDescription }
    }

    private func cancel() {
        guard let process, process.isRunning else { return }
        cancelling = true
        status = "正在取消"
        process.terminate()
    }

    private func run(_ job: [String: Any], status runningStatus: String, onSuccess: @escaping (URL) throws -> Void) {
        guard process == nil else { return }
        guard let resources = Bundle.main.resourceURL,
              let worker = Bundle.main.url(forResource: "desktop_worker", withExtension: "py") else {
            failure = "应用资源缺失，请重新安装听笺。"
            return
        }
        let runtime = resources.appendingPathComponent("Runtime", isDirectory: true)
        let bin = runtime.appendingPathComponent("bin", isDirectory: true)
        let python = bin.appendingPathComponent("python3.11")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            failure = "内置运行环境缺失，请重新安装听笺。"
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let specification = directory.appendingPathComponent("job.json")
            try JSONSerialization.data(withJSONObject: job).write(to: specification)
            let log = directory.appendingPathComponent("worker.log")
            try Data().write(to: log)
            let handle = try FileHandle(forWritingTo: log)
            let task = Process()
            task.executableURL = python
            task.arguments = ["-B", "-u", worker.path, specification.path]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "PYTHONPATH")
            environment.removeValue(forKey: "__PYVENV_LAUNCHER__")
            environment["PYTHONHOME"] = runtime.path
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PATH"] = bin.path + ":/usr/bin:/bin"
            environment["NUMBA_CACHE_DIR"] = NSHomeDirectory() + "/Library/Caches/local.funasr.transcription/numba"
            task.environment = environment
            task.standardOutput = handle
            task.standardError = handle
            task.terminationHandler = { finished in
                try? handle.close()
                let message = (try? String(contentsOf: log, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).last.map(String.init)
                DispatchQueue.main.async {
                    defer { try? FileManager.default.removeItem(at: directory) }
                    process = nil
                    progressFile = nil
                    transcriptionProgress = nil
                    refreshModels()
                    if cancelling {
                        status = "任务已取消"
                    } else if finished.terminationStatus == 0 {
                        do { try onSuccess(directory) }
                        catch { status = "任务失败"; failure = error.localizedDescription }
                    } else {
                        status = "任务失败"
                        failure = message ?? "后台任务退出，状态码 \(finished.terminationStatus)。"
                    }
                    cancelling = false
                }
            }
            try task.run()
            process = task
            if job["input"] != nil {
                progressFile = directory.appendingPathComponent("progress.json")
            }
            status = runningStatus
        } catch {
            try? FileManager.default.removeItem(at: directory)
            failure = error.localizedDescription
        }
    }
}
