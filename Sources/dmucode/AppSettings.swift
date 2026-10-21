import Combine
import dmucodeCore

/// dmucode's config as the window and the views see it; replaced whenever
/// the file is reloaded, so SwiftUI views observing it redraw.
final class AppSettings: ObservableObject {
    @Published var config = AppConfig()
}
