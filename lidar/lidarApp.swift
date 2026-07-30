//
//  lidarApp.swift
//  lidar
//
//  Created by Ted Schultz on 7/30/26.
//

import SwiftUI

@main
struct lidarApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
