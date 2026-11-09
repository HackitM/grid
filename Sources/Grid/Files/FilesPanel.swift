import SwiftUI

/// Full-width Files workspace: browser + optional inspector.
struct FilesPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            FileBrowserView(compact: false)
            if app.inspectorVisible {
                InspectorView().frame(width: 290)
            }
        }
    }
}
