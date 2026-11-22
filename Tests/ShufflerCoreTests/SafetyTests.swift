import Foundation
import Testing

/// Guards the brief's safety rules at the source level: the tool may only add or
/// remove photos in its own album, and create that album once. Any PhotoKit API
/// that deletes or edits assets, or deletes/edits other collections, fails this test.
@Suite struct SafetyTests {
    static let forbidden = [
        "deleteAssets",
        "deleteAssetCollections",
        "deleteCollectionLists",
        "PHAssetChangeRequest",
        "PHAssetCreationRequest",
        "PHCollectionListChangeRequest",
        "PHContentEditingOutput",
        "isFavorite",
        ".replaceAssets(",
        ".moveAssets(",
        ".insertAssets(",
        ".title = ",          // renaming a collection
    ]

    @Test func sourcesUseOnlyAlbumAddRemove() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for api in Self.forbidden {
                #expect(!code.contains(api), "\(file.lastPathComponent) uses forbidden API \(api)")
            }
        }
    }

    @Test func photoKitIsConfinedToOneFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        for file in files where file.lastPathComponent != "PhotoLibrary.swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
            #expect(!code.contains("performChanges"), "\(file.lastPathComponent) writes to Photos outside PhotoLibrary.swift")
        }
    }
}
