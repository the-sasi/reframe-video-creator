import ReframeKit
import SwiftUI

/// Create, continue, templates. One primary action, everything else is recall.
///
/// The hero card is the product's promise; the two tiles under it are the other ways in; the
/// grid below is "get me back to what I was doing", with rename, duplicate, favourite and
/// delete one long-press away. Templates get a strip here and a full library screen.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var sort: ProjectSort = .recent
    @State private var renaming: AppModel.ProjectSummary?
    @State private var renameText = ""
    @State private var deleting: AppModel.ProjectSummary?

    enum ProjectSort: String, CaseIterable, Identifiable {
        case recent, name, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: return "Recent"
            case .name: return "Name"
            case .favorites: return "Favourites"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                createCard
                secondaryTiles
                projectsSection
                templatesStrip
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.Palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task { await model.refreshLibrary() }
        .refreshable { await model.refreshLibrary() }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { Task { await model.renameProject(id: renaming.id, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                if let deleting { Task { await model.deleteProject(id: deleting.id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Your photos and videos stay in your library — only the project is removed.")
        }
    }

    // MARK: - Header & create

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reframe")
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.Palette.primaryText)
            Text("Your content, their edit.")
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.xs)
    }

    private var createCard: some View {
        Button {
            model.startFromReference()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(alignment: .top) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.Palette.onAccent)
                        .frame(width: 58, height: 58)
                        .background(Theme.Palette.accentGradient, in: Circle())
                        .shadow(color: Theme.Palette.accent.opacity(0.4), radius: 12, y: 5)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(10)
                        .background(Theme.Palette.accentSoft, in: Circle())
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Create From Reference")
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Pick a reel you like. Reframe learns how it was cut, then rebuilds it with your photos, clips and words.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Space.s) {
                    ForEach(
                        [("scissors", "Learns cuts"), ("camera.metering.center.weighted", "Matches framing"), ("waveform", "Finds the beat")],
                        id: \.0
                    ) { symbol, label in
                        HStack(spacing: 4) {
                            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                            Text(label).font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.Palette.surfaceRaised, in: Capsule())
                    }
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .heroSurface()
        }
        .buttonStyle(.plain)
        .pressable()
    }

    private var secondaryTiles: some View {
        HStack(spacing: Theme.Space.s) {
            HomeTile(
                title: "Templates",
                detail: "\(model.templates.count) styles",
                systemImage: "square.grid.2x2"
            ) {
                model.path.append(.templates)
            }
            HomeTile(
                title: "From Scratch",
                detail: "Your own timing",
                systemImage: "square.stack.3d.up"
            ) {
                model.startFromScratch()
            }
        }
    }

    // MARK: - Projects

    private var filteredProjects: [AppModel.ProjectSummary] {
        var projects = model.recentProjects
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmed.isEmpty {
            projects = projects.filter { $0.title.lowercased().contains(trimmed) }
        }
        switch sort {
        case .recent: projects.sort { $0.modifiedAt > $1.modifiedAt }
        case .name: projects.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .favorites: projects.sort { ($0.isFavorite ? 0 : 1, $1.modifiedAt) < ($1.isFavorite ? 0 : 1, $0.modifiedAt) }
        }
        return projects
    }

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Continue").font(Theme.Font.sectionTitle)
                Spacer()
                if model.recentProjects.count > 1 {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(ProjectSort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sort.title)
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            }

            if model.recentProjects.count > 5 {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.tertiaryText)
                    TextField("Search projects", text: $query)
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.tertiaryText)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: 40)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }

            if model.recentProjects.isEmpty {
                EmptyStateView(
                    systemImage: "film.stack",
                    title: "Nothing here yet",
                    message: "Your projects appear here as soon as you make one. Start with a reference or a template."
                )
                .cardSurface(.flat)
            } else if filteredProjects.isEmpty {
                Text("No projects match “\(query)”.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .padding(.vertical, Theme.Space.m)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.s), GridItem(.flexible(), spacing: Theme.Space.s)], spacing: Theme.Space.m) {
                    ForEach(filteredProjects) { project in
                        Button {
                            Task { await model.openProject(id: project.id) }
                        } label: {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(.plain)
                        .pressable()
                        .contextMenu {
                            Button {
                                renameText = project.title
                                renaming = project
                            } label: { Label("Rename", systemImage: "pencil") }
                            Button {
                                Task { await model.toggleFavorite(id: project.id) }
                            } label: {
                                Label(project.isFavorite ? "Unfavourite" : "Favourite", systemImage: project.isFavorite ? "star.slash" : "star")
                            }
                            Button {
                                Task { await model.duplicateProject(id: project.id) }
                            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            Divider()
                            Button(role: .destructive) {
                                deleting = project
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Templates strip

    private var templatesStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Templates").font(Theme.Font.sectionTitle)
                Spacer()
                Button("See all") { model.path.append(.templates) }
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ForEach(model.templates.prefix(8)) { recipe in
                        Button {
                            model.startFromTemplate(recipe)
                        } label: {
                            TemplateCard(recipe: recipe, compact: true)
                        }
                        .buttonStyle(.plain)
                        .pressable()
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - Pieces

private struct HomeTile: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.Palette.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(.flat, radius: Theme.Radius.medium)
        }
        .buttonStyle(.plain)
        .pressable()
    }
}

struct ProjectCard: View {
    let project: AppModel.ProjectSummary
    @State private var poster: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Palette.surfaceRaised, Theme.Palette.surface],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .aspectRatio(max(0.5, min(1.9, project.canvasAspect)), contentMode: .fit)
                .overlay {
                    if let poster {
                        Image(uiImage: poster).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Text(PreviewPane.timecode(project.duration))
                        Text("·")
                        Text("\(project.sceneCount)")
                        Image(systemName: "rectangle.stack").font(.system(size: 8))
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if project.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.title)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                Text(project.modifiedAt, format: .relative(presentation: .named))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
        .task(id: project.thumbnailURL) {
            guard let url = project.thumbnailURL, let data = try? Data(contentsOf: url) else { return }
            poster = UIImage(data: data)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.title), \(project.sceneCount) scenes")
    }
}

/// A style in the library. Draws a schematic of its scene rhythm — the thing that actually
/// distinguishes two templates — over its palette, so the card is honest about what it is.
struct TemplateCard: View {
    let recipe: EditRecipe
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TemplatePreviewTile(recipe: recipe, animated: !compact)
                .frame(width: compact ? 132 : nil, height: compact ? 92 : 108)
                .frame(maxWidth: compact ? nil : .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if recipe.isBuiltIn != true {
                        Text("YOURS")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Palette.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.Palette.accent, in: Capsule())
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(recipe.title)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                Text("\(recipe.stats.sceneCount) scenes · \(String(format: "%.0fs", recipe.duration)) · \(recipe.source.aspect.displayName)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: compact ? 132 : nil, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recipe.title), \(recipe.stats.sceneCount) scenes")
    }
}

/// What a style actually produces: a looping render of its timeline over placeholder art
/// (see `TemplatePreviewStore`). Falls back to the rhythm swatch while rendering or when a
/// preview cannot be made, and says which.
///
/// `animated: false` shows the poster frame instead of a player — the Home strip can hold a
/// dozen cards and a dozen decoders is not a price worth paying for a strip you scroll past.
struct TemplatePreviewTile: View {
    @Environment(AppModel.self) private var model
    let recipe: EditRecipe
    var animated: Bool = true

    var body: some View {
        let store = model.templatePreviews
        ZStack(alignment: .bottomTrailing) {
            if let url = store.previewURL(for: recipe) {
                if animated {
                    ZStack {
                        // Poster under the player until its first frame lands, so the tile
                        // never flashes black.
                        if let poster = store.posters[recipe.id] {
                            Image(uiImage: poster).resizable().scaledToFill()
                        } else {
                            RhythmSwatch(recipe: recipe)
                        }
                        LoopingVideoView(url: url)
                    }
                } else if let poster = store.posters[recipe.id] {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    RhythmSwatch(recipe: recipe)
                }
            } else {
                RhythmSwatch(recipe: recipe)
                statusBadge(store.state(for: recipe))
            }
        }
        .background(Theme.Palette.surfaceRaised)
        .task(id: recipe.id) { store.request(recipe) }
    }

    @ViewBuilder
    private func statusBadge(_ state: TemplatePreviewStore.State?) -> some View {
        switch state {
        case .queued, .rendering:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Preview").font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(6)
        case .unavailable:
            Text("No preview")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(6)
        case .ready, .none:
            EmptyView()
        }
    }
}

/// Scene durations as bars over the recipe's palette. Cheap, deterministic, and it makes a
/// fast reel and a slideshow look different at a glance.
struct RhythmSwatch: View {
    let recipe: EditRecipe

    var body: some View {
        let colors = recipe.palette.dominant.prefix(3).map { Color(hex: $0) }
        let base = colors.isEmpty ? [Theme.Palette.surfaceRaised, Theme.Palette.surface] : colors
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: base, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(.black.opacity(0.18))
            GeometryReader { geometry in
                let scenes = recipe.scenes
                let total = max(0.1, recipe.duration)
                let gap: CGFloat = 2
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(scenes) { scene in
                        let fraction = scene.duration / total
                        let hasMove = scene.move.effectiveKind != .none
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.white.opacity(hasMove ? 0.85 : 0.55))
                            .frame(
                                width: max(2, (geometry.size.width - gap * CGFloat(scenes.count - 1)) * fraction),
                                height: geometry.size.height * (0.28 + 0.4 * min(1, scene.duration / 2.5))
                            )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                .padding(.bottom, 0)
            }
            .padding(10)
        }
    }
}
