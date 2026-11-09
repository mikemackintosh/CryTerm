//
//  NerdFontInstaller.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/15/23.
//
//  Installs the Nerd Font Bundle: the special-exceptions table bundled with
//  the app (nerd.itse), which maps Nerd Font symbol ranges to their fonts.
//  This build never downloads the fonts themselves; if any are missing, it
//  names them so you can install them yourself, and changes nothing.
//

import Foundation
import CoreText

enum NerdFontInstallerError: LocalizedError {
    case missingFonts([String])

    var errorDescription: String? {
        switch self {
        case .missingFonts(let names):
            let list = names.joined(separator: ", ")
            return String(localized: "NerdFontInstaller.MissingFontsNoDownload",
                          defaultValue: "The Nerd Font Bundle needs these fonts, which aren’t installed: \(list). Install them yourself, then try again. CryTerm doesn’t download fonts.",
                          comment: "Error shown when fonts the Nerd Font Bundle needs are missing; the placeholder is a comma-separated list of font names")
        }
    }
}

class NerdFontInstaller {
    static var configString: String {
        let path = Bundle(for: SpecialExceptionsWindowController.self).path(forResource: "nerd", ofType: "itse")!
        return try! String(contentsOf: URL.init(fileURLWithPath: path))
    }

    static var config: FontTable.Config = {
        FontTable.Config(string: configString)!
    }()

    // PostScript names of the bundle's fonts that aren't installed.
    static var neededFontPostscriptNames: [String] {
        let needed = config.entries.compactMap { entry in
            let needFont = NSFont(name: entry.fontName, size: 10) == nil
            return needFont ? entry.fontName : nil
        }
        return Array(Set(needed)).sorted()
    }

    // Completes with nil when every font is installed, so the caller can
    // import configString; otherwise with .missingFonts.
    static func start(window: NSWindow?, completion: @escaping (NerdFontInstallerError?) -> ()) {
        let needed = neededFontPostscriptNames
        if needed.isEmpty {
            completion(nil)
        } else {
            RLog("Nerd Font Bundle needs fonts that aren't installed: \(needed)")
            completion(.missingFonts(needed))
        }
    }
}

extension Array {
    var cfArray: CFArray {
        let count = self.count
        let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        pointer.initialize(repeating: nil, count: count)

        for (index, element) in self.enumerated() {
            pointer[index] = UnsafeRawPointer(Unmanaged.passRetained(element as AnyObject).toOpaque())
        }

        var callbacks = kCFTypeArrayCallBacks
        callbacks.retain = { source, pointer in
            return UnsafeRawPointer(Unmanaged<AnyObject>.fromOpaque(pointer!).retain().toOpaque())
        }

        callbacks.release = { source, pointer in
            Unmanaged<AnyObject>.fromOpaque(pointer!).release()
        }

        let cfArray = CFArrayCreate(kCFAllocatorDefault, pointer, count, &callbacks)
        pointer.deallocate()

        return cfArray!
    }
}

extension Array {
    init(_ cfArray: CFArray) {
        self.init()

        let count = CFArrayGetCount(cfArray)
        for index in 0..<count {
            if let value = CFArrayGetValueAtIndex(cfArray, index) {
                append(unsafeBitCast(value, to: Element.self))
            }
        }
    }
}

extension FileManager {
    func flatMapRegularFiles<T>(in folder: String, closure: (URL) throws -> ([T])) rethrows -> [T] {
        var result = [T]()
        try enumerateRegularFiles(in: folder) {
            let value = try closure($0)
            result.append(contentsOf: value)
        }
        return result
    }

    func enumerateRegularFiles(in folder: String, closure: (URL) throws -> ()) rethrows {
        let directoryContents = try? contentsOfDirectory(atPath: folder)
        for itemName in directoryContents ?? [] {
            if itemName.hasPrefix(".") {
                continue
            }

            var isDirectory: ObjCBool = false
            let itemURL = URL(fileURLWithPath: folder).appendingPathComponent(itemName)
            guard fileExists(atPath: itemURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue else {
                continue
            }
            try closure(itemURL)
        }
    }
}

extension CTFontDescriptor {
    var postscriptName: String? {
        let fontFamilyNameKey = kCTFontNameAttribute as String
        return CTFontDescriptorCopyAttribute(self, fontFamilyNameKey as CFString) as? String
    }
}
