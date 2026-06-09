public enum BuiltInCompressionProfiles {
    public static let fastZIP = CompressionProfile(
        id: "fast-zip",
        name: "Fast ZIP",
        format: .zip,
        level: .fastest,
        ignoreRules: IgnoreRule.defaultMacOSRules
    )

    public static let standard7z = CompressionProfile(
        id: "standard-7z",
        name: "Standard 7z",
        format: .sevenZip,
        level: .normal,
        method: "lzma2",
        solid: true,
        ignoreRules: IgnoreRule.defaultMacOSRules
    )

    public static let ultra7z = CompressionProfile(
        id: "ultra-7z",
        name: "Ultra 7z",
        format: .sevenZip,
        level: .ultra,
        method: "lzma2",
        solid: true,
        dictionarySize: 256 * 1024 * 1024,
        ignoreRules: IgnoreRule.defaultMacOSRules
    )

    public static let encrypted7z = CompressionProfile(
        id: "encrypted-7z",
        name: "Encrypted 7z",
        format: .sevenZip,
        level: .normal,
        method: "lzma2",
        solid: true,
        encryptFileNames: true,
        ignoreRules: IgnoreRule.defaultMacOSRules
    )

    public static let split100MB7z = CompressionProfile(
        id: "split-100mb-7z",
        name: "Split 100MB 7z",
        format: .sevenZip,
        level: .normal,
        method: "lzma2",
        solid: true,
        volumeSize: 100 * 1024 * 1024,
        ignoreRules: IgnoreRule.defaultMacOSRules
    )

    public static let windowsCompatibleZIP = CompressionProfile(
        id: "windows-compatible-zip",
        name: "Windows-compatible ZIP",
        format: .zip,
        level: .normal,
        method: "deflate",
        ignoreRules: IgnoreRule.defaultMacOSRules,
        filenameEncoding: .utf8
    )

    public static let all: [CompressionProfile] = [
        fastZIP,
        standard7z,
        ultra7z,
        encrypted7z,
        split100MB7z,
        windowsCompatibleZIP
    ]
}
