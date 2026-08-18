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
                    // A filled circular glyph rather than a bare symbol — gives the card a
                    // focal point at a glance instead of a uniform block of text.
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
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
                    Text("Pick a reel you like. Reframe learns how it was cut, then rebuilds it with your photos.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Space.s) {
                    ForEach(
                        [("scissors", "Learns cuts"), ("camera.filters", "Copies the look"), ("waveform", "Finds the beat")],
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
                .fill(
                    LinearGradient(
                        colors: [Theme.Palette.surfaceRaised, Theme.Palette.surface],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(width: 112)
                .overlay {
                    Image(systemName: "film.stack")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
                .overlay(alignment: .bottomLeading) {
                    // Scene count on the thumbnail: it is the one number that distinguishes
                    // two projects at a glance when neither has a rendered preview yet.
                    Text("\(project.sceneCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(7)
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
            .frame(width: 112, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.title), \(project.sceneCount) scenes")
    }
}
