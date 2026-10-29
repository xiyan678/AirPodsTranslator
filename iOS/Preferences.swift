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
}
