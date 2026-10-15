import SwiftUI

@MainActor
struct InformationView: View {
    @ObservedObject var preferences: AppPreferences
    private var bundle: Bundle { .main }

    var body: some View {
        Form {
            Section("应用信息") {
                LabeledContent("应用名称", value: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AutoDarkShift")
                LabeledContent("版本", value: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")
                LabeledContent("Build", value: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")
                LabeledContent("最低系统版本", value: bundle.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "iOS 17")
                LabeledContent("模型版本", value: "MathModel v2")
            }
            Section("开发者") {
                Toggle("开发者模式", isOn: $preferences.developerModeEnabled)
            }
        }
        .navigationTitle("信息")
    }
}
