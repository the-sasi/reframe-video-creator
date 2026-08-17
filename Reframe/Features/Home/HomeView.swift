import ReframeKit
import SwiftUI

/// One primary action, everything else is recall.
///
/// Deliberately not the six-item grid the brief sketched: in mobile editors one action
/// dominates and the rest is "get me back to what I was doing". So there is one large card,
/// a Continue strip, and a quiet secondary row. Drafts are not a separate destination — an
/// unfinished project *is* a draft, and it appears in Continue.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                createCard

                if !model.recentProjects.isEmpty {
                    continueStrip
                }

                secondaryActions

                if !model.savedRecipes.isEmpty {
                    savedStyles
                }
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reframe")
                .font(Theme.Font.displayTitle)
            Text("Your content, their edit.")
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .padding(.top, Theme.Space.s)
    }

    private var createCard: some View {
        Button {
            model.startFromReference()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Create From Reference")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Pick a reel you like. Reframe learns how it was cut, then rebuilds it with your photos.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Space.xs) {
                    Text("Start")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.Palette.accent)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Theme.Palette.accentSoft, Theme.Palette.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var continueStrip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Continue")
                .font(Theme.Font.sectionTitle)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.m) {
                    ForEach(model.recentProjects) { project in
                        Button {
                            Task { await model.openProject(id: project.id) }
                        } label: {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.deleteProject(id: project.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: Theme.Space.s) {
            SecondaryButton(title: "Start From Scratch", systemImage: "square.stack.3d.up") {
                model.resetFlow()
                model.path.append(.contentImport)
            }
        }
    }

    private var savedStyles: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Saved Styles")
                .font(Theme.Font.sectionTitle)
            Text("Reuse an edit you've already analysed.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)

            ForEach(model.savedRecipes, id: \.id) { recipe in
                Button {
                    model.resetFlow()
                    model.recipe = recipe
                    model.path.append(.contentImport)
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "square.stack")
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(recipe.title)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                                .lineLimit(1)
                            Text("\(recipe.stats.sceneCount) slots · \(recipe.stats.pacingDescription.lowercased())")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .padding(Theme.Space.m)
                    .cardSurface()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProjectCard: View {
    let project: AppModel.ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Palette.surfaceRaised)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(width: 108)
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(project.title)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                Text(project.modifiedAt, format: .relative(presentation: .named))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            .frame(width: 108, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.title), \(project.sceneCount) scenes")
    }
}
