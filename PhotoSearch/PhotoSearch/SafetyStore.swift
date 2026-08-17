import CloudKit
import Foundation

/// Blocking and abuse reporting for the social surfaces (friends, shared
/// albums, photo requests) — App Store Guideline 1.2 requires both for any app
/// carrying user-generated content between people.
///
/// Blocking is deliberately LOCAL. A server-side blocklist would need the
/// sender's device to honour it, which is unenforceable in a serverless
/// CloudKit design and trivially bypassed; filtering on the receiving device is
/// what actually protects the user, and it works offline. Reports DO go to the
/// public database, because those are for the developer to read and act on.
@MainActor
final class SafetyStore: ObservableObject {
    static let shared = SafetyStore()

    private static let runningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @Published private(set) var blocked: [BlockedUser] = []

    private static var storeDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("photosearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var blockedURL: URL { storeDir.appendingPathComponent("blocked_users.json") }

    private init() { load() }

    // MARK: - Persistence

    func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.blockedURL),
              let arr = try? dec.decode([BlockedUser].self, from: data) else { return }
        blocked = arr
    }

    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(blocked).write(to: Self.blockedURL, options: .atomic)
    }

    // MARK: - Blocking

    func isBlocked(userRecordID: String) -> Bool {
        !userRecordID.isEmpty && blocked.contains { $0.userRecordID == userRecordID }
    }

    /// Block a person. Idempotent — re-blocking refreshes the cached username
    /// rather than adding a duplicate row.
    func block(userRecordID: String, username: String) {
        guard !userRecordID.isEmpty else { return }
        if let i = blocked.firstIndex(where: { $0.userRecordID == userRecordID }) {
            blocked[i].username = username
        } else {
            blocked.insert(BlockedUser(userRecordID: userRecordID,
                                       username: username,
                                       blockedAt: Date()), at: 0)
        }
        persist()
    }

    func unblock(userRecordID: String) {
        guard blocked.contains(where: { $0.userRecordID == userRecordID }) else { return }
        blocked.removeAll { $0.userRecordID == userRecordID }
        persist()
    }

    /// Drop anything originating from a blocked person. Used by the invitation
    /// and photo-request inboxes so blocked users simply stop appearing.
    func filterBlocked<T>(_ items: [T], senderID: (T) -> String) -> [T] {
        guard !blocked.isEmpty else { return items }
        return items.filter { !isBlocked(userRecordID: senderID($0)) }
    }

    /// Wipe the blocklist — part of account deletion.
    func clearAll() {
        blocked = []
        try? FileManager.default.removeItem(at: Self.blockedURL)
    }

    // MARK: - Reporting

    /// File an abuse report into the PUBLIC database, where it can be reviewed
    /// in the CloudKit Dashboard. Reporting also blocks the person — a user who
    /// reports someone should not have to take a second action to stop seeing
    /// them.
    ///
    /// NOTE: `AbuseReport` is a new record type. CloudKit auto-creates it in the
    /// Development environment on first save, but it must be deployed to
    /// Production along with the rest of the schema before release.
    func report(reportedUserRecordID: String,
                reportedUsername: String,
                reason: ReportReason,
                details: String,
                context: String) async throws {
        // Block first and locally, so the user is protected even if the
        // network write fails.
        block(userRecordID: reportedUserRecordID, username: reportedUsername)
        guard !Self.runningTests else { return }

        let container = CKContainer(identifier: CloudKitService.containerIdentifier)
        let reporterID = try await container.userRecordID().recordName

        let record = CKRecord(recordType: AbuseReport.recordType,
                              recordID: CKRecord.ID(recordName: "report_\(UUID().uuidString)"))
        record[AbuseReport.Field.reporterUserRecordID] = reporterID as CKRecordValue
        record[AbuseReport.Field.reportedUserRecordID] = reportedUserRecordID as CKRecordValue
        record[AbuseReport.Field.reportedUsername] = reportedUsername as CKRecordValue
        record[AbuseReport.Field.reason] = reason.rawValue as CKRecordValue
        record[AbuseReport.Field.context] = context as CKRecordValue
        record[AbuseReport.Field.createdAt] = Date() as CKRecordValue
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            record[AbuseReport.Field.details] = trimmed as CKRecordValue
        }
        _ = try await container.publicCloudDatabase.save(record)
    }
}

// MARK: - Models

struct BlockedUser: Identifiable, Codable, Equatable {
    let userRecordID: String
    var username: String
    var blockedAt: Date
    var id: String { userRecordID }

    /// What to show when the cached username is missing (an older blocklist
    /// entry, or a block made from a record that carried no name).
    var displayName: String { username.isEmpty ? "Unknown user" : username }
}

enum ReportReason: String, CaseIterable, Codable, Identifiable {
    case spam
    case harassment
    case nudity
    case violence
    case impersonation
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:          return "Spam or scam"
        case .harassment:    return "Harassment or bullying"
        case .nudity:        return "Nudity or sexual content"
        case .violence:      return "Violence or dangerous content"
        case .impersonation: return "Impersonation"
        case .other:         return "Something else"
        }
    }
}

enum AbuseReport {
    static let recordType = "AbuseReport"
    enum Field {
        static let reporterUserRecordID = "reporterUserRecordID"
        static let reportedUserRecordID = "reportedUserRecordID"
        static let reportedUsername = "reportedUsername"
        static let reason = "reason"
        static let details = "details"
        static let context = "context"
        static let createdAt = "createdAt"
    }
}
