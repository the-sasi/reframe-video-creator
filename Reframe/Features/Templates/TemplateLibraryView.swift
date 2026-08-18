import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// Every style available: the ones analysed from references and the built-in starters, filtered
/// by category. Tap to start a project; long-press for rename, duplicate, export, delete.
struct TemplateLibraryView: View {
    @Environment(AppModel.self) private var model

    @State private var category = "All"
    @State private var query = ""
    @State private var renaming: EditRecipe?
    @State private var renameText = ""
    @State private var deleting: EditRecipe?
    @State private var shareURL: URL?
    @State private var isImporting = false
    @State private var previewing: EditRecipe?

    private var categories: [String] {
        var seen: [String] = []
        for recipe in model.templates {
            for tag in recipe.displayTags where !seen.contains(tag) { seen.append(tag) }
        }
        return ["All", "Yours"] + seen.sorted()
    }

    private var filtered: [EditRecipe] {
        var recipes = model.templates
        if category == "Yours" {
            recipes = recipes.filter { $0.isBuiltIn != true }
        } else if category != "All" {
            recipes = recipes.filter { $0.displayTags.contains(category) }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmed.isEmpty {
            recipes = recipes.filter { $0.title.lowercased().contains(trimmed) || $0.displayTags.joined(separator: " ").lowercased().contains(trimmed) }
        }
        return recipes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ChipRow(items: categories, title: { $0 }, selection: $category)

                if filtered.isEmpty {
                    EmptyStateView(
                        systemImage: "square.grid.2x2",
                        title: category == "Yours" ? "No saved styles yet" : "Nothing in this category",
                        message: category == "Yours"
                            ? "Analyse a reference and its style is saved here automatically. You can also import a .reframestyle file."
                            : "Try another category, or import a style file.",
                        actionTitle: "Import a style",
                        action: { isImporting = true }
                    )
                    .cardSurface(.flat)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible(), spacing: Theme.Space.s)], spacing: Theme.Space.m) {
                        ForEach(filtered) { recipe in
                            Button {
                                previewing = recipe
                            } label: {
                                TemplateCard(recipe: recipe)
                            }
                            .buttonStyle(.plain)
                            .pressable()
                            .contextMenu {
                                Button {
                                    model.startFromTemplate(recipe)
                                } label: { Label("Use", systemImage: "play.fill") }
                                Button {
                                    Task { await model.duplicateRecipe(recipe) }
                                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                if recipe.isBuiltIn != true {
                                    Button {
                                        renameText = recipe.title
                                        renaming = recipe
                                    } label: { Label("Rename", systemImage: "pencil") }
                                }
                                Button {
                                    Task { shareURL = await model.exportRecipeFile(recipe) }
                                } label: { Label("Export style file", systemImage: "square.and.arrow.up") }
                                if recipe.isBuiltIn != true {
                                    Divider()
                                    Button(role: .destructive) {
                                        deleting = recipe
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search styles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import a style file")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "reframestyle") ?? .json, .json]
        ) { result in
            if case .success(let url) = result {
                Task { await model.importRecipeFile(url) }
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .sheet(item: $previewing) { recipe in
            TemplatePreviewSheet(recipe: recipe) {
                previewing = nil
                model.startFromTemplate(recipe)
            }
        }
        .alert("Rename style", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { Task { await model.renameRecipe(id: renaming.id, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Style", role: .destructive) {
                if let deleting { Task { await model.deleteRecipe(id: deleting.id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Projects already made with it are unaffected.")
        }
    }
}

/// What a template is, before committing to it: rhythm, moves, text slots, tags.
private struct TemplatePreviewSheet: View {
    let recipe: EditRecipe
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    HStack {
                        Spacer(minLength: 0)
                        TemplatePreviewTile(recipe: recipe, animated: true)
                            .aspectRatio(recipe.canvas.aspectRatio, contentMode: .fit)
                            .frame(maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                            }
                        Spacer(minLength: 0)
                    }
                    Text("Preview uses placeholder photos. Your own photos and words go in the same places.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)

                    HStack(spacing: 0) {
                        MetricTile(value: "\(recipe.stats.sceneCount)", label: "scenes", systemImage: "rectangle.stack")
                        Divider().frame(height: 34)
                        MetricTile(value: String(format: "%.0fs", recipe.duration), label: "length", systemImage: "clock")
                        Divider().frame(height: 34)
                        MetricTile(value: "\(recipe.stats.transitionCount)", label: "transitions", systemImage: "arrow.left.arrow.right")
                        Divider().frame(height: 34)
                        MetricTile(value: "\(recipe.stats.textSlotCount)", label: "text", systemImage: "textformat")
                    }
                    .cardSurface()

                    HStack(spacing: Theme.Space.xs) {
                        ForEach(recipe.displayTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Theme.Palette.surfaceRaised, in: Capsule())
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer()
                        Text(recipe.stats.pacingDescription)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Scenes").font(Theme.Font.sectionTitle)
                        ForEach(recipe.scenes.prefix(12)) { scene in
                            HStack(spacing: Theme.Space.s) {
                                Text("\(scene.index + 1)")
                                    .font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(Theme.Palette.tertiaryText)
                                    .frame(width: 18)
                                Text(scene.role.value.displayName)
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                Text("·").foregroundStyle(Theme.Palette.tertiaryText)
                                Text(scene.slot.framing.value.displayName.lowercased())
                                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                                if scene.move.effectiveKind != .none {
                                    Text("·").foregroundStyle(Theme.Palette.tertiaryText)
                                    Text(scene.move.effectiveKind.displayName.lowercased())
                                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.accent)
                                }
                                Spacer()
                                Text(String(format: "%.1fs", scene.duration))
                                    .font(.system(.caption, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                        if recipe.scenes.count > 12 {
                            Text("+ \(recipe.scenes.count - 12) more")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.tertiaryText)
                        }
                    }
                    .padding(Theme.Space.m)
                    .cardSurface(.flat)
                }
                .padding(Theme.Space.m)
                .padding(.bottom, 90)
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Use This Style", systemImage: "checkmark") { onUse() }
                    .padding(Theme.Space.m)
                    .background(.regularMaterial)
            }
        }
        .presentationDetents([.large])
    }
}
