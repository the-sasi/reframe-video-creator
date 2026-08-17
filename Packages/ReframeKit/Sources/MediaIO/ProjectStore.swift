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
        exportSettings: ExportSettings = .default
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
    }
}

public struct ExportSettings: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var preferHEVC: Bool

    public init(width: Int, height: Int, fps: Int, preferHEVC: Bool) {
        self.width = width
        self.height = height
        self.fps = fps
        self.preferHEVC = preferHEVC
    }

    public static let `default` = ExportSettings(width: 1080, height: 1920, fps: 30, preferHEVC: true)
    public static let hd720 = ExportSettings(width: 720, height: 1280, fps: 30, preferHEVC: true)
    public static let uhd4K = ExportSettings(width: 2160, height: 3840, fps: 30, preferHEVC: true)

    /// Rough output size, for the storage pre-flight check. Deliberately generous — refusing an
    /// export that would have fit is a smaller failure than starting one that runs out of disk.
    public func estimatedBytes(duration: Double) -> Int64 {
        let pixelsPerSecond = Double(width * height * fps)
        let bitsPerPixel = preferHEVC ? 0.09 : 0.14
        let bitrate = pixelsPerSecond * bitsPerPixel
        return Int64((bitrate / 8) * duration * 1.25)
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
