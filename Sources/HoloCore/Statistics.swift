import Foundation

extension Array where Element == Double {
    func median() -> Double {
        guard !isEmpty else { return 0 }
        let sorted = self.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}
