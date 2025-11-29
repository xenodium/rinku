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
    var renderEnabled = false
    var renderWidth: CGFloat?
    var renderHeight: CGFloat?

    let validFlags = ["--no-cache", "--preview", "--width", "--height"]

    if let index = arguments.firstIndex(of: "--no-cache") {
      cacheEnabled = false
      arguments.remove(at: index)
    }

    if let index = arguments.firstIndex(of: "--preview") {
      renderEnabled = true
      arguments.remove(at: index)
    }

    if let index = arguments.firstIndex(of: "--width") {
      arguments.remove(at: index)
      if index < arguments.count, let width = Double(arguments[index]) {
        renderWidth = CGFloat(width)
        arguments.remove(at: index)
      }
    }

    if let index = arguments.firstIndex(of: "--height") {
      arguments.remove(at: index)
      if index < arguments.count, let height = Double(arguments[index]) {
        renderHeight = CGFloat(height)
        arguments.remove(at: index)
      }
    }

    // Check for unknown flags
    if let unknownFlag = arguments.first(where: { $0.hasPrefix("--") }) {
      Response.error(
        message:
          "Unknown flag '\(unknownFlag)'. Valid flags are: \(validFlags.joined(separator: ", "))"
      ).output()
      exit(1)
    }

    // Check if --width or --height used without --preview
    if !renderEnabled && (renderWidth != nil || renderHeight != nil) {
      Response.error(message: "The --width and --height flags require --preview to be set.")
        .output()
      exit(1)
    }

    guard !arguments.isEmpty else {
      let programName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
      print(
        "Usage: \(programName) [--no-cache] [--preview] [--width N] [--height N] <URL>"
      )
      exit(1)
    }

    let urlString = arguments[0]

    // Check if user forgot to use -- for flags
    if urlString.hasPrefix("-") && !urlString.hasPrefix("--") {
      Response.error(
        message:
          "Invalid flag '\(urlString)'. Did you mean '--\(urlString.dropFirst())'?"
      ).output()
      exit(1)
    }

    // Automatically prepend https:// if no scheme is present
    var processedURL = urlString
    if !urlString.contains("://") {
      processedURL = "https://\(urlString)"
    }

    guard let url = URL(string: processedURL), url.scheme != nil else {
      Response.error(
        message: "Invalid URL: '\(urlString)'. URL must be a valid URL."
      ).output()
      exit(1)
    }

    Task { @MainActor in
      await processLinkPreview(
        url: url,
        cacheEnabled: cacheEnabled,
        renderEnabled: renderEnabled,
        renderSize: CGSize(width: renderWidth ?? 300, height: renderHeight ?? 150)
      )
    }

    RunLoop.current.run()
  }

  @MainActor
  static func processLinkPreview(
    url: URL,
    cacheEnabled: Bool,
    renderEnabled: Bool,
    renderSize: CGSize
  ) async {
    if renderEnabled {
      do {
        let cacheURL = try cacheURL(prefix: "render-", for: url, size: renderSize)

        // Check if cached version exists
        if cacheEnabled && FileManager.default.fileExists(atPath: cacheURL.path) {
          Response.preview(path: cacheURL.path).output()
          exit(0)
        }

        let metadata = try await fetchMetadataWithCache(for: url, cacheEnabled: cacheEnabled)
        try await renderAndSave(metadata: metadata, to: cacheURL, size: renderSize)
        Response.preview(path: cacheURL.path).output()
        exit(0)
      } catch {
        Response.error(message: error.localizedDescription).output()
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
        Response.error(message: error.localizedDescription).output()
        exit(1)
      }
    }
  }

  static func createMetadataResponse(metadata: LPLinkMetadata, url: URL, cacheEnabled: Bool)
    async throws -> Response
  {
    var imagePath: String?

    if let imageProvider = metadata.imageProvider {
      do {
        let imageCacheURL = try cacheURL(prefix: "image-", for: url)

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
            fputs(
              "Warning: Failed to fetch or cache image: \(error.localizedDescription)\n", stderr)
          }
        }
      } catch {
        fputs("Warning: Failed to create image cache URL: \(error.localizedDescription)\n", stderr)
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
    let metadataCacheURL = try cacheURL(prefix: "metadata-", for: url, extension: "plist")

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
    guard originalStderr != -1 else {
      throw CacheError.stderrRedirectionFailed
    }

    let devNull = open("/dev/null", O_WRONLY)
    guard devNull != -1 else {
      close(originalStderr)
      throw CacheError.stderrRedirectionFailed
    }

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
  static func renderAndSave(
    metadata: LPLinkMetadata,
    to cacheURL: URL,
    size: CGSize
  ) async throws {
    let linkView = LPLinkView(metadata: metadata)
    let rect = CGRect(origin: .zero, size: size)
    linkView.frame = rect

    // Create a window to momentarily host the view
    let window = NSWindow(
      contentRect: rect,
      styleMask: [],
      backing: .buffered,
      defer: false
    )
    window.contentView = linkView
    window.orderBack(nil)

    // Force layout to complete synchronously
    linkView.layoutSubtreeIfNeeded()

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

  static func cacheURL(prefix: String, for url: URL, size: CGSize? = nil, extension: String = "png")
    throws -> URL
  {
    var cacheKey = prefix + url.absoluteString

    if let size = size {
      cacheKey += "-\(Int(size.width))x\(Int(size.height))"
    }

    guard let keyData = cacheKey.data(using: .utf8) else {
      throw CacheError.invalidURLEncoding
    }

    let hash = SHA256.hash(data: keyData)
    let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("link-previews")

    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

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

enum CacheError: Error, LocalizedError {
  case invalidURLEncoding
  case directoryCreationFailed
  case stderrRedirectionFailed

  var errorDescription: String? {
    switch self {
    case .invalidURLEncoding: return "Failed to encode URL as UTF-8"
    case .directoryCreationFailed: return "Failed to create cache directory"
    case .stderrRedirectionFailed: return "Failed to redirect stderr"
    }
  }
}

enum Response {
  case preview(path: String)
  case error(message: String)
  case metadata(title: String?, url: String, image: String?)

  func output() {
    let dict: [String: Any?]

    switch self {
    case .preview(let path):
      dict = ["image": path]
    case .error(let message):
      dict = ["error": message]
    case .metadata(let title, let url, let image):
      dict = ["title": title, "url": url, "image": image]
    }

    // Filter out nil values and encode
    let filteredDict = dict.compactMapValues { $0 }

    do {
      let jsonData = try JSONSerialization.data(withJSONObject: filteredDict, options: [])
      if let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
      } else {
        fputs("Error: Failed to convert JSON data to string\n", stderr)
        exit(1)
      }
    } catch {
      fputs("Error: Failed to encode response as JSON: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
