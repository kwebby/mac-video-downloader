import SwiftUI

// Explicitly select the property wrapper on SDKs that also export a State macro.
// This keeps the macOS 14 app buildable with the Command Line Tools SDK.
typealias ViewState<Value> = State<Value>
