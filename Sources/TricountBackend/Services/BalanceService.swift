import Fluent
import Vapor

struct BalanceService {
    let req: Request

    func getGroupBalances(groupID: UUID) async throws -> [UserBalanceResponse] {
        let entries = try await LedgerEntry
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .all()

        var balances: [UUID: Int64] = [:]
        for entry in entries {
            let userId = try entry.$user.id
            balances[userId, default: 0] += entry.amount
        }

        return balances.map { UserBalanceResponse(userId: $0.key, balance: $0.value, currency: "INR") }
    }

    func simplifyDebts(groupID: UUID) async throws -> [SimplifiedDebtResponse] {
        let balances = try await getGroupBalances(groupID: groupID)

        var creditors: [(UUID, Int64)] = []
        var debtors: [(UUID, Int64)] = []

        for balance in balances {
            if balance.balance > 0 {
                creditors.append((balance.userId, balance.balance))
            } else if balance.balance < 0 {
                debtors.append((balance.userId, -balance.balance))
            }
        }

        creditors.sort { $0.1 > $1.1 }
        debtors.sort { $0.1 > $1.1 }

        guard !debtors.isEmpty, !creditors.isEmpty else { return [] }

        var simplified: [SimplifiedDebtResponse] = []
        var debtorIndex = 0
        var creditorIndex = 0
        var debtorAmount = debtors[debtorIndex].1
        var creditorAmount = creditors[creditorIndex].1

        while debtorIndex < debtors.count && creditorIndex < creditors.count {
            let transferAmount = min(debtorAmount, creditorAmount)

            let fromUser = try await User.requireFind(debtors[debtorIndex].0, on: req.db)
            let toUser = try await User.requireFind(creditors[creditorIndex].0, on: req.db)
            simplified.append(SimplifiedDebtResponse(
                from: try fromUser.toBasicInfo(),
                to: try toUser.toBasicInfo(),
                amount: transferAmount
            ))

            debtorAmount -= transferAmount
            creditorAmount -= transferAmount

            if debtorAmount == 0 {
                debtorIndex += 1
                if debtorIndex < debtors.count {
                    debtorAmount = debtors[debtorIndex].1
                }
            }

            if creditorAmount == 0 {
                creditorIndex += 1
                if creditorIndex < creditors.count {
                    creditorAmount = creditors[creditorIndex].1
                }
            }
        }

        return simplified
    }
}
