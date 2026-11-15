import SwiftUI

extension Binding {
    /// A nil-safe stand-in for SwiftUI's `Binding(_: Binding<Value?>)`.
    ///
    /// SwiftUI's unwrapping initialiser force-unwraps on every read, so if the optional
    /// becomes nil while a view still holds the unwrapped binding (for example removing
    /// the bed in the main window while the Preview window shows its controls), the app
    /// traps inside SwiftUI. This binding reads `fallback` once the value is gone and
    /// ignores writes, so a removed track is never brought back by a late slider update.
    func unwrapped<Wrapped>(fallback: Wrapped) -> Binding<Wrapped> where Value == Wrapped?, Wrapped: Sendable {
        Binding<Wrapped>(
            get: { wrappedValue ?? fallback },
            set: { newValue in
                if wrappedValue != nil { wrappedValue = newValue }
            }
        )
    }
}
