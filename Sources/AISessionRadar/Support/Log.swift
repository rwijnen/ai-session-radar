import Foundation
import OSLog

/// `log stream --predicate 'subsystem == "com.robinwijnen.AISessionRadar"'` shows what the app decides.
enum Log {
    static let app = Logger(subsystem: "com.robinwijnen.AISessionRadar", category: "app")
}
