//
//  verticalizeApp.swift
//  verticalize
//

import SwiftUI

@main
struct verticalizeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
