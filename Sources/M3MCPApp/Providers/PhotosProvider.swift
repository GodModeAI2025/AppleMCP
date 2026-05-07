import AppKit
import Foundation
import M3MCPCore
import Photos

final class PhotosProvider {
    func search(input: [String: JSONValue]) async -> ToolResponse {
        let granted = await requestAccess()
        guard granted else {
            return ToolResponse(ok: false, source: "Photos", message: "Photos access was not granted.")
        }

        let query = StringSanitizer.lower(input.string("query"))
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 500), 2_000))

        let assets = matchingAssets(query: query, limit: limit, maxCandidates: maxCandidates)
        let items = assets.map(makeItem)
        let message = items.isEmpty ? "No matching photos found." : nil
        return ToolResponse(ok: true, source: "Photos", items: items, message: message)
    }

    func getAlbums(input: [String: JSONValue]) async -> ToolResponse {
        let granted = await requestAccess()
        guard granted else {
            return ToolResponse(ok: false, source: "Photos", message: "Photos access was not granted.")
        }

        let query = StringSanitizer.lower(input.string("query"))
        let limit = max(1, min(input.int("limit", default: 50), 200))
        let collections = albumCollections(limit: limit, query: query)
        let items = collections.map { collection in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            return DataItem(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "(unnamed album)",
                kind: "photos_album",
                source: "Photos",
                metadata: [
                    "count": String(assets.count),
                    "collection_type": collectionType(collection.assetCollectionType)
                ]
            )
        }

        return ToolResponse(ok: true, source: "Photos", items: items)
    }

    private func matchingAssets(query: String, limit: Int, maxCandidates: Int) -> [PHAsset] {
        var results: [PHAsset] = []
        var seen = Set<String>()

        if !query.isEmpty {
            for collection in albumCollections(limit: 20, query: query) {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = maxCandidates
                let assets = PHAsset.fetchAssets(in: collection, options: options)
                append(assets: assets, to: &results, seen: &seen, query: "", limit: limit, maxCandidates: maxCandidates)
                if results.count >= limit {
                    return results
                }
            }
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = maxCandidates
        let assets = PHAsset.fetchAssets(with: options)
        append(assets: assets, to: &results, seen: &seen, query: query, limit: limit, maxCandidates: maxCandidates)
        return results
    }

    private func append(
        assets: PHFetchResult<PHAsset>,
        to results: inout [PHAsset],
        seen: inout Set<String>,
        query: String,
        limit: Int,
        maxCandidates: Int
    ) {
        let count = min(assets.count, maxCandidates)
        for index in 0..<count {
            if results.count >= limit {
                return
            }

            let asset = assets.object(at: index)
            guard !seen.contains(asset.localIdentifier) else {
                continue
            }

            if query.isEmpty || self.assetMatches(asset, query: query) {
                seen.insert(asset.localIdentifier)
                results.append(asset)
            }
        }
    }

    private func albumCollections(limit: Int, query: String) -> [PHAssetCollection] {
        var collections: [PHAssetCollection] = []
        let options = PHFetchOptions()
        let fetches = [
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options),
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: options)
        ]

        for fetch in fetches {
            fetch.enumerateObjects { collection, _, stop in
                if collections.count >= limit {
                    stop.pointee = true
                    return
                }

                let title = collection.localizedTitle ?? ""
                if query.isEmpty || title.localizedLowercase.contains(query) {
                    collections.append(collection)
                }
            }
        }

        return collections
    }

    private func assetMatches(_ asset: PHAsset, query: String) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first?.originalFilename ?? ""
        let mediaSubtype = mediaSubtypes(asset.mediaSubtypes)
        let haystack = [
            filename,
            mediaType(asset.mediaType),
            mediaSubtype
        ]
        .joined(separator: " ")
        .localizedLowercase
        return haystack.contains(query)
    }

    private func makeItem(asset: PHAsset) -> DataItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first?.originalFilename ?? "(photo)"
        var metadata: [String: String] = [
            "media_type": mediaType(asset.mediaType),
            "media_subtypes": mediaSubtypes(asset.mediaSubtypes),
            "pixel_width": String(asset.pixelWidth),
            "pixel_height": String(asset.pixelHeight),
            "duration": String(asset.duration),
            "local_identifier": asset.localIdentifier
        ]

        let formatter = ISO8601DateFormatter()
        if let created = asset.creationDate {
            metadata["created"] = formatter.string(from: created)
        }
        if let modified = asset.modificationDate {
            metadata["modified"] = formatter.string(from: modified)
        }

        return DataItem(
            id: asset.localIdentifier,
            title: filename,
            kind: "photo",
            source: "Photos",
            preview: "\(mediaType(asset.mediaType)) \(asset.pixelWidth)x\(asset.pixelHeight)",
            metadata: metadata
        )
    }

    @MainActor
    private func requestAccess() async -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            return true
        }
        if current == .denied || current == .restricted {
            return false
        }

        let status: PHAuthorizationStatus = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized || status == .limited
    }

    private func mediaType(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func collectionType(_ type: PHAssetCollectionType) -> String {
        switch type {
        case .album: return "album"
        case .smartAlbum: return "smart_album"
        case .moment: return "moment"
        @unknown default: return "unknown"
        }
    }

    private func mediaSubtypes(_ subtypes: PHAssetMediaSubtype) -> String {
        var values: [String] = []
        if subtypes.contains(.photoPanorama) { values.append("panorama") }
        if subtypes.contains(.photoHDR) { values.append("hdr") }
        if subtypes.contains(.photoScreenshot) { values.append("screenshot") }
        if subtypes.contains(.photoLive) { values.append("live") }
        if subtypes.contains(.videoStreamed) { values.append("streamed") }
        if subtypes.contains(.videoHighFrameRate) { values.append("high_frame_rate") }
        if subtypes.contains(.videoTimelapse) { values.append("timelapse") }
        return values.joined(separator: ",")
    }
}
