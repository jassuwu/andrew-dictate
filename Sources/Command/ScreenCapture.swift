import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    case noCaptureTarget
    case captureFailed
    case emptyCapture
    case unableToEncode
    case unableToWrite
}

struct EphemeralScreenCapture: Equatable, Sendable {
    let url: URL

    static func create(
        pngData: Data,
        temporaryDirectory: URL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) throws -> Self {
        let url = temporaryDirectory.appendingPathComponent(
            "andrew-dictate-screen-\(UUID().uuidString).png",
            isDirectory: false
        )
        let permissions = NSNumber(value: 0o600)
        guard fileManager.createFile(
            atPath: url.path,
            contents: pngData,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw ScreenCaptureError.unableToWrite
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
            let attributes = try fileManager.attributesOfItem(
                atPath: url.path
            )
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue
                    == 0o600 else {
                try? fileManager.removeItem(at: url)
                throw ScreenCaptureError.unableToWrite
            }
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            try? fileManager.removeItem(at: url)
            throw ScreenCaptureError.unableToWrite
        }

        return Self(url: url)
    }

    func delete(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}

@MainActor
final class ScreenCapture {
    static let screenRecordingSettingsURL = URL(
        string:
            "x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_ScreenCapture"
    )!

    private var didRequestPermission = false
    private var captureGeneration: UInt64 = 0

    func cancelPendingCapture() {
        captureGeneration &+= 1
    }

    func capture(
        scope: ScreenAskScope
    ) async throws -> EphemeralScreenCapture {
        let generation = captureGeneration
        try Task.checkCancellation()
        try ensurePermission()
        try Task.checkCancellation()
        guard generation == captureGeneration else {
            throw CancellationError()
        }

        // Give Esc and a new hotkey event a main-run-loop cancellation point
        // before asking ScreenCaptureKit for shareable content.
        await Task.yield()
        try Task.checkCancellation()
        guard generation == captureGeneration else {
            throw CancellationError()
        }

        let image: CGImage
        do {
            switch scope {
            case .activeDisplay:
                image = try await captureActiveDisplay()
            case .frontWindow:
                image = try await captureFrontWindow()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            throw ScreenCaptureError.captureFailed
        }

        try Task.checkCancellation()
        guard generation == captureGeneration else {
            throw CancellationError()
        }
        guard image.width > 0,
              image.height > 0,
              containsVisiblePixels(image) else {
            throw ScreenCaptureError.emptyCapture
        }

        guard let pngData = NSBitmapImageRep(cgImage: image).representation(
            using: .png,
            properties: [:]
        ) else {
            throw ScreenCaptureError.unableToEncode
        }

        try Task.checkCancellation()
        guard generation == captureGeneration else {
            throw CancellationError()
        }

        let capture = try EphemeralScreenCapture.create(pngData: pngData)
        do {
            try Task.checkCancellation()
            guard generation == captureGeneration else {
                throw CancellationError()
            }
            return capture
        } catch {
            capture.delete()
            throw error
        }
    }

    private func ensurePermission() throws {
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }

        guard !didRequestPermission else {
            throw ScreenCaptureError.permissionDenied
        }
        didRequestPermission = true

        guard CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }
    }

    private func captureActiveDisplay() async throws -> CGImage {
        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(pointerLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let screen,
              let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw ScreenCaptureError.noCaptureTarget
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let display = content.displays.first(where: {
            $0.displayID == displayID
        }) else {
            throw ScreenCaptureError.noCaptureTarget
        }

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(
                display: display,
                excludingWindows: []
            ),
            configuration: configuration
        )
    }

    private func captureFrontWindow() async throws -> CGImage {
        guard let processIdentifier = NSWorkspace.shared
            .frontmostApplication?
            .processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]],
              let window = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == processIdentifier
                    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue
                    == 0
              }),
              let boundsDictionary = window[
                kCGWindowBounds as String
              ] as? NSDictionary,
              let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary
              ),
              !bounds.isEmpty,
              let windowNumber = window[
                kCGWindowNumber as String
              ] as? NSNumber else {
            throw ScreenCaptureError.noCaptureTarget
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let windowID = CGWindowID(windowNumber.uint32Value)
        guard let shareableWindow = content.windows.first(where: {
            $0.windowID == windowID
        }) else {
            throw ScreenCaptureError.noCaptureTarget
        }

        let windowDisplay = content.displays.max {
            intersectionArea($0.frame, bounds)
                < intersectionArea($1.frame, bounds)
        }
        let scale = windowDisplay.map {
            CGFloat($0.width) / max(1, $0.frame.width)
        } ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(bounds.width * scale))
        configuration.height = max(1, Int(bounds.height * scale))
        configuration.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(
                desktopIndependentWindow: shareableWindow
            ),
            configuration: configuration
        )
    }

    private func intersectionArea(
        _ first: CGRect,
        _ second: CGRect
    ) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func containsVisiblePixels(_ image: CGImage) -> Bool {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: height * bytesPerRow
        )

        let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard didDraw else {
            return false
        }

        return stride(
            from: 0,
            to: pixels.count,
            by: bytesPerPixel
        ).contains {
            pixels[$0] > 2
                || pixels[$0 + 1] > 2
                || pixels[$0 + 2] > 2
        }
    }
}
