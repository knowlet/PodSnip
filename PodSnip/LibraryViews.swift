import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("節目", systemImage: "mic.fill") }
            SnipListView()
                .tabItem { Label("擷取", systemImage: "bookmark.fill") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
        }
    }
}

struct LibraryView: View {
    @Query(sort: \PodcastFeed.createdAt, order: .reverse) var feeds: [PodcastFeed]
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List(feeds) { feed in
                NavigationLink(destination: EpisodeListView(feed: feed)) {
                    HStack {
                        AsyncImage(url: URL(string: feed.artworkURL ?? "")) { img in
                            img.resizable()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.3))
                        }
                        .frame(width: 56, height: 56)
                        .cornerRadius(8)
                        VStack(alignment: .leading) {
                            Text(feed.title).font(.headline).lineLimit(2)
                            Text("\(feed.episodes.count) 集").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("PodSnip")
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showAdd) { AddFeedView() }
            .overlay {
                if feeds.isEmpty {
                    ContentUnavailableView("還沒有節目", systemImage: "mic",
                                           description: Text("點右上角 ＋ 貼上節目 RSS 連結"))
                }
            }
        }
    }
}

struct AddFeedView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var context
    @EnvironmentObject var library: PodcastLibrary
    @State private var url = ""
    @State private var busy = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("貼上 RSS 連結", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let errorMsg { Text(errorMsg).foregroundStyle(.red).font(.caption) }
                Button(busy ? "抓取中…" : "加入") {
                    Task {
                        busy = true; errorMsg = nil
                        do {
                            _ = try await library.addFeed(urlString: url, context: context)
                            dismiss()
                        } catch { errorMsg = error.localizedDescription }
                        busy = false
                    }
                }
                .disabled(busy || url.isEmpty)
            }
            .navigationTitle("加入節目")
            .toolbar { Button("取消") { dismiss() } }
        }
    }
}

struct EpisodeListView: View {
    var feed: PodcastFeed
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var library: PodcastLibrary
    @Environment(\.modelContext) var context

    var body: some View {
        List(feed.episodes.sorted(by: { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) })) { ep in
            NavigationLink(destination: PlayerView(episode: ep)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ep.title).font(.subheadline).lineLimit(2)
                    HStack(spacing: 8) {
                        if let d = ep.pubDate { Text(d, style: .date).font(.caption) }
                        if ep.hasTranscript { Label("逐字稿", systemImage: "text.quote").font(.caption) }
                        if ep.hasSummary { Label("AI", systemImage: "sparkles").font(.caption) }
                        if let p = library.downloads[ep.id] {
                            ProgressView(value: p).frame(width: 60)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .swipeActions {
                Button("下載") {
                    Task { try? await library.download(ep); try? context.save() }
                }
                .tint(.blue)
            }
        }
        .navigationTitle(feed.title)
    }
}
