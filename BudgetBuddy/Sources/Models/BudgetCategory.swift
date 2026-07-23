import Foundation

struct BudgetCategory: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var monthlyLimit: Decimal

    init(id: UUID = UUID(), name: String, monthlyLimit: Decimal) {
        self.id = id
        self.name = name
        self.monthlyLimit = monthlyLimit
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case monthlyLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)

        if let decimalLimit = try? container.decode(Decimal.self, forKey: .monthlyLimit) {
            monthlyLimit = decimalLimit
        } else {
            let doubleLimit = try container.decode(Double.self, forKey: .monthlyLimit)
            monthlyLimit = Decimal(doubleLimit)
        }
    }
}
