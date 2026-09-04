import Foundation
import M3MCPCore
import Photos

final class PhotosProvider {
    static let maximumQueryUTF8Bytes = 4_096
    static let maximumSearchFieldUTF8Bytes = 16 * 1_024
    static let maximumIdentifierUTF8Bytes = 2_048
    static let maximumTitleUTF8Bytes = 1_024
    static let maximumAlbumCandidates = 2_000

    private struct AssetPage {
        let assets: [PHAsset]
        let inspected: Int
        let budgetCapped: Bool
        let outputLimitCapped: Bool
        let albumScopeCapped: Bool
        let searchContentCapped: Bool
    }

    private struct AlbumPage {
        let collections: [PHAssetCollection]
        let inspected: Int
        let available: Int
        let budgetCapped: Bool
        let outputLimitCapped: Bool
        let searchContentCapped: Bool

        var scopeCapped: Bool { budgetCapped || outputLimitCapped }
    }

    func search(input: [String: JSONValue]) async -> ToolResponse {
        guard !Task.isCancelled else {
            return ToolResponse(ok: false, source: "Photos", message: "Photos request was cancelled.")
        }
        let rawQuery = input.string("query")
        guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
            return ToolResponse(
                ok: false,
                source: "Photos",
                message: "Photos query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit."
            )
        }
        guard hasReadAccess else {
            return ToolResponse(
                ok: false,
                source: "Photos",
                message: "Photos access is not authorized. Grant it in System Settings, or explicitly enable and call permissions_request."
            )
        }

        let query = StringSanitizer.lower(rawQuery)
        let limit = max(1, min(input.int("limit", default: 25), 100))
        let maxCandidates = max(limit, min(input.int("max_candidates", default: 500), 2_000))

        let page = matchingAssets(query: query, limit: limit, maxCandidates: maxCandidates)
        guard !Task.isCancelled else {
            return ToolResponse(ok: false, source: "Photos", message: "Photos request was cancelled.")
        }
        let items = page.assets.map(makeItem)
        let message: String?
        if page.budgetCapped {
            message = "Photos search reached its \(maxCandidates)-asset inspection budget; narrow the query or raise max_candidates."
        } else if page.albumScopeCapped {
            message = "Photos inspected a bounded subset of albums; additional album-title matches may exist."
        } else if page.searchContentCapped {
            message = "Some photo fields exceeded the per-field search budget; matches beyond those prefixes were not inspected."
        } else if page.outputLimitCapped {
            message = "More photos may match; increase limit."
        } else {
            message = items.isEmpty ? "No matching photos found." : nil
        }
        let truncated = page.budgetCapped || page.outputLimitCapped
            || page.albumScopeCapped || page.searchContentCapped
        return ToolResponse(
            ok: true,
            source: "Photos",
            items: items,
            message: message,
            meta: [
                "returned": String(items.count),
                "inspected": String(page.inspected),
                "scan_budget": String(maxCandidates),
                "scan_capped": String(page.budgetCapped),
                "output_limit_capped": String(page.outputLimitCapped),
                "album_scope_capped": String(page.albumScopeCapped),
                "search_content_capped": String(page.searchContentCapped),
                "has_more": String(truncated),
                "truncated": String(truncated)
            ]
        )
    }

    func getAlbums(input: [String: JSONValue]) async -> ToolResponse {
        guard !Task.isCancelled else {
            return ToolResponse(ok: false, source: "Photos", message: "Photos request was cancelled.")
        }
        let rawQuery = input.string("query")
        guard rawQuery.utf8.count <= Self.maximumQueryUTF8Bytes else {
            return ToolResponse(
                ok: false,
                source: "Photos",
                message: "Photos album query exceeds the \(Self.maximumQueryUTF8Bytes)-byte work limit."
            )
        }
        guard hasReadAccess else {
            return ToolResponse(
                ok: false,
                source: "Photos",
                message: "Photos access is not authorized. Grant it in System Settings, or explicitly enable and call permissions_request."
            )
        }

        let query = StringSanitizer.lower(rawQuery)
        let limit = max(1, min(input.int("limit", default: 50), 200))
        let page = albumCollections(
            limit: limit,
            query: query,
            maxCandidates: Self.maximumAlbumCandidates
        )
        let items = page.collections.map { collection in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            return Self.makeAlbumItem(
                identifier: collection.localIdentifier,
                title: collection.localizedTitle ?? "(unnamed album)",
                count: assets.count,
                collectionType: collectionType(collection.assetCollectionType)
            )
        }

        let truncated = page.scopeCapped || page.searchContentCapped
        return ToolResponse(
            ok: true,
            source: "Photos",
            items: items,
            message: page.budgetCapped
                ? "Photos album listing reached its \(Self.maximumAlbumCandidates)-album inspection budget."
                : (page.outputLimitCapped
                    ? "More albums may match; increase limit."
                    : (page.searchContentCapped
                        ? "Some album titles exceeded the per-field search budget."
                        : nil)),
            meta: [
                "returned": String(items.count),
                "inspected": String(page.inspected),
                "framework_available": String(page.available),
                "scan_budget": String(Self.maximumAlbumCandidates),
                "scan_capped": String(page.budgetCapped),
                "output_limit_capped": String(page.outputLimitCapped),
                "search_content_capped": String(page.searchContentCapped),
                "has_more": String(page.scopeCapped),
                "truncated": String(truncated)
            ]
        )
    }

    private func matchingAssets(query: String, limit: Int, maxCandidates: Int) -> AssetPage {
        var results: [PHAsset] = []
        var seen = Set<String>()
        var inspected = 0
        var budgetCapped = false
        var outputLimitCapped = false
        var albumScopeCapped = false
        var searchContentCapped = false

        if !query.isEmpty {
            let albums = albumCollections(
                limit: 20,
                query: query,
                maxCandidates: Self.maximumAlbumCandidates
            )
            albumScopeCapped = albums.scopeCapped
            searchContentCapped = albums.searchContentCapped
            for collection in albums.collections {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = max(1, maxCandidates - inspected)
                let assets = PHAsset.fetchAssets(in: collection, options: options)
                let stop = append(
                    assets: assets,
                    to: &results,
                    seen: &seen,
                    query: "",
                    limit: limit,
                    maxCandidates: maxCandidates,
                    inspected: &inspected,
                    searchContentCapped: &searchContentCapped
                )
                budgetCapped = budgetCapped || stop.budgetCapped
                outputLimitCapped = outputLimitCapped || stop.outputLimitCapped
                if results.count >= limit {
                    // A later album or the global library scope remains uninspected.
                    outputLimitCapped = true
                    return AssetPage(
                        assets: results,
                        inspected: inspected,
                        budgetCapped: budgetCapped,
                        outputLimitCapped: outputLimitCapped,
                        albumScopeCapped: albumScopeCapped,
                        searchContentCapped: searchContentCapped
                    )
                }
                if inspected >= maxCandidates {
                    budgetCapped = true
                    return AssetPage(
                        assets: results,
                        inspected: inspected,
                        budgetCapped: budgetCapped,
                        outputLimitCapped: outputLimitCapped,
                        albumScopeCapped: albumScopeCapped,
                        searchContentCapped: searchContentCapped
                    )
                }
            }
        }

        guard inspected < maxCandidates else {
            return AssetPage(
                assets: results,
                inspected: inspected,
                budgetCapped: true,
                outputLimitCapped: outputLimitCapped,
                albumScopeCapped: albumScopeCapped,
                searchContentCapped: searchContentCapped
            )
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = maxCandidates - inspected
        let assets = PHAsset.fetchAssets(with: options)
        let stop = append(
            assets: assets,
            to: &results,
            seen: &seen,
            query: query,
            limit: limit,
            maxCandidates: maxCandidates,
            inspected: &inspected,
            searchContentCapped: &searchContentCapped
        )
        budgetCapped = budgetCapped || stop.budgetCapped
        outputLimitCapped = outputLimitCapped || stop.outputLimitCapped
        // PhotoKit's fetchLimit does not expose whether the library had one more object. Treat an
        // exactly exhausted caller budget/output limit conservatively as a disclosed partial page.
        budgetCapped = budgetCapped || inspected >= maxCandidates
        outputLimitCapped = outputLimitCapped || results.count >= limit
        return AssetPage(
            assets: results,
            inspected: inspected,
            budgetCapped: budgetCapped,
            outputLimitCapped: outputLimitCapped,
            albumScopeCapped: albumScopeCapped,
            searchContentCapped: searchContentCapped
        )
    }

    private struct AppendStop {
        let budgetCapped: Bool
        let outputLimitCapped: Bool
    }

    private func append(
        assets: PHFetchResult<PHAsset>,
        to results: inout [PHAsset],
        seen: inout Set<String>,
        query: String,
        limit: Int,
        maxCandidates: Int,
        inspected: inout Int,
        searchContentCapped: inout Bool
    ) -> AppendStop {
        var index = 0
        while index < assets.count {
            if results.count >= limit {
                return AppendStop(budgetCapped: false, outputLimitCapped: true)
            }
            if inspected >= maxCandidates {
                return AppendStop(budgetCapped: true, outputLimitCapped: false)
            }

            let asset = assets.object(at: index)
            inspected += 1
            index += 1
            guard !seen.contains(asset.localIdentifier) else {
                continue
            }

            let match = assetMatches(asset, query: query)
            searchContentCapped = searchContentCapped || match.contentCapped
            if query.isEmpty || match.matches {
                seen.insert(asset.localIdentifier)
                results.append(asset)
            }
        }
        return AppendStop(budgetCapped: false, outputLimitCapped: false)
    }

    private func albumCollections(limit: Int, query: String, maxCandidates: Int) -> AlbumPage {
        var collections: [PHAssetCollection] = []
        var inspected = 0
        var searchContentCapped = false
        let options = PHFetchOptions()
        let fetches = [
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options),
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: options)
        ]
        let available = fetches.reduce(into: 0) { total, fetch in
            let addition = total.addingReportingOverflow(fetch.count)
            total = addition.overflow ? Int.max : addition.partialValue
        }

        for fetch in fetches {
            var index = 0
            while index < fetch.count, inspected < maxCandidates, collections.count < limit {
                let collection = fetch.object(at: index)
                index += 1
                inspected += 1
                let title = collection.localizedTitle ?? ""
                let boundedTitle = ProviderOutputBudget.text(
                    title,
                    maximumUTF8Bytes: Self.maximumSearchFieldUTF8Bytes
                )
                searchContentCapped = searchContentCapped || boundedTitle.truncated
                if query.isEmpty || boundedTitle.text.localizedLowercase.contains(query) {
                    collections.append(collection)
                }
            }
        }

        return AlbumPage(
            collections: collections,
            inspected: inspected,
            available: available,
            budgetCapped: inspected >= maxCandidates && inspected < available,
            outputLimitCapped: collections.count >= limit && inspected < available,
            searchContentCapped: searchContentCapped
        )
    }

    private func assetMatches(_ asset: PHAsset, query: String) -> (matches: Bool, contentCapped: Bool) {
        guard !query.isEmpty else { return (true, false) }
        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first?.originalFilename ?? ""
        let boundedFilename = ProviderOutputBudget.text(
            filename,
            maximumUTF8Bytes: Self.maximumSearchFieldUTF8Bytes
        )
        let mediaSubtype = mediaSubtypes(asset.mediaSubtypes)
        let haystack = [
            boundedFilename.text,
            mediaType(asset.mediaType),
            mediaSubtype
        ]
        .joined(separator: " ")
        .localizedLowercase
        return (haystack.contains(query), boundedFilename.truncated)
    }

    private func makeItem(asset: PHAsset) -> DataItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first?.originalFilename ?? "(photo)"
        var metadata: [String: String] = [
            "media_type": mediaType(asset.mediaType),
            "media_subtypes": mediaSubtypes(asset.mediaSubtypes),
            "pixel_width": String(asset.pixelWidth),
            "pixel_height": String(asset.pixelHeight),
            "duration": String(asset.duration)
        ]

        let formatter = ISO8601DateFormatter()
        if let created = asset.creationDate {
            metadata["created"] = formatter.string(from: created)
        }
        if let modified = asset.modificationDate {
            metadata["modified"] = formatter.string(from: modified)
        }

        return Self.makePhotoItem(
            identifier: asset.localIdentifier,
            filename: filename,
            preview: "\(mediaType(asset.mediaType)) \(asset.pixelWidth)x\(asset.pixelHeight)",
            metadata: metadata
        )
    }

    static func makePhotoItem(
        identifier: String,
        filename: String,
        preview: String,
        metadata: [String: String]
    ) -> DataItem {
        let boundedIdentifier = ProviderOutputBudget.text(
            identifier,
            maximumUTF8Bytes: maximumIdentifierUTF8Bytes
        )
        let boundedFilename = ProviderOutputBudget.text(
            filename,
            maximumUTF8Bytes: maximumTitleUTF8Bytes
        )
        var boundedMetadata = metadata
        boundedMetadata["local_identifier"] = boundedIdentifier.text
        boundedMetadata["content_truncated"] = String(
            boundedIdentifier.truncated || boundedFilename.truncated
        )
        return DataItem(
            id: boundedIdentifier.text,
            title: boundedFilename.text.isEmpty ? "(photo)" : boundedFilename.text,
            kind: "photo",
            source: "Photos",
            preview: preview,
            metadata: boundedMetadata
        )
    }

    static func makeAlbumItem(
        identifier: String,
        title: String,
        count: Int,
        collectionType: String
    ) -> DataItem {
        let boundedIdentifier = ProviderOutputBudget.text(
            identifier,
            maximumUTF8Bytes: maximumIdentifierUTF8Bytes
        )
        let boundedTitle = ProviderOutputBudget.text(
            title,
            maximumUTF8Bytes: maximumTitleUTF8Bytes
        )
        return DataItem(
            id: boundedIdentifier.text,
            title: boundedTitle.text.isEmpty ? "(unnamed album)" : boundedTitle.text,
            kind: "photos_album",
            source: "Photos",
            metadata: [
                "count": String(count),
                "collection_type": collectionType,
                "content_truncated": String(boundedIdentifier.truncated || boundedTitle.truncated)
            ]
        )
    }

    private var hasReadAccess: Bool {
        // PhotoKit exposes only `.readWrite` for reading the existing library (`.addOnly` cannot
        // fetch assets). The provider itself contains no mutation API.
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
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
