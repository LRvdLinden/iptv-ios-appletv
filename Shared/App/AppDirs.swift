import Foundation

/// Build 144: mappen zonder `urls(...)[0]` (een lege lijst gaf een crash) en met een terugval naar tmp. Op Apple TV zijn
/// alleen Caches en tmp betrouwbaar schrijfbaar; Application Support kan daar ontbreken of niet schrijfbaar zijn (dan Caches).
enum AppDirs {
    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// Application Support (zoals tot nu toe, ook op Apple TV), anders Caches
    static var support: URL {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return caches }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return caches }
        return dir
    }
}
