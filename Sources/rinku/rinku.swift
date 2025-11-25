/*
 * This file is part of rinku.
 *
 * Copyright (C) 2025 Álvaro Ramírez https://xenodium.com
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import CryptoKit
import Foundation
import LinkPresentation
import SwiftUI

@main
struct LinkPreviewRenderer {
  static func main() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var cacheEnabled = true
    var renderEnabled = true

    if let index = arguments.firstIndex(of: "--no-cache") {
      cacheEnabled = false
      arguments.remove(at: index)
    }

    if let index = arguments.firstIndex(of: "--render") {
      renderEnabled = true
      arguments.remove(at: index)
    } else {
      renderEnabled = false
    }

    guard !arguments.isEmpty else {
      print("Usage: \(CommandLine.arguments[0]) [--no-cache] [--render] <URL>")
      exit(1)
    }

    guard let url = URL(string: arguments[0]) else {
      print("\(Response.failure(error: "Invalid URL").output())")
      exit(1)
    }

    Task { @MainActor in
      await processLinkPreview(url: url, cacheEnabled: cacheEnabled, renderEnabled: renderEnabled)
    }

    RunLoop.current.run()
  }

  @MainActor
  static func processLinkPreview(url: URL, cacheEnabled: Bool, renderEnabled: Bool) async {
    if renderEnabled {
      let cacheURL = cacheURL(prefix: "render-", for: url)

      // Check if cached version exists
      if cacheEnabled && FileManager.default.fileExists(atPath: cacheURL.path) {
        Response.success(preview: cacheURL.path).output()
        exit(0)
      }

      do {
        let metadata = try await fetchMetadataWithCache(for: url, cacheEnabled: cacheEnabled)
        try await renderAndSave(metadata: metadata, to: cacheURL)
        Response.success(preview: cacheURL.path).output()
        exit(0)
      } catch {
        Response.failure(error: error.localizedDescription).output()
        exit(1)
      }
    } else {
      do {
        let metadata = try await fetchMetadataWithCache(for: url, cacheEnabled: cacheEnabled)
        let metadataResponse = try await createMetadataResponse(
          metadata: metadata, url: url, cacheEnabled: cacheEnabled)
        metadataResponse.output()
        exit(0)
      } catch {
        Response.failure(error: error.localizedDescription).output()
        exit(1)
      }
    }
  }

  static func createMetadataResponse(metadata: LPLinkMetadata, url: URL, cacheEnabled: Bool)
    async throws -> Response
  {
    var imagePath: String?

    if let imageProvider = metadata.imageProvider {
      let imageCacheURL = cacheURL(prefix: "image-", for: url)

      if cacheEnabled && FileManager.default.fileExists(atPath: imageCacheURL.path) {
        imagePath = imageCacheURL.path
      } else {
        do {
          let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSImage?, Error>) in
            imageProvider.loadObject(ofClass: NSImage.self) { (object, error) in
              if let error = error {
                continuation.resume(throwing: error)
              } else {
                continuation.resume(returning: object as? NSImage)
              }
            }
          }

          if let image = image,
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
          {
            try pngData.write(to: imageCacheURL)
            imagePath = imageCacheURL.path
          }
        } catch {
          // Ignore image fetch errors, continue without image
        }
      }
    }

    return Response.metadata(
      title: metadata.title,
      url: metadata.url?.absoluteString ?? url.absoluteString,
      image: imagePath
    )
  }

  static func fetchMetadataWithCache(for url: URL, cacheEnabled: Bool) async throws
    -> LPLinkMetadata
  {
    let metadataCacheURL = cacheURL(prefix: "metadata-", for: url, extension: "plist")

    // Try to load from cache first
    if cacheEnabled && FileManager.default.fileExists(atPath: metadataCacheURL.path) {
      if let data = try? Data(contentsOf: metadataCacheURL),
        let metadata = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: LPLinkMetadata.self, from: data)
      {
        return metadata
      }
    }

    // Suppress framework warnings
    let originalStderr = dup(STDERR_FILENO)
    let devNull = open("/dev/null", O_WRONLY)
    dup2(devNull, STDERR_FILENO)
    close(devNull)

    defer {
      // Restore stderr
      dup2(originalStderr, STDERR_FILENO)
      close(originalStderr)
    }

    // Fetch fresh metadata
    let provider = LPMetadataProvider()
    let metadata = try await provider.startFetchingMetadata(for: url)

    // Cache the metadata
    if cacheEnabled,
      let data = try? NSKeyedArchiver.archivedData(
        withRootObject: metadata, requiringSecureCoding: true)
    {
      try? data.write(to: metadataCacheURL)
    }

    return metadata
  }

  @MainActor
  static func renderAndSave(metadata: LPLinkMetadata, to cacheURL: URL) async throws {
    let linkView = LPLinkView(metadata: metadata)
    let size = CGRect(x: 0, y: 0, width: 300, height: 150)
    linkView.frame = size

    // Create a window to host the view
    let window = NSWindow(
      contentRect: size,
      styleMask: [],
      backing: .buffered,
      defer: false
    )
    window.contentView = linkView
    window.orderBack(nil)

    // Wait a moment for rendering
    try await Task.sleep(nanoseconds: 500_000_000)

    let imageRep = linkView.bitmapImageRepForCachingDisplay(in: linkView.bounds)
    guard let bitmap = imageRep else {
      throw RenderError.captureViewFailed
    }
    linkView.cacheDisplay(in: linkView.bounds, to: bitmap)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw RenderError.pngDataCreationFailed
    }

    try data.write(to: cacheURL)
  }

  static func cacheURL(prefix: String, for url: URL, extension: String = "png") -> URL {
    let hash = SHA256.hash(data: url.absoluteString.data(using: .utf8)!)
    let hashString = prefix + hash.compactMap { String(format: "%02x", $0) }.joined()

    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("link-previews")

    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    return cacheDir.appendingPathComponent("\(hashString).\(`extension`)")
  }
}

enum RenderError: Error, LocalizedError {
  case captureViewFailed
  case pngDataCreationFailed

  var errorDescription: String? {
    switch self {
    case .captureViewFailed: return "Failed to capture view"
    case .pngDataCreationFailed: return "Failed to create PNG data"
    }
  }
}

struct Response: Codable {
  let preview: String?
  let error: String?
  let title: String?
  let url: String?
  let image: String?

  static func success(preview: String) -> Response {
    Response(preview: preview, error: nil, title: nil, url: nil, image: nil)
  }

  static func failure(error: String) -> Response {
    Response(preview: nil, error: error, title: nil, url: nil, image: nil)
  }

  static func metadata(title: String?, url: String, image: String?) -> Response {
    Response(preview: nil, error: nil, title: title, url: url, image: image)
  }

  func output() {
    let data = try! JSONEncoder().encode(self)
    print(String(data: data, encoding: .utf8)!)
  }
}
