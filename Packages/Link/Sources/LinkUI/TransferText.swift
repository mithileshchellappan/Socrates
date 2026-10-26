import Foundation

/// The bytes of a copy between the devices (DESIGN 9).
enum TransferText {
    /// "212 of 520 MB": the bytes on the Mac and the recording's total, both in the total's unit,
    /// named once (decimal units, as Finder shows file sizes). The stored part is rounded down, so
    /// the line never claims bytes the Mac does not hold yet.
    static func bytes(_ stored: Int64, of total: Int64) -> String {
        let total = max(total, 0)
        let stored = min(max(stored, 0), total)
        let unit: UnitInformationStorage
        let divisor: Double
        let digits: Int
        switch total {
        case ..<1_000_000: (unit, divisor, digits) = (.kilobytes, 1e3, 0)
        case ..<1_000_000_000: (unit, divisor, digits) = (.megabytes, 1e6, 0)
        default: (unit, divisor, digits) = (.gigabytes, 1e9, 1)
        }
        let step = pow(10, Double(digits))
        let totalValue = Double(total) / divisor
        let storedValue = stored == total ? totalValue : (Double(stored) / divisor * step).rounded(.down) / step
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits))
        let totalText = Measurement(value: totalValue, unit: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: number))
        return String(localized: "\(storedValue.formatted(number)) of \(totalText)")
    }
}
