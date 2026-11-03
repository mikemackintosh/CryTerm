//
//  MainMenuAIItemRemovalTests.swift
//  ModernTests
//
//  This build never connects to AI services, so MainMenuMangler removes the
//  menu items that only reach AI features. Removal must reach submenus and
//  must not leave doubled, leading, or trailing separators behind.
//

import XCTest
@testable import iTerm2SharedARC

final class MainMenuAIItemRemovalTests: XCTestCase {
    private func item(_ title: String, identifier: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let identifier {
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return item
    }

    private func titles(_ menu: NSMenu) -> [String] {
        return menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    func testRemovesMatchingItemsInSubmenus() {
        let root = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy"))
        edit.addItem(item("Engage AI", identifier: "Engage Artificial Intelligence"))
        edit.addItem(item("Paste"))
        let editItem = item("Edit")
        editItem.submenu = edit
        root.addItem(editItem)

        MainMenuMangler.removeItems(withIdentifiers: MainMenuMangler.aiMenuItemIdentifiers, from: root)

        XCTAssertEqual(titles(edit), ["Copy", "Paste"])
    }

    func testCleansUpSeparatorsLeftBehind() {
        let menu = NSMenu()
        menu.addItem(item("AI Chats", identifier: "AI Chats"))
        menu.addItem(.separator())
        menu.addItem(item("Minimize"))
        menu.addItem(.separator())
        menu.addItem(item("Open AI Chat", identifier: "Open AI Chat"))
        menu.addItem(.separator())
        menu.addItem(item("Zoom"))
        menu.addItem(.separator())
        menu.addItem(item("Explain", identifier: "Explain Output with AI"))

        MainMenuMangler.removeItems(withIdentifiers: MainMenuMangler.aiMenuItemIdentifiers, from: menu)

        XCTAssertEqual(titles(menu), ["Minimize", "---", "Zoom"])
    }

    func testLeavesMenusWithoutAIItemsAlone() {
        let menu = NSMenu()
        menu.addItem(.separator())
        menu.addItem(item("Close"))
        menu.addItem(.separator())

        MainMenuMangler.removeItems(withIdentifiers: MainMenuMangler.aiMenuItemIdentifiers, from: menu)

        XCTAssertEqual(titles(menu), ["---", "Close", "---"])
    }

    // Every identifier must exist in MainMenu.xib, or the removal silently
    // misses an item after a rename.
    func testEveryIdentifierIsInTheMainMenu() throws {
        let nib = try XCTUnwrap(NSNib(nibNamed: "MainMenu", bundle: Bundle(for: MainMenuMangler.self)))
        var objects: NSArray?
        XCTAssertTrue(nib.instantiate(withOwner: nil, topLevelObjects: &objects))
        let menu = try XCTUnwrap(objects?.compactMap { $0 as? NSMenu }.first { $0.items.count > 3 })
        var found = Set<String>()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let identifier = item.identifier?.rawValue {
                    found.insert(identifier)
                }
                if let submenu = item.submenu {
                    walk(submenu)
                }
            }
        }
        walk(menu)
        XCTAssertEqual(MainMenuMangler.aiMenuItemIdentifiers.subtracting(found), [])
    }
}
