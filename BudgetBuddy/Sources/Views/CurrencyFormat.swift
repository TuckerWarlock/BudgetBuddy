import Foundation

extension Decimal {
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        return formatter
    }()

    var asCurrency: String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: self)) ?? "\(self)"
    }
}
