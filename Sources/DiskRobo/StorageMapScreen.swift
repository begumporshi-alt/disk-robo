import SwiftUI
import RoboCore

/// Storage Map screen — full-size version of the dashboard map card
/// (interactive sunburst, hover tooltips, breadcrumb drill-down).
struct StorageMapScreen: View {
    var body: some View {
        StorageMapCard()
            .padding(20)
            .navigationTitle("Storage Map")
    }
}
