import Foundation

struct BudgetTransaction: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var amount: Decimal
    var categoryID: UUID
    var date: Date

    init(id: UUID = UUID(), title: String, amount: Decimal, categoryID: UUID, date: Date) {
        self.id = id
        self.title = title
        self.amount = amount
        self.categoryID = categoryID
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case amount
        case categoryID
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        date = try container.decode(Date.self, forKey: .date)

        if let decimalAmount = try? container.decode(Decimal.self, forKey: .amount) {
            amount = decimalAmount
        } else {
            let doubleAmount = try container.decode(Double.self, forKey: .amount)
            amount = Decimal(doubleAmount)
        }
    }
}
