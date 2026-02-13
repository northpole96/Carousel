import SwiftUI
import PhotosUI
import Photos
import Combine


enum MediaItem: Identifiable, Equatable {
    case photo(PHAsset)
    case file(URL)
    
    var id: String {
        switch self {
        case .photo(let asset): return asset.localIdentifier
        case .file(let url): return url.path
        }
    }
}

struct ContentView: View {
    // Media State
    @State private var mediaItems: [MediaItem] = []
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var isAlbumPickerPresented = false
    @State private var albumOptions: [AlbumOption] = []
    @State private var didRestoreSavedAlbum = false
    @State private var showAlbumAlert = false
    @State private var albumAlertMessage = ""
    
    // Viewer Settings (HUD)
    @AppStorage("autoScrollInterval") private var autoScrollInterval: Double = 3.0
    @AppStorage("isAutoScrollEnabled") private var isAutoScrollEnabled: Bool = true
    @AppStorage("itemWidth") private var itemWidth: Double = 600
    @AppStorage("itemHeight") private var itemHeight: Double = 450
    @AppStorage("cardSpacing") private var cardSpacing: Double = 220
    @AppStorage("staggerDelay") private var staggerDelay: Double = 0.05
    
    // UI Visibility
    @State private var isUIVisible = true
    @State private var isCursorHidden = false
    @State private var hoverTask: Task<Void, Never>?
    
    @AppStorage("savedAlbumIdentifier") private var savedAlbumIdentifier: String = ""
    @AppStorage("savedAlbumTitle") private var savedAlbumTitle: String = ""
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: .windowBackgroundColor)
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.15), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()
            
            if mediaItems.isEmpty {
                LandingView(
                    isLoading: isLoading,
                    selectedItems: $selectedItems,
                    selectFromFolder: selectFromFolder,
                    selectFromAlbums: presentAlbumPicker,
                    savedAlbumTitle: savedAlbumTitle,
                    loadSavedAlbum: loadSavedAlbumIfAvailable
                )
            } else {
                OptimizedCarouselView(
                    mediaItems: mediaItems,
                    itemWidth: itemWidth,
                    itemHeight: itemHeight,
                    cardSpacing: cardSpacing,
                    staggerDelay: staggerDelay,
                    interval: autoScrollInterval,
                    isAutoScrollEnabled: isAutoScrollEnabled
                )
                .ignoresSafeArea()
                .overlay(
                    VStack(spacing: 0) {
                        if isUIVisible {
                            CarouselHeader(count: mediaItems.count, onBack: {
                                withAnimation(.spring()) {
                                    mediaItems = []
                                    selectedItems = []
                                    if isCursorHidden {
                                        NSCursor.unhide()
                                        isCursorHidden = false
                                    }
                                }
                            })
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        Spacer()
                    }
                )
                .overlay(alignment: .bottomLeading) {
                    if isUIVisible {
                        CarouselControls(
                            autoScrollInterval: $autoScrollInterval,
                            isAutoScrollEnabled: $isAutoScrollEnabled,
                            itemWidth: $itemWidth,
                            itemHeight: $itemHeight,
                            cardSpacing: $cardSpacing,
                            staggerDelay: $staggerDelay
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onContinuousHover { _ in
                    showUI()
                }
                .onTapGesture {
                    showUI()
                }
            }
            
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onChange(of: selectedItems) { _ in
            loadLibraryPhotos()
        }
        .onAppear {
            guard !didRestoreSavedAlbum else { return }
            didRestoreSavedAlbum = true
            loadSavedAlbumIfAvailable()
        }
        .sheet(isPresented: $isAlbumPickerPresented) {
            AlbumPickerSheet(
                albums: albumOptions,
                savedAlbumIdentifier: savedAlbumIdentifier,
                onSelect: { album in
                    savedAlbumIdentifier = album.id
                    savedAlbumTitle = album.title
                    isAlbumPickerPresented = false
                    loadAlbumPhotos(albumIdentifier: album.id)
                }
            )
        }
        .alert("Photo Albums", isPresented: $showAlbumAlert) {
            Button("Open Settings") {
                openPhotosPrivacySettings()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(albumAlertMessage)
        }
    }
    
    private func selectFromFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        
        if panel.runModal() == .OK {
            var items: [MediaItem] = []
            for url in panel.urls {
                if url.hasDirectoryPath {
                    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    while let fileURL = enumerator?.nextObject() as? URL {
                        items.append(.file(fileURL))
                    }
                } else {
                    items.append(.file(url))
                }
            }
            withAnimation(.spring()) {
                self.mediaItems = items.shuffled()
            }
        }
    }
    
    private func loadLibraryPhotos() {
        guard !selectedItems.isEmpty else { return }
        // For library photos selected via picker, we still need to load data once to get stable identifiers or local URLs
        // but for simplicity and to follow "on demand", we'll just map them.
        // Actually PhotosPickerItem needs async loading. Let's stick to PHAsset where possible.
    }
    
    private func presentAlbumPicker() {
        requestPhotoLibraryAccess { granted in
            guard granted else {
                albumAlertMessage = "Photo Library access is not granted. Allow Photos access for this app in System Settings, then try again."
                showAlbumAlert = true
                return
            }
            
            albumOptions = fetchAlbums()
            guard !albumOptions.isEmpty else {
                albumAlertMessage = "No albums with photos were found."
                showAlbumAlert = true
                return
            }
            
            isAlbumPickerPresented = true
        }
    }
    
    private func loadSavedAlbumIfAvailable() {
        guard !savedAlbumIdentifier.isEmpty else { return }
        loadAlbumPhotos(albumIdentifier: savedAlbumIdentifier)
    }
    
    private func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            completion(false)
        }
    }
    
    private func fetchAlbums() -> [AlbumOption] {
        var options: [AlbumOption] = []
        var seen = Set<String>()
        
        func addCollections(from result: PHFetchResult<PHAssetCollection>) {
            result.enumerateObjects { collection, _, _ in
                let id = collection.localIdentifier
                guard !seen.contains(id) else { return }
                
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                let count = assets.count
                guard count > 0 else { return }
                
                let title = collection.localizedTitle ?? "Untitled Album"
                options.append(AlbumOption(id: id, title: title, count: count))
                seen.insert(id)
            }
        }
        
        addCollections(from: PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
        addCollections(from: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil))
        
        return options.sorted { lhs, rhs in
            let lhsPreferred = preferredAlbumRank(for: lhs.title)
            let rhsPreferred = preferredAlbumRank(for: rhs.title)
            if lhsPreferred != rhsPreferred { return lhsPreferred < rhsPreferred }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
    
    private func preferredAlbumRank(for title: String) -> Int {
        let normalized = title.lowercased()
        if normalized.contains("favorite") { return 0 }
        if normalized.contains("people") { return 1 }
        if normalized.contains("pet") { return 2 }
        return 3
    }
    
    private func loadAlbumPhotos(albumIdentifier: String) {
        requestPhotoLibraryAccess { granted in
            guard granted else { return }
            
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumIdentifier],
                options: nil
            )
            
            guard let collection = collections.firstObject else {
                DispatchQueue.main.async {
                    self.albumAlertMessage = "The saved album was not found. Please select another album."
                    self.showAlbumAlert = true
                    self.mediaItems = []
                }
                return
            }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            
            var items: [MediaItem] = []
            assets.enumerateObjects { asset, _, _ in
                items.append(.photo(asset))
            }
            
            DispatchQueue.main.async {
                withAnimation(.spring()) {
                    self.mediaItems = items.shuffled()
                }
            }
        }
    }
    
    private func openPhotosPrivacySettings() {
        if let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(privacyURL)
        } else if let settingsURL = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(settingsURL)
        }
    }
    
    private func showUI() {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isUIVisible = true
        }
        
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.0)) {
                    isUIVisible = false
                }
                if !isCursorHidden {
                    NSCursor.hide()
                    isCursorHidden = true
                }
            }
        }
    }
}

// MARK: - Components

struct LandingView: View {
    let isLoading: Bool
    @Binding var selectedItems: [PhotosPickerItem]
    let selectFromFolder: () -> Void
    let selectFromAlbums: () -> Void
    let savedAlbumTitle: String
    let loadSavedAlbum: () -> Void
    
    var body: some View {
        VStack(spacing: 35) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.2), radius: 20)
                
                Image(systemName: "photo.stack")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.primary.opacity(0.8))
            }
            
            VStack(spacing: 12) {
                Text("Carousel Viewer")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                
                Text("High-performance infinite gallery")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 25) {
                Button(action: selectFromFolder) {
                    Label("Select Folder", systemImage: "folder.fill")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                PhotosPicker(selection: $selectedItems, matching: .images) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button(action: selectFromAlbums) {
                    Label("Select Album", systemImage: "rectangle.stack.fill")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            if !savedAlbumTitle.isEmpty {
                Button(action: loadSavedAlbum) {
                    Label("Load Saved: \(savedAlbumTitle)", systemImage: "clock.arrow.circlepath")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AlbumOption: Identifiable {
    let id: String
    let title: String
    let count: Int
}

struct AlbumPickerSheet: View {
    let albums: [AlbumOption]
    let savedAlbumIdentifier: String
    let onSelect: (AlbumOption) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    onSelect(album)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                                .foregroundStyle(.primary)
                            Text("\(album.count) photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if album.id == savedAlbumIdentifier {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

struct CarouselHeader: View {
    let count: Int
    let onBack: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "arrow.left.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            
            Text("\(count) Photos Loaded")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .zIndex(10)
    }
}

struct OptimizedCarouselView: View {
    let mediaItems: [MediaItem]
    let itemWidth: Double
    let itemHeight: Double
    let cardSpacing: Double
    let staggerDelay: Double
    let interval: Double
    let isAutoScrollEnabled: Bool
    
    // We use a "virtual" index that grows to keep ForEach identities stable.
    @State private var currentIndex: Int = 0
    @State private var isAnimatingStep: Bool = false
    @State private var itemPositionShifts: [Int: CGFloat] = [:]
    @State private var timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    private let minScale: CGFloat = 0.82
    private let scaleDropPerStep: CGFloat = 0.1
    
    var body: some View {
        GeometryReader { geo in
            let step = CGFloat(itemWidth + cardSpacing)
            
            ZStack {
                // Premium Background Blur with smooth transition
                ZStack {
                    let wrapped = wrappedIndex(currentIndex)
                    CarouselCard(
                        item: mediaItems[wrapped],
                        width: geo.size.width,
                        height: geo.size.height,
                        opacity: 0.2,
                        scale: 1.0,
                        isBackground: true
                    )
                    .id("bg-\(wrapped)")
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                    .blur(radius: 80)
                }
                .ignoresSafeArea()
                
                // Centered Carousel Lane
                ZStack {
                    // We render a window of indices around the current virtual index.
                    // Because identities (the index) stay the same as they move,
                    // CarouselCard views are preserved and don't trigger reloads.
                    ForEach(currentIndex-4...currentIndex+4, id: \.self) { virtualIndex in
                        let item = mediaItems[wrappedIndex(virtualIndex)]
                        
                        let offsetFromCenter = CGFloat(virtualIndex - currentIndex)
                        let shift = itemPositionShifts[virtualIndex] ?? 0
                        let position = offsetFromCenter + shift
                        
                        let visualOffset = laneOffset(for: position)
                        let distance = abs(position)
                        
                        let scale = scaleForPosition(distance)
                        let opacity = max(0, min(1.0, 1.2 - (distance * 0.4)))

                        CarouselCard(
                            item: item,
                            width: itemWidth,
                            height: itemHeight,
                            opacity: opacity,
                            scale: scale
                        )
                        .offset(x: visualOffset)
                        .zIndex(10 - Double(distance))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
        }
        .onReceive(timer) { _ in
            guard isAutoScrollEnabled && !isAnimatingStep else { return }
            performStep(drift: 1)
        }
        .onChange(of: interval) { newInterval in
            resetTimer(newInterval)
        }
        .onAppear {
            resetTimer(interval)
        }
    }
    
    private func wrappedIndex(_ index: Int) -> Int {
        guard !mediaItems.isEmpty else { return 0 }
        let count = mediaItems.count
        return ((index % count) + count) % count
    }
    
    private func resetTimer(_ newInterval: Double) {
        timer.upstream.connect().cancel()
        timer = Timer.publish(every: max(0.1, newInterval), on: .main, in: .common).autoconnect()
    }
    
    private func scaleForPosition(_ distance: CGFloat) -> Double {
        let scale = max(minScale, 1.0 - (distance * scaleDropPerStep))
        return Double(scale)
    }
    
    private func laneOffset(for position: CGFloat) -> CGFloat {
        let sign: CGFloat = position < 0 ? -1 : 1
        let distance = abs(position)
        let integral = integratedScale(fromZeroTo: distance)
        return sign * (CGFloat(cardSpacing) * distance + CGFloat(itemWidth) * integral)
    }
    
    private func integratedScale(fromZeroTo distance: CGFloat) -> CGFloat {
        guard distance > 0 else { return 0 }
        
        let linearLimit = (1.0 - minScale) / scaleDropPerStep
        if distance <= linearLimit {
            return distance - (scaleDropPerStep * distance * distance / 2.0)
        }
        
        let linearArea = linearLimit - (scaleDropPerStep * linearLimit * linearLimit / 2.0)
        let tailDistance = distance - linearLimit
        return linearArea + minScale * tailDistance
    }
    
    private func performStep(drift: Int) {
        guard !isAnimatingStep else { return }
        isAnimatingStep = true
        
        // Stop timer to prevent inconsistent overlaps or skipped beats
        timer.upstream.connect().cancel()
        
        let maxDelay = Double(4) * staggerDelay 
        
        for virtualIndex in currentIndex-4...currentIndex+4 {
            let relativeIndex = virtualIndex - currentIndex
            let delay = max(0, Double(relativeIndex + 2) * staggerDelay)
            
            withAnimation(.interpolatingSpring(stiffness: 300, damping: 32).delay(delay)) {
                itemPositionShifts[virtualIndex] = -CGFloat(drift)
            }
        }
        
        let totalTime = maxDelay + 0.7
        
        DispatchQueue.main.asyncAfter(deadline: .now() + totalTime) {
            currentIndex = currentIndex + drift
            itemPositionShifts.removeAll()
            isAnimatingStep = false
            
            // Restart timer only after animation has fully settled
            // This ensures the 'rest' period is always exactly what the user selected
            if isAutoScrollEnabled {
                resetTimer(interval)
            }
        }
    }
}


struct CarouselCard: View {
    let item: MediaItem
    let width: Double
    let height: Double
    let opacity: Double
    let scale: Double
    var isBackground: Bool = false
    
    @State private var image: NSImage?
    private let manager = PHCachingImageManager.default()
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.1)
                    .overlay(isBackground ? nil : ProgressView().controlSize(.small))
            }
        }
        .frame(width: width, height: height)
        .clipShape(isBackground ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
        .scaleEffect(scale)
        .overlay(
            Group {
                if !isBackground {
                    // Removed border for a cleaner look
                }
            }
        )
        .shadow(color: isBackground ? .clear : .black.opacity(0.4), radius: 25, x: 0, y: 15)
        .opacity(opacity)
        .onAppear { loadImage() }
        .onChange(of: item) { _ in loadImage() }
    }
    
    private func loadImage() {
        switch item {
        case .photo(let asset):
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            
            // Higher res for background blur to avoid pixelation
            let multiplier: CGFloat = isBackground ? 1.0 : 2.0
            let targetSize = CGSize(width: width * multiplier, height: height * multiplier)
            
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { img, _ in
                self.image = img
            }
        case .file(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                if let img = NSImage(contentsOf: url) {
                    DispatchQueue.main.async {
                        self.image = img
                    }
                }
            }
        }
    }
}

// Helper to handle conditional shapes
struct AnyShape: Shape {
    private let _path: (CGRect) -> Path
    
    init<S: Shape>(_ shape: S) {
        _path = { rect in shape.path(in: rect) }
    }
    
    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}


struct CarouselControls: View {
    @Binding var autoScrollInterval: Double
    @Binding var isAutoScrollEnabled: Bool
    @Binding var itemWidth: Double
    @Binding var itemHeight: Double
    @Binding var cardSpacing: Double
    @Binding var staggerDelay: Double
    
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .black))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        
                        Text("VIEWER SETTINGS")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if isExpanded {
                    Toggle("", isOn: $isAutoScrollEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            
            if isExpanded {
                VStack(spacing: 12) {
                    ControlSlider(label: "Interval", value: $autoScrollInterval, range: 0.1...10)
                    Divider().opacity(0.3)
                    ControlSlider(label: "Width", value: $itemWidth, range: 400...900)
                    ControlSlider(label: "Height", value: $itemHeight, range: 300...1000)
                    ControlSlider(label: "Gap", value: $cardSpacing, range: 10...500)
                    ControlSlider(label: "Stagger", value: $staggerDelay, range: 0...0.2)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -10)),
                    removal: .opacity.combined(with: .offset(y: -10))
                ))
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .frame(width: 220)
        .padding(30)
    }
}

struct ControlSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if label == "Interval" {
                    Text(String(format: "%.1fs", value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.primary)
                } else if label == "Stagger" {
                    Text(String(format: "%.2fs", value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text(String(format: "%.0f", value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

#Preview {
    ContentView()
}

