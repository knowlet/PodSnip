import SwiftUI
import SwiftData

@main
struct PodSnipApp: App {
    @StateObject private var player = AudioPlayer.shared
    @StateObject private var library = PodcastLibrary()
    @StateObject private var pipeline = SummaryPipeline()

    var sharedModelContainer: ModelContainer = {
        do {
            return try PodSnipPersistence.makeContainer()
        } catch {
            fatalError("ModelContainer failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(pipeline)
                .onAppear {
                    player.attach(context: sharedModelContainer.mainContext)
                    Snack.shared.context = sharedModelContainer.mainContext
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

// The app and migration tests share this throwing initialization path. A supplied
// URL isolates synthetic on-disk fixtures; nil preserves the shipped default
// store configuration, location, and automatic lightweight migration behavior.
enum PodSnipPersistence {
    static func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema([PodcastFeed.self, EpisodeItem.self, Snip.self])
        let config: ModelConfiguration
        if let storeURL {
            config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
        // Never delete a store, retry with an empty store, or fall back to memory.
        return try ModelContainer(for: schema, configurations: [config])
    }
}
