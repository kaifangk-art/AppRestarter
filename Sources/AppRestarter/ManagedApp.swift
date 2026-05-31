import Foundation

struct ManagedApp: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var bundleIdentifier: String?

    init(id: UUID = UUID(), name: String, path: String, bundleIdentifier: String?) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }
}
