//
//  Adobe-Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import SwiftUI

struct LanguagePickerView: View {
    let languages: [(code: String, name: String)]
    let onLanguageSelected: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultLanguage") private var defaultLanguage: String = "zh_CN"
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择安装语言")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(languages, id: \.code) { language in
                        Button(action: {
                            defaultLanguage = language.code
                            onLanguageSelected(language.code)
                            dismiss()
                        }) {
                            HStack {
                                Text(language.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                if defaultLanguage == language.code {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(defaultLanguage == language.code ? Color.blue.opacity(0.1) : Color.clear)
                        )
                    }
                }
                .padding()
            }
        }
        .frame(width: 300, height: 400)
    }
}

#Preview {
    LanguagePickerView(
        languages: AppStatics.supportedLanguages,
        onLanguageSelected: { _ in }
    )
}