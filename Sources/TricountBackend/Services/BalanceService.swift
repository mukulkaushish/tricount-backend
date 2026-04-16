import Fluent
import Vapor

struct BalanceService {
    let req: Request

    func getGroupBalances(groupID: UUID) async throws -> [UserBalanceResponse] {
        // Three independent reads — dispatch in parallel to cut latency on the hottest balance endpoint.
        async let entriesQuery = LedgerEntry
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .all()

        async let reversedQuery = Payment.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$reversedAt != nil)
            .all(\.$id)

        async let deletedQuery = Expense.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$deletedAt != nil)
            .all(\.$id)

        let (entries, reversedPaymentIDs, deletedExpenseIDs) = try await (entriesQuery, reversedQuery, deletedQuery)

        // Defense-in-depth: even though expense-delete and payment-reverse now purge ledger entries, filter defensively
        // so any straggler (e.g. from historical data predating the cleanup) doesn't corrupt balances.
        let reversedSet = Set(reversedPaymentIDs)
        let deletedSet = Set(deletedExpenseIDs)

        var balances: [UUID: Int64] = [:]
        for entry in entries {
            switch entry.referenceType {
            case "PAYMENT" where reversedSet.contains(entry.referenceId):
                continue
            case "EXPENSE" where deletedSet.contains(entry.referenceId):
                continue
            default:
                balances[entry.$user.id, default: 0] += entry.amount
            }
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

        let userIDs = Set(creditors.map(\.0) + debtors.map(\.0))
        let users = try await User.query(on: req.db)
            .filter(\.$id ~~ Array(userIDs))
            .all()
        let userMap = Dictionary(uniqueKeysWithValues: users.compactMap { user -> (UUID, User)? in
            guard let id = user.id else { return nil }
            return (id, user)
        })

        func userInfo(_ id: UUID) throws -> UserBasicInfo {
            guard let user = userMap[id] else {
                throw Abort(.notFound, reason: "User \(id) not found while computing simplified debts")
            }
            return try user.toBasicInfo()
        }

        var simplified: [SimplifiedDebtResponse] = []
        var debtorIndex = 0
        var creditorIndex = 0
        var debtorAmount = debtors[debtorIndex].1
        var creditorAmount = creditors[creditorIndex].1

        while debtorIndex < debtors.count && creditorIndex < creditors.count {
            let transferAmount = min(debtorAmount, creditorAmount)

            simplified.append(SimplifiedDebtResponse(
                from: try userInfo(debtors[debtorIndex].0),
                to: try userInfo(creditors[creditorIndex].0),
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
