import Foundation
import RecipeCore

/// Everything one project consists of.
public struct Project: Codable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date

    public var timeline: Timeline
    public var assets: AssetPool
    public var content: UserContent
    public var assignment: AssetAssignment
    public var recipeID: UUID?
    public var exportSettings: ExportSettings
    /// Vision features per asset, so re-arranging or replacing a photo later never re-runs
    /// analysis on the ones that have not changed.
    public var assetFeatures: [UUID: AssetFeatures]
    public var fidelity: BindingFidelity
    public var isFavorite: Bool
    /// Path of the poster frame inside the package's `thumbnails/`, if one has been rendered.
    public var thumbnailPath: String?

    public init(
        schemaVersion: Int = RecipeSchema.current,
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        timeline: Timeline,
        assets: AssetPool = AssetPool(),
        content: UserContent = UserContent(),
        assignment: AssetAssignment = AssetAssignment(),
        recipeID: UUID? = nil,
        exportSettings: ExportSettings = .default,
        assetFeatures: [UUID: AssetFeatures] = [:],
        fidelity: BindingFidelity = .closeMatch,
        isFavorite: Bool = false,
        thumbnailPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.timeline = timeline
        self.assets = assets
        self.content = content
        self.assignment = assignment
        self.recipeID = recipeID
        self.exportSettings = exportSettings
        self.assetFeatures = assetFeatures
        self.fidelity = fidelity
        self.isFavorite = isFavorite
        self.thumbnailPath = thumbnailPath
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, modifiedAt, timeline, assets, content
        case assignment, recipeID, exportSettings, assetFeatures, fidelity, isFavorite, thumbnailPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        timeline = try c.decode(Timeline.self, forKey: .timeline)
        assets = try c.decodeIfPresent(AssetPool.self, forKey: .assets) ?? AssetPool()
        content = try c.decodeIfPresent(UserContent.self, forKey: .content) ?? UserContent()
        assignment = try c.decodeIfPresent(AssetAssignment.self, forKey: .assignment) ?? AssetAssignment()
        recipeID = try c.decodeIfPresent(UUID.self, forKey: .recipeID)
        exportSettings = try c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? .default
        assetFeatures = try c.decodeIfPresent([UUID: AssetFeatures].self, forKey: .assetFeatures) ?? [:]
        fidelity = try c.decodeIfPresent(BindingFidelity.self, forKey: .fidelity) ?? .closeMatch
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        thumbnailPath = try c.decodeIfPresent(String.self, forKey: .thumbnailPath)
    }
}

/// Output quality tier. Maps to a bitrate multiplier; explained to the user in plain words
/// rather than megabits.
public enum ExportQuality: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case standard
    case high
    case maximum

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    public var explanation: String {
        switch self {
        case .standard: return "Smallest file. Fine for messaging and stories."
        case .high: return "The usual choice — indistinguishable from Maximum on a phone, half the size."
        case .maximum: return "Largest file, for uploads that get re-compressed anyway."
        }
    }

    var bitrateMultiplier: Double {
        switch self {
        case .standard: return 0.65
        case .high: return 1.0
        case .maximum: return 1.6
        }
    }
}

public struct ExportSettings: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var preferHEVC: Bool
    public var quality: ExportQuality

    public init(width: Int, height: Int, fps: Int, preferHEVC: Bool, quality: ExportQuality = .high) {
        self.width = width
        self.height = height
        self.fps = fps
        self.preferHEVC = preferHEVC
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey { case width, height, fps, preferHEVC, quality }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        fps = try c.decode(Int.self, forKey: .fps)
        preferHEVC = try c.decodeIfPresent(Bool.self, forKey: .preferHEVC) ?? true
        quality = try c.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high
    }

    public static let `default` = ExportSettings(width: 1080, height: 1920, fps: 30, preferHEVC: true)
    public static let hd720 = ExportSettings(width: 720, height: 1280, fps: 30, preferHEVC: true)
    public static let uhd4K = ExportSettings(width: 2160, height: 3840, fps: 30, preferHEVC: true)

    /// Settings matched to a canvas at a given resolution tier. `tier` is the shorter side:
    /// 720, 1080 or 2160. Landscape and square canvases keep their shape — an earlier version
    /// hard-coded 9:16 sizes and stretched every other canvas.
    public static func matching(canvas: CanvasSpec, shortSide tier: Int, preferHEVC: Bool = true, quality: ExportQuality = .high) -> ExportSettings {
        let aspect = canvas.aspectRatio
        var width: Int
        var height: Int
        if aspect >= 1 {
            height = tier
            width = Int((Double(tier) * aspect).rounded())
        } else {
            width = tier
            height = Int((Double(tier) / aspect).rounded())
        }
        width -= width % 2
        height -= height % 2
        return ExportSettings(width: width, height: height, fps: canvas.fps, preferHEVC: preferHEVC, quality: quality)
    }

    /// The tier this represents (the shorter side, snapped to 720/1080/2160).
    public var shortSideTier: Int {
        let short = min(width, height)
        if short <= 720 { return 720 }
        if short >= 2160 { return 2160 }
        return 1080
    }

    /// Bits per second the encoder is asked for.
    public var bitrate: Int {
        let pixelsPerSecond = Double(width * height * fps)
        let bitsPerPixel = preferHEVC ? 0.09 : 0.14
        return Int(pixelsPerSecond * bitsPerPixel * quality.bitrateMultiplier)
    }

    /// Rough output size, for the storage pre-flight check and the export screen. Deliberately
    /// generous — refusing an export that would have fit is a smaller failure than starting one
    /// that runs out of disk.
    public func estimatedBytes(duration: Double) -> Int64 {
        Int64((Double(bitrate) / 8) * duration * 1.2) + 200_000
    }
}

/// Filesystem persistence.
///
/// Projects are packages of JSON plus caches. The user's originals are never copied — see
/// `AssetReference`. A 20-photo project is a few kilobytes.
public actor ProjectStore {

    private let root: URL
    private let fileManager = FileManager.default

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var projectsRoot: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    private var recipesRoot: URL { root.appendingPathComponent("Recipes", isDirectory: true) }

    private func packageURL(_ id: UUID) -> URL {
        projectsRoot.appendingPathComponent("\(id.uuidString).reframeproj", isDirectory: true)
    }

    // MARK: - Projects

    public func save(_ project: Project, history: TimelineDocument.PersistedHistory? = nil) throws {
        let package = packageURL(project.id)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        try createCacheDirectories(in: package)

        var project = project
        project.modifiedAt = Date()

        let data = try RecipeSchema.encoder.encode(project)
        // Atomic write: a force-quit mid-save must not leave a truncated project.
        try data.write(to: package.appendingPathComponent("project.json"), options: .atomic)

        if let history {
            let historyData = try RecipeSchema.encoder.encode(history)
            try historyData.write(to: package.appendingPathComponent("history.json"), options: .atomic)
        }
    }

    public func load(id: UUID) throws -> Project {
        let url = packageURL(id).appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ReframeError.documentCorrupt(detail: "project.json missing")
        }
        let data = try Data(contentsOf: url)
        let version = try RecipeSchema.peekVersion(data)
        guard version <= RecipeSchema.current else {
            throw ReframeError.documentTooNew(found: version, supported: RecipeSchema.current)
        }
        do {
            return try RecipeSchema.decoder.decode(Project.self, from: data)
        } catch {
            throw ReframeError.documentCorrupt(detail: error.localizedDescription)
        }
    }

    public func loadHistory(id: UUID) -> TimelineDocument.PersistedHistory? {
        let url = packageURL(id).appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? RecipeSchema.decoder.decode(TimelineDocument.PersistedHistory.self, from: data)
    }

    public func delete(id: UUID) throws {
        try fileManager.removeItem(at: packageURL(id))
    }

    /// A copy under a fresh id, titled "<title> copy". History is not carried over — the copy
    /// starts with a clean undo stack, which is what people expect of a duplicate.
    public func duplicate(id: UUID) throws -> Project {
        var copy = try load(id: id)
        let sourceThumbnail = copy.thumbnailPath.map { thumbnailsURL(projectID: id).appendingPathComponent($0) }
        copy.id = UUID()
        copy.title = copy.title.hasSuffix(" copy") ? copy.title : "\(copy.title) copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        try save(copy)
        if let sourceThumbnail, let name = copy.thumbnailPath,
           fileManager.fileExists(atPath: sourceThumbnail.path) {
            let destination = thumbnailsURL(projectID: copy.id).appendingPathComponent(name)
            try? fileManager.copyItem(at: sourceThumbnail, to: destination)
        }
        return copy
    }

    /// Writes a poster frame into the package and records its name on the project.
    public func saveThumbnail(_ pngData: Data, projectID: UUID) throws -> String {
        let directory = thumbnailsURL(projectID: projectID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "poster.png"
        try pngData.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func thumbnailURL(projectID: UUID, name: String) -> URL {
        thumbnailsURL(projectID: projectID).appendingPathComponent(name)
    }

    /// Lists projects by scanning the filesystem rather than by querying the index.
    ///
    /// The SwiftData store is an index, not a document store — if it were lost, every project
    /// would still be recoverable this way. Used to rebuild the index on first launch after an
    /// upgrade, and as the fallback if the index is corrupt.
    public func listProjectIDs() throws -> [UUID] {
        guard fileManager.fileExists(atPath: projectsRoot.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        return contents.compactMap { url in
            guard url.pathExtension == "reframeproj" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Recipes

    /// Recipes live outside projects because they are reusable across them — that reusability
    /// is the whole point of the abstraction, and storing them inside a project would bury it.
    public func save(recipe: EditRecipe) throws {
        try fileManager.createDirectory(at: recipesRoot, withIntermediateDirectories: true)
        let data = try RecipeSchema.encoder.encode(recipe)
        let url = recipesRoot.appendingPathComponent("\(recipe.id.uuidString).editrecipe.json")
        try data.write(to: url, options: .atomic)
    }

    public func loadRecipe(id: UUID) throws -> EditRecipe {
        let url = recipesRoot.appendingPathComponent("\(id.uuidString).editrecipe.json")
        let data = try Data(contentsOf: url)
        return try RecipeSchema.decodeRecipe(data)
    }

    public func listRecipes() throws -> [EditRecipe] {
        guard fileManager.fileExists(atPath: recipesRoot.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(at: recipesRoot, includingPropertiesForKeys: nil)
        return contents.compactMap { url in
            guard url.lastPathComponent.hasSuffix(".editrecipe.json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? RecipeSchema.decodeRecipe(data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func deleteRecipe(id: UUID) throws {
        try fileManager.removeItem(
            at: recipesRoot.appendingPathComponent("\(id.uuidString).editrecipe.json")
        )
    }

    /// The recipe as a shareable file. Recipes carry no pixels and no paths — see
    /// `EditRecipe` — so this is safe to hand to anyone.
    public func exportRecipe(_ recipe: EditRecipe) throws -> URL {
        let data = try RecipeSchema.encoder.encode(recipe)
        let safeTitle = recipe.title
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let name = (safeTitle.isEmpty ? "Reframe Style" : safeTitle) + ".reframestyle"
        let url = fileManager.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Reads a recipe file. Assigns a fresh id if one with the same id is already saved, so
    /// importing a style twice makes two entries rather than overwriting.
    public func importRecipe(from url: URL) throws -> EditRecipe {
        let data = try Data(contentsOf: url)
        var recipe = try RecipeSchema.decodeRecipe(data)
        if fileManager.fileExists(atPath: recipesRoot.appendingPathComponent("\(recipe.id.uuidString).editrecipe.json").path) {
            recipe.id = UUID()
        }
        recipe.isBuiltIn = false
        try save(recipe: recipe)
        return recipe
    }

    // MARK: - Caches

    public func thumbnailsURL(projectID: UUID) -> URL {
        packageURL(projectID).appendingPathComponent("thumbnails", isDirectory: true)
    }

    public func proxiesURL(projectID: UUID) -> URL {
        packageURL(projectID).appendingPathComponent("proxies", isDirectory: true)
    }

    /// Caches are regenerable, so they are excluded from backup and dropped under pressure.
    /// Losing them costs time; it never costs data.
    private func createCacheDirectories(in package: URL) throws {
        for name in ["thumbnails", "proxies"] {
            var url = package.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    public func purgeCaches(projectID: UUID) {
        try? fileManager.removeItem(at: proxiesURL(projectID: projectID))
        try? fileManager.removeItem(at: thumbnailsURL(projectID: projectID))
    }

    public func availableStorageBytes() -> Int64 {
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return .max
        }
        return available
    }
}
