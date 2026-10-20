import Foundation

/// Decides which items retention removes (HI-5). Pure so it's easy to test.
///
/// 1. Items older than the retention window go.
/// 2. If a storage cap is set and the remaining items still exceed it, the
///    oldest items go next until the library fits.
enum RetentionPlanner {
    struct Entry: Sendable {
        var id: UUID
        var createdAt: Date
        var byteSize: Int64
    }

    static func idsToDelete(
        _ entries: [Entry],
        retention: HistoryRetention,
        storageCapBytes: Int64?,
        now: Date,
        calendar: Calendar = .current
    ) -> [UUID] {
        var doomed: [UUID] = []
        var kept = entries.sorted { $0.createdAt < $1.createdAt }

        if let days = retention.days,
           let cutoff = calendar.date(byAdding: .day, value: -days, to: now) {
            let expired = kept.prefix { $0.createdAt < cutoff }
            doomed.append(contentsOf: expired.map(\.id))
            kept.removeFirst(expired.count)
        }

        if let cap = storageCapBytes {
            var total = kept.reduce(Int64(0)) { $0 + $1.byteSize }
            var index = 0
            while total > cap, index < kept.count {
                doomed.append(kept[index].id)
                total -= kept[index].byteSize
                index += 1
            }
        }
        return doomed
    }
}
