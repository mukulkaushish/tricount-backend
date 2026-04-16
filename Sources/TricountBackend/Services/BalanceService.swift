import Fluent
import Vapor

struct BalanceService: Content {
    static func getGroupBalances(_ req: Request, groupID: UUID) async throws -> [UserBalanceResponse] {
        let entries = try await LedgerEntry
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .all()

        var balances: [UUID: Int64] = [:]
        for entry in entries {
            let userId = try entry.$user.id
            balances[userId, default: 0] += entry.amount
        }

        var results: [UserBalanceResponse] = []
        for (userId, amount) in balances {
            results.append(UserBalanceResponse(userId: userId, balance: amount, currency: "INR"))
        }

        return results
    }

    static func getUserBalance(_ req: Request, groupID: UUID, userID: UUID) async throws -> Int64 {
        let entries = try await LedgerEntry
            .query(on: req.db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == userID)
            .all()

        return entries.reduce(0) { $0 + $1.amount }
    }

    static func simplifyDebts(_ req: Request, groupID: UUID) async throws -> [SimplifiedDebtResponse] {
        let balances = try await getGroupBalances(req, groupID: groupID)

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

        var simplified: [SimplifiedDebtResponse] = []
        var debtorIndex = 0
        var creditorIndex = 0
        var debtorAmount = debtors[debtorIndex].1
        var creditorAmount = creditors[creditorIndex].1

        while debtorIndex < debtors.count && creditorIndex < creditors.count {
            let debtorId = debtors[debtorIndex].0
            let creditorId = creditors[creditorIndex].0
            let transferAmount = min(debtorAmount, creditorAmount)

            simplified.append(SimplifiedDebtResponse(
                from: try await getUserBasicInfo(req, userID: debtorId),
                to: try await getUserBasicInfo(req, userID: creditorId),
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

    static func getUserBasicInfo(_ req: Request, userID: UUID) async throws -> UserBasicInfo {
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "User not found")
        }

        return UserBasicInfo(
            id: try user.requireID(),
            displayName: user.displayName,
            email: user.email,
            avatarUrl: nil
        )
    }
}
