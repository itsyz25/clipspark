import SwiftUI

/// Templates tab: bundled offline recipes. Tapping one → pick clips → editor
/// pre-built with the recipe's speed/transition/title.
struct TemplatesView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: CSSpacing.m)], spacing: CSSpacing.m) {
                    ForEach(ClipTemplate.catalog) { template in
                        TemplateCard(template: template) {
                            app.startProject(template: template)
                        }
                    }
                }
                .padding(CSSpacing.l)

                Text("All templates are stored on-device — they work without a connection.")
                    .font(CSType.timecode)
                    .foregroundStyle(CSTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(CSSpacing.l)
            }
            .background(CSTheme.bg.ignoresSafeArea())
            .navigationTitle("Templates")
            .sheet(isPresented: $app.showPicker) {
                MediaPickerView { app.picked($0) }
            }
            .fullScreenCover(item: Binding(
                get: { app.editorPayload },
                set: { app.editorPayload = $0 }
            )) { payload in
                EditorView(assets: payload.assets, template: payload.template)
            }
        }
    }
}
