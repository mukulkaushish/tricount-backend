# CLAUDE.md — tricount-backend

## Priority Rules

- **Never** add `Co-Authored-By` or any Claude/AI attribution to git commit messages.
- **Never** run `git commit` or `git push` directly. Only suggest the commit message — the user will commit and push manually.
- **Never** use aggressive sed/awk replacements across multiple files. Always use targeted edits with the Edit tool to avoid syntax corruption.
- **All migrations must wrap operations in database transactions** so partial failures roll back automatically.
- **Always follow the feature template** at `Documentation/FEATURE_TEMPLATE.md` when adding or modifying features.
- **After any feature change**, update the relevant sections in this file (endpoints table, project layout, phase roadmap).

---

## Overview

Server-side Swift backend for the **Tricount** Flutter expense-splitting app.
Built with [Vapor 4](https://vapor.codes), Fluent ORM, MySQL, and JWT auth.

---

## Quick Start

```bash
docker compose up mysql -d
swift package resolve
export JWT_SECRET="your-strong-random-secret-here"
swift run
# Server: http://localhost:8080 — Health: GET /
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `JWT_SECRET` | `change-me-in-production-use-env-var` | HMAC-SHA256 signing key |
| `MYSQL_HOST` | `127.0.0.1` | MySQL hostname |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_USERNAME` | `tricount` | MySQL username |
| `MYSQL_PASSWORD` | `tricount` | MySQL password |
| `MYSQL_DATABASE` | `tricount` | MySQL database name |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error` |

---

## Project Layout

```
Sources/TricountBackend/
├── configure.swift                  # App bootstrap
├── routes.swift                     # Top-level route registration (/v1/...)
├── entrypoint.swift                 # main()
│
├── Controllers/
│   ├── Auth/                        # Auth sub-controllers (session, MFA, passkeys, account)
│   │   ├── AuthSessionController.swift
│   │   ├── AuthAccountController.swift
│   │   ├── AuthMFALoginController.swift
│   │   ├── AuthMFASettingsController.swift
│   │   └── AuthPasskeyManagementController.swift
│   ├── AuthController.swift         # Auth route composition
│   ├── GroupController.swift        # Groups & members
│   ├── ExpenseController.swift      # Expenses & splits
│   ├── PaymentController.swift      # Payments & reversals
│   ├── InviteController.swift       # Group invites
│   └── PaymentIdentityController.swift  # UPI/QR payment identity
│
├── DTOs/                            # Request & response Codable structs
│   ├── AuthDTOs.swift
│   ├── GroupDTOs.swift              # + UserBasicInfo, model→DTO extensions
│   ├── ExpenseDTOs.swift
│   ├── PaymentDTOs.swift
│   ├── InviteDTOs.swift
│   ├── ActivityDTOs.swift
│   ├── PaymentIdentityDTOs.swift
│   └── PasskeyDTOs.swift
│
├── Middleware/
│   ├── ErrorMiddleware.swift        # All errors → standard JSON shape
│   ├── JWTAuthMiddleware.swift      # Bearer JWT verification + AuthError enum
│   ├── GroupMemberMiddleware.swift   # Validates membership, injects GroupContext
│   ├── LoggingMiddleware.swift      # Structured request/response logging
│   └── RateLimitMiddleware.swift    # Sliding-window in-memory rate limiter
│
├── Migrations/                      # All DB migrations (transactional)
│
├── Models/                          # Fluent models
│   ├── User.swift
│   ├── RefreshToken.swift
│   ├── Group.swift
│   ├── GroupMember.swift
│   ├── GroupActivity.swift
│   ├── GroupInvite.swift
│   ├── Expense.swift
│   ├── ExpenseSplit.swift
│   ├── LedgerEntry.swift
│   ├── Payment.swift
│   ├── UserPaymentIdentity.swift
│   └── ...                          # MFA, passkey, OTP models
│
├── Extensions/
│   ├── Request+ApplicationHelpers.swift  # authenticatedUserID, requireUUIDParameter
│   ├── Request+ResponseHelpers.swift     # Response.json(), dataResponse()
│   ├── Fluent+Helpers.swift              # Model.requireFind(), QueryBuilder.firstOrThrow()
│   ├── Constants.swift                   # TokenLifetime values
│   └── ...
│
├── Payload/
│   └── UserJWTPayload.swift         # JWT payload + req.jwtPayload helper
│
├── Services/
│   ├── ResourceServices.swift       # Facade: req.services.groups/expenses/payments/...
│   ├── GroupService.swift           # Group CRUD, members, activity logging
│   ├── ExpenseService.swift         # Expense CRUD, splits, ledger entries
│   ├── PaymentService.swift         # Payment CRUD, reversals, ledger entries
│   ├── InviteService.swift          # Invite create, accept, token validation
│   ├── PaymentIdentityService.swift # UPI/QR identity management
│   ├── BalanceService.swift         # Balance computation, debt simplification
│   ├── AuthServices.swift           # Facade: req.authServices.session/account/mfa/...
│   ├── AuthService.swift            # Core auth logic (login, register, social)
│   ├── AuthService+Session.swift    # Login, register, refresh, social sign-in
│   ├── AuthService+Account.swift    # Profile, email verification, logout
│   ├── AuthService+MFA.swift        # MFA enable/disable, email/phone/authenticator
│   ├── AuthService+Recovery.swift   # Password reset, backup codes
│   ├── PasskeyService.swift         # WebAuthn passkey operations
│   └── ...
│
└── Documentation/
    └── DocumentedRoutesBuilder.swift  # Auto-docs + bearerProtected() helper
```

---

## Architecture Patterns

### Service Layer (Dependency Inversion)

All services are instance-based, accessed via request:
```swift
// Resource services
req.services.groups.create(input, createdByID: userID)
req.services.expenses.list(groupID: groupID)
req.services.balances.simplifyDebts(groupID: groupID)

// Auth services
req.authServices.session.login(dto: body)
req.authServices.account.currentUser()
```

Services hold `req: Request` — no static methods, no `req` in every call.

### Middleware Chain

Group-scoped routes use layered middleware:
```swift
routes
    .grouped("groups", ":id")
    .grouped(JWTAuthMiddleware())       // Verifies JWT
    .grouped(GroupMemberMiddleware())    // Validates membership → req.groupContext
    .grouped("expenses")
```

Handlers access context directly:
```swift
func getExpense(req: Request) async throws -> ExpenseDetailsResponse {
    let ctx = try req.groupContext  // groupID, userID, member — pre-validated
    let expense = try await req.services.expenses.get(expenseID: ...)
    ...
}
```

### Model → Response Mapping

Conversions live as extensions on models:
```swift
user.toBasicInfo()          // User → UserBasicInfo
member.toResponse(with:)    // GroupMember + User → GroupMemberResponse
identity.toResponse()       // UserPaymentIdentity → PaymentIdentityResponse
```

### Shared Helpers

| Helper | Location | Replaces |
|--------|----------|----------|
| `req.authenticatedUserID` | `Request+ApplicationHelpers` | Manual JWT decode + UUID cast |
| `req.requireUUIDParameter("id")` | `Request+ApplicationHelpers` | `guard let id = req.parameters.get(...)` |
| `req.groupContext` | `GroupMemberMiddleware` | userID + groupID + assertMember |
| `Model.requireFind(id, on:)` | `Fluent+Helpers` | `guard let x = try await X.find(...) else { throw }` |

### Error Format

All errors → standard JSON via `TricountErrorMiddleware`:
```json
{ "error": "CODE", "message": "Human message", "statusCode": 401 }
```

Use `Abort(.status, reason:)` for ad-hoc errors.
Use `AuthError` enum cases for auth-domain errors.

### Token Strategy

- **Access:** JWT (HMAC-SHA256), 1-hour expiry, stateless
- **Refresh:** 32-byte random, SHA-256 hashed in DB, rotated on use, revoked on logout

### Ledger System

All monetary operations write to `ledger_entries`. Balances are derived, never stored.
Amounts are `Int64` in minor units (paise). Currency default: `INR`.

---

## API Endpoints

### Auth (Public)

| Method | Path | Rate Limit |
|--------|------|------------|
| `POST` | `/v1/auth/login` | 10/15min |
| `POST` | `/v1/auth/register` | 5/hour |
| `POST` | `/v1/auth/forgot-password` | 3/hour |
| `POST` | `/v1/auth/reset-password` | — |
| `POST` | `/v1/auth/google` | 20/15min |
| `POST` | `/v1/auth/apple` | 20/15min |
| `POST` | `/v1/auth/refresh` | 30/hour |
| `POST` | `/v1/auth/mfa/*` | varies |
| `POST` | `/v1/auth/passkeys/authenticate/*` | — |

### Auth (Protected — Bearer JWT)

| Method | Path |
|--------|------|
| `GET` | `/v1/auth/me` |
| `POST` | `/v1/auth/logout` |
| `POST` | `/v1/auth/verify-profile/*` |
| `POST` | `/v1/auth/mfa/enable\|disable` |
| `POST` | `/v1/auth/mfa/email/*` |
| `POST` | `/v1/auth/mfa/phone/*` |
| `POST` | `/v1/auth/mfa/authenticator-app/*` |
| `POST` | `/v1/auth/mfa/backup-codes/*` |
| `*` | `/v1/auth/passkeys/*` (management) |

### Groups (Protected — Bearer JWT + Membership)

| Method | Path | Notes |
|--------|------|-------|
| `POST` | `/v1/groups` | Create (no group context) |
| `GET` | `/v1/groups` | List user's groups |
| `GET` | `/v1/groups/:id` | Group details |
| `PUT` | `/v1/groups/:id` | Update (admin only) |
| `POST` | `/v1/groups/:id/members` | Add member (admin) |
| `GET` | `/v1/groups/:id/members` | List members |
| `DELETE` | `/v1/groups/:id/members/:userId` | Remove (admin) |
| `PUT` | `/v1/groups/:id/members/:userId/role` | Change role (admin) |
| `POST` | `/v1/groups/:id/leave` | Leave group |
| `GET` | `/v1/groups/:id/activities` | Activity log |
| `GET` | `/v1/groups/:id/balance` | Group balances |
| `GET` | `/v1/groups/:id/balance/simplified` | Simplified debts |

### Expenses (Protected — Bearer JWT + Membership)

| Method | Path |
|--------|------|
| `POST` | `/v1/groups/:id/expenses` |
| `GET` | `/v1/groups/:id/expenses` |
| `GET` | `/v1/groups/:id/expenses/:expenseId` |
| `PUT` | `/v1/groups/:id/expenses/:expenseId` |
| `DELETE` | `/v1/groups/:id/expenses/:expenseId` |

### Payments (Protected — Bearer JWT + Membership)

| Method | Path |
|--------|------|
| `POST` | `/v1/groups/:id/payments` |
| `GET` | `/v1/groups/:id/payments` |
| `GET` | `/v1/groups/:id/payments/:paymentId` |
| `POST` | `/v1/groups/:id/payments/:paymentId/reverse` |

### Invites (Protected — Bearer JWT)

| Method | Path | Notes |
|--------|------|-------|
| `POST` | `/v1/groups/:id/invites` | Create (admin, group-scoped) |
| `GET` | `/v1/groups/:id/invites` | List (group-scoped) |
| `POST` | `/v1/invites/accept` | Accept invite |
| `GET` | `/v1/invites/:token` | Get invite by token |

### Payment Identity (Protected — Bearer JWT)

| Method | Path |
|--------|------|
| `POST` | `/v1/payment-identity` |
| `GET` | `/v1/payment-identity` |
| `DELETE` | `/v1/payment-identity` |

---

## Adding a New Feature

1. Copy `Documentation/FEATURE_TEMPLATE.md` to `Documentation/features/[name].md`
2. Fill out all sections in the template
3. Follow the architecture checklist in the template
4. Implementation order: Migration → Model → DTOs → Service → Controller → routes.swift
5. Register service in `ResourceServices.swift` if new
6. **Update this file** (endpoints, project layout, phase roadmap)

---

## Running Tests

```bash
swift test
```

---

## Docker

```bash
docker compose up --build
```

---

## Phase Roadmap

| Phase | Status | Scope |
|---|---|---|
| 1 | Done | Project scaffold |
| 2 | Done | Auth (login, register, Google, Apple, MFA, passkeys, refresh, logout) |
| 3 | Done | Groups, members, activity log |
| 4 | Done | Expenses, splits, ledger |
| 5 | Done | Payments, reversals |
| 6 | Done | Invites |
| 7 | Done | Payment identity (UPI/QR) |
| 8 | Done | Balance computation, debt simplification |
| 9 | Planned | Sync queue |
