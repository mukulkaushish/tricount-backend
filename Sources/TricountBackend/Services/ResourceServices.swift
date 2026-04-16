import Vapor

/// Capability-scoped resource service access, mirroring the `AuthServices` pattern.
///
/// Usage: `req.services.groups.create(input, createdByID: userID)`
/// instead of: `GroupService.createGroup(req, input, createdByID: userID)`
struct ResourceServices {
    let req: Request

    var groups: GroupService { GroupService(req: req) }
    var expenses: ExpenseService { ExpenseService(req: req) }
    var payments: PaymentService { PaymentService(req: req) }
    var invites: InviteService { InviteService(req: req) }
    var paymentIdentity: PaymentIdentityService { PaymentIdentityService(req: req) }
    var balances: BalanceService { BalanceService(req: req) }
}

extension Request {
    var services: ResourceServices {
        ResourceServices(req: self)
    }
}
