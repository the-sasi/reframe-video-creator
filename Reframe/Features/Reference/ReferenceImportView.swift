import CoreTransferable
import PhotosUI
import ReframeKit
import SwiftUI
import UniformTypeIdentifiers

/// Choosing a reference.
///
/// There is no "Paste Link" field, on purpose. YouTube's terms forbid access by any means other
/// than its own player, Instagram's forbid downloading others' content, and App Review 5.2.1
/// requires documented rights for apps that download media. Rather than ship a field that
/// cannot legitimately work, the screen explains the position and offers the routes that do —
/// which is also the honest UX. See docs/00-research.md §6.
struct ReferenceImportView: View {
    @Environment(AppModel.self) private var model

    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var isLoading = false
    @State private var showsLinkHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Choose a reference")
                        .font(Theme.Font.screenTitle)
                    Text("A reel, short or clip whose editing you like. Reframe reads its structure — it never uses its footage.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: Theme.Space.s) {
                    PhotosPicker(
                        selection: $photoItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        SourceRow(
                            systemImage: "photo.on.rectangle.angled",
                            title: "Choose From Photos",
                            subtitle: "Videos and screen recordings in your library"
                        )
                    }
                    .disabled(isLoading)

                    Button {
                        isImportingFile = true
                    } label: {
                        SourceRow(
                            systemImage: "folder",
                            title: "Import From Files",
                            subtitle: "iCloud Drive, AirDrop, anywhere on device"
                        )
                    }
                    .disabled(isLoading)
                }

                linkExplanation

                if isLoading {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView()
                        Text("Loading video…")
                            .font(Theme.Font.callout)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    .padding(.top, Theme.Space.s)
                }
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Reference")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            switch result {
            case .success(let url):
                handleFileImport(url)
            case .failure:
                model.present(.fileAccessDenied(name: "the selected file"))
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadFromPhotos(item) }
        }
        .sheet(isPresented: $showsLinkHelp) {
            LinkHelpSheet()
        }
    }

    private var linkExplanation: some View {
        Button {
            showsLinkHelp = true
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Got a link instead?")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Reframe doesn't download from Instagram or YouTube. Here's what to do instead.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .background(
                Theme.Palette.surface.opacity(0.6),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let movie = try await item.loadTransferable(type: ReferenceMovie.self) else {
                model.present(.unsupportedFormat(detail: "unreadable Photos item"))
                return
            }
            proceed(with: movie.url)
        } catch {
            model.present(.corruptMedia(detail: error.localizedDescription))
        }
    }

    private func handleFileImport(_ url: URL) {
        // Files hands back a security-scoped URL that expires. Copy into the sandbox now, so
        // analysis cannot fail halfway through because access lapsed.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            proceed(with: destination)
        } catch {
            model.present(.fileAccessDenied(name: url.lastPathComponent))
        }
    }

    private func proceed(with url: URL) {
        model.path.append(.analysis(url))
    }
}

private struct SourceRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.tertiaryText)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct LinkHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Reframe can't download from social apps — their terms don't allow it, and neither does the App Store. Two things work instead:")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HelpStep(
                        number: 1,
                        title: "Screen record it",
                        detail: "Add Screen Recording to Control Centre, play the reel full-screen, and record. The recording lands in Photos and imports straight into Reframe."
                    )
                    HelpStep(
                        number: 2,
                        title: "Save it, if the creator allows",
                        detail: "Some posts offer a download. If it's your own content, or you have permission, save it and import from Files."
                    )

                    Text("Either way, Reframe only reads the *structure* — the timings, the moves, the rhythm. None of the reference's footage ends up in your video.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
            }
            .navigationTitle("Using a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HelpStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("\(number)")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.Palette.onAccent)
                .frame(width: 26, height: 26)
                .background(Theme.Palette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.sectionTitle)
                Text(detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Photos hands back a temporary file that is deleted when the transfer completes, so it has to
/// be copied somewhere we control before it can be analysed.
struct ReferenceMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("reference-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ReferenceMovie(url: destination)
        }
    }
}
