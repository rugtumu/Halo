import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Wheels", systemImage: "circle.circle") { WheelsPane() }
            Tab("Formats", systemImage: "square.grid.2x2") { FormatsPane() }
            Tab("Compatibility", systemImage: "tablecells") { CompatibilityPane() }
            Tab("Folders", systemImage: "folder") { FoldersPane() }
            Tab("About", systemImage: "info.circle") { AboutPane() }
        }
        .frame(width: 660, height: 580)
        .tint(HaloPalette.cobalt)
    }
}

private struct GeneralPane: View {
    @AppStorage(Prefs.Key.style) private var style = WheelStyle.glass.rawValue
    @AppStorage(Prefs.Key.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.Key.sound) private var sound = true
    @AppStorage(Prefs.Key.haptic) private var haptic = true
    @AppStorage(Prefs.Key.reveal) private var reveal = false
    @AppStorage(Prefs.Key.floatBehaviour) private var floatBehaviour = FloatBehaviour.new.rawValue
    @AppStorage(Prefs.Key.terminalApp) private var terminalApp = Prefs.defaultTerminal
    @AppStorage(Prefs.Key.modifier(.conversion)) private var conversionKey = WheelKind.conversion.defaultModifier.rawValue
    @AppStorage(Prefs.Key.modifier(.tools)) private var toolsKey = WheelKind.tools.defaultModifier.rawValue
    @AppStorage(Prefs.Key.modifier(.actions)) private var actionsKey = WheelKind.actions.defaultModifier.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Style", selection: $style) {
                    Text("Glass").tag(WheelStyle.glass.rawValue)
                    Text("Solid").tag(WheelStyle.solid.rawValue)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Show Halo in menu bar", isOn: $showMenuBar)
                Toggle("Sound feedback", isOn: $sound)
                Toggle("Haptic feedback", isOn: $haptic)
                Toggle("Reveal results in Finder", isOn: $reveal)
            } header: {
                Text("General")
            } footer: {
                if !showMenuBar { Text("Open Halo again from Applications to get back to Settings.") }
            }

            Section {
                modifierPicker(.conversion, $conversionKey)
                modifierPicker(.tools, $toolsKey)
                modifierPicker(.actions, $actionsKey)
            } header: {
                Text("Drag Modifiers")
            } footer: {
                if Set([conversionKey, toolsKey, actionsKey]).count < 3 {
                    Text("Two wheels share a modifier — only the first one will open.").foregroundStyle(.orange)
                } else {
                    Text("Tap the chosen modifier while dragging files.")
                }
            }

            Section {
                Picker("Float behaviour", selection: $floatBehaviour) {
                    Text("Create a new float").tag(FloatBehaviour.new.rawValue)
                    Text("Add to existing float").tag(FloatBehaviour.existing.rawValue)
                }
                LabeledContent("Terminal app") {
                    HStack {
                        Text(URL(fileURLWithPath: terminalApp).deletingPathExtension().lastPathComponent)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseTerminal)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modifierPicker(_ kind: WheelKind, _ value: Binding<String>) -> some View {
        Picker(kind.title, selection: value) {
            ForEach(ModifierKey.allCases) { Text($0.label).tag($0.rawValue) }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseTerminal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { terminalApp = url.path }
    }
}

private struct FormatsPane: View {
    @AppStorage(Prefs.Key.disabledFormats) private var disabled = ""

    var body: some View {
        Form {
            Text("Choose which targets appear on the conversion wheel.")
                .foregroundStyle(.secondary)
            ForEach(Catalog.matrices) { matrix in
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4)) {
                        ForEach(matrix.columns, id: \.self) { format in
                            Toggle(format.uppercased(), isOn: binding("\(matrix.category.rawValue).\(format)"))
                                .toggleStyle(.checkbox)
                        }
                    }
                } header: {
                    Label(matrix.category.title, systemImage: matrix.category.symbol)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var disabledSet: Set<String> { Set(disabled.split(separator: ",").map(String.init)) }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !disabledSet.contains(key) },
            set: { enabled in
                var set = disabledSet
                if enabled { set.remove(key) } else { set.insert(key) }
                disabled = set.sorted().joined(separator: ",")
            })
    }
}

private struct CompatibilityPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Catalog.matrices) { matrix in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(matrix.category.title, systemImage: matrix.category.symbol).font(.headline)
                        table(matrix)
                    }
                }
                Text("Dimmed ticks need ffmpeg or LibreOffice — see Folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func table(_ matrix: Catalog.Matrix) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 6) {
            GridRow {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                ForEach(matrix.columns, id: \.self) { Text($0.uppercased()).font(.caption2.bold()).frame(maxWidth: .infinity) }
            }
            Divider()
            ForEach(matrix.rows, id: \.source) { row in
                GridRow {
                    Text(row.source.uppercased()).font(.caption2.bold()).gridColumnAlignment(.leading)
                    ForEach(matrix.columns, id: \.self) { column in cell(matrix.category, row, column) }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func cell(_ category: FileCategory, _ row: Catalog.Row, _ column: String) -> some View {
        if row.targets.contains(column) {
            let available = Converter.isAvailable(category, from: row.source, to: column)
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(available ? AnyShapeStyle(HaloPalette.cobalt) : AnyShapeStyle(.tertiary))
                .frame(maxWidth: .infinity)
        } else {
            Text("–").foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }
}

private struct FoldersPane: View {
    @AppStorage(Prefs.Key.outputMode) private var outputMode = "source"
    @AppStorage(Prefs.Key.outputFolder) private var outputFolder = ""

    var body: some View {
        Form {
            Section("Output") {
                Picker("Save results to", selection: $outputMode) {
                    Text("Same folder as the original").tag("source")
                    Text("Custom folder").tag("custom")
                }
                .pickerStyle(.radioGroup)
                if outputMode == "custom" {
                    LabeledContent("Folder") {
                        HStack {
                            Text(outputFolder.isEmpty ? "Not set" : (outputFolder as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }
            }
            Section("Engines") {
                engine("ffmpeg", Binaries.ffmpeg, "Audio, video, WEBP and AVIF")
                engine("LibreOffice", Binaries.soffice, "Office documents and spreadsheets")
            }
        }
        .formStyle(.grouped)
    }

    private func engine(_ name: String, _ url: URL?, _ purpose: String) -> some View {
        LabeledContent {
            Label(url == nil ? "Not found" : "Ready", systemImage: url == nil ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(HaloPalette.cobalt))
        } label: {
            Text(name)
            Text(url?.path ?? purpose)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
    }
}

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .strokeBorder(HaloPalette.spectrum, lineWidth: 10)
                .frame(width: 84, height: 84)
                .shadow(color: HaloPalette.cobalt.opacity(0.4), radius: 18)
            Text("Halo").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Drag a file. Tap a key. Done.").font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WheelsPane: View {
    @AppStorage(Prefs.Key.style) private var style = WheelStyle.glass.rawValue
    @State private var kind = WheelKind.conversion
    @State private var category = FileCategory.image
    @State private var ids: [String] = []

    private var categories: [FileCategory] {
        kind == .tools ? [.image, .audio, .video, .document] : FileCategory.allCases
    }
    private var scopeCategory: FileCategory? { kind == .actions ? nil : category }
    private var key: String { WheelOrder.key(kind, scopeCategory) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $kind) {
                    Text("Conversion").tag(WheelKind.conversion)
                    Text("Tools").tag(WheelKind.tools)
                    Text("Actions").tag(WheelKind.actions)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if kind != .actions {
                    Picker("Files", selection: $category) {
                        ForEach(categories) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }

                List {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            if let symbol = WheelBuilder.item(id, kind: kind)?.symbol {
                                Image(systemName: symbol).frame(width: 20)
                            }
                            Text(WheelBuilder.item(id, kind: kind)?.title ?? id)
                        }
                    }
                    .onMove { from, to in
                        ids.move(fromOffsets: from, toOffset: to)
                        UserDefaults.standard.set(ids.joined(separator: ","), forKey: key)
                    }
                }
                .frame(minHeight: 280)

                HStack(alignment: .top) {
                    Text("Drag to reorder. The first item sits at 12 o’clock, the rest follow clockwise.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: key)
                        load()
                    }
                }
            }

            WheelView(model: .preview(ids.compactMap { WheelBuilder.item($0, kind: kind) }, kind: kind,
                                      style: WheelStyle(rawValue: style) ?? .glass))
                .frame(width: WheelGeometry.size, height: WheelGeometry.size)
                .scaleEffect(0.55)
                .frame(width: WheelGeometry.size * 0.55, height: WheelGeometry.size * 0.55)
                .padding(.top, 30)
        }
        .padding(20)
        .onAppear(perform: load)
        .onChange(of: kind) {
            if !categories.contains(category) { category = .image }
            load()
        }
        .onChange(of: category) { load() }
    }

    private func load() {
        ids = WheelOrder.ordered(WheelOrder.defaultIDs(kind, scopeCategory), saved: WheelOrder.saved(key))
    }
}
