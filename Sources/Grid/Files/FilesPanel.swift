import SwiftUI

/// Full-width Files workspace: browser + optional inspector.
struct FilesPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            FileBrowserView(compact: false)
            if app.inspectorVisible {
                ResizeHandle(width: Binding(get: { app.layout.inspectorWidth }, set: { app.layout.inspectorWidth = $0 }),
                             range: 220...520, defaultValue: 290, edge: .trailing)
                InspectorView().frame(width: app.layout.inspectorWidth)
            }
        }
    }
}
