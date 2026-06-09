import Foundation

/// Entry point required by SwiftPM .executableTarget.
/// Extension lifecycle is managed by the host process via Info.plist NSExtensionPrincipalClass.
@_silgen_name("NSExtensionMain")
private func foundationNSExtensionMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
)

@main
enum _NSExtensionMain {
    static func main() {
        foundationNSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
