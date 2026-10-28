import Foundation
import Combine

@MainActor
final class Preferences: ObservableObject {
    @Published var preferredLanguage = UserDefaults.standard.string(forKey: "preferredLanguage") ?? "zh" {
        didSet { UserDefaults.standard.set(preferredLanguage, forKey: "preferredLanguage") }
    }
    @Published var sourceLanguage = UserDefaults.standard.string(forKey: "sourceLanguage") ?? "auto" {
        didSet { UserDefaults.standard.set(sourceLanguage, forKey: "sourceLanguage") }
    }
    @Published var autoReadAloud = UserDefaults.standard.object(forKey: "autoReadAloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReadAloud, forKey: "autoReadAloud") }
    }
    @Published var fontSize = UserDefaults.standard.double(forKey: "fontSize") == 0 ? 25 : UserDefaults.standard.double(forKey: "fontSize") {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var speechRate = UserDefaults.standard.float(forKey: "speechRate") == 0 ? 0.48 : UserDefaults.standard.float(forKey: "speechRate") {
        didSet { UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }
    @Published var processingMode = ProcessingMode(rawValue: UserDefaults.standard.string(forKey: "processingMode") ?? "") ?? .fast {
        didSet { UserDefaults.standard.set(processingMode.rawValue, forKey: "processingMode") }
    }
    @Published var nearField = UserDefaults.standard.bool(forKey: "nearField") {
        didSet { UserDefaults.standard.set(nearField, forKey: "nearField") }
    }
    @Published var saveAutomatically = UserDefaults.standard.bool(forKey: "saveAutomatically") {
        didSet { UserDefaults.standard.set(saveAutomatically, forKey: "saveAutomatically") }
    }
    @Published private(set) var termsError: String?
    @Published var terms: [Term] = [] {
        didSet { persistTerms() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "terms") {
            do { terms = try JSONDecoder().decode([Term].self, from: data) }
            catch { termsError = "术语数据无法读取，原数据已保留。" }
        }
    }

    private func persistTerms() {
        guard termsError == nil else { return }
        guard let data = try? JSONEncoder().encode(terms) else { return }
        UserDefaults.standard.set(data, forKey: "terms")
    }
}
