import SwiftUI
import SwiftData

@main
struct PodSnipApp: App {
    @StateObject private var player = AudioPlayer.shared
    @StateObject private var library = PodcastLibrary()
    @StateObject private var pipeline = SummaryPipeline()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([PodcastFeed.self, EpisodeItem.self, Snip.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
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
