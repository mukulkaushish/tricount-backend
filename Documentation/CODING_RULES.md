# Coding Rules

These rules are intended to keep the backend readable, scalable, and predictable for developers working on `tricount-backend`.

## 1. Architecture Rules

- Use feature-first structure for fast-growing domains such as auth, MFA, passkeys, groups, and expenses.
- Each RouteCollection should own one bounded capability.
- Controllers are transport-layer adapters, not business-logic containers.
- Services own business workflows, security decisions, and DB coordination.
- Models represent persistence state and relationships, not orchestration.
- DTOs define request/response contracts and should stay decoupled from Fluent models.
- Request extensions should only provide narrow factories or request-scoped helpers.

## 2. Controller Rules

- Keep controllers thin.
- A controller method should usually do one thing: decode, delegate, return.
- If a controller starts mixing multiple auth capabilities, split it into another RouteCollection.
- Keep public and authenticated route registration visibly separated.
- Preserve existing HTTP contracts when doing internal refactors unless the contract change is intentional and documented.

## 3. Service Rules

- Put business rules in services, not controllers.
- Prefer one service per capability as the codebase grows.
- Avoid “god services”. If a service spans unrelated workflows, split it by bounded context.
- Centralize security-sensitive logic such as OTP validation, MFA state changes, and token issuance.
- Use transactions for multi-step persistence that must succeed atomically.

## 4. Persistence Rules

- New schema changes must use new migrations.
- Avoid rewriting released migrations except for local-only test fixes that are explicitly understood.
- Add indexes for recurring lookup paths, expiry cleanup paths, and foreign-key filters.
- Never store raw OTP values.
- Hash or encrypt sensitive MFA data appropriately.

## 5. API Design Rules

- Follow Swift API Design Guidelines for naming and argument labels.
- Name types with nouns and actions with verbs.
- Use explicit argument labels when they improve clarity at the call site.
- Prefer clear, stable DTO names over clever abbreviations.
- Add concise doc comments to new controllers, services, and complex helpers.

## 6. Testing Rules

- Add at least one success-path test for every new auth or MFA flow.
- Add at least one failure-path test for every security-sensitive flow.
- When changing routing or architecture, verify at least one representative endpoint per affected route collection.
- Add regression tests when fixing bugs around MFA state transitions.

## 7. Readability Rules

- Prefer small files with a single reason to change.
- Use `MARK:` sections to group related behavior inside larger files.
- Prefer helper methods with domain names over inline duplicated logic.
- Avoid hidden side effects in computed properties or tiny wrappers.
- When a type grows rapidly, split by feature before the file becomes hard to scan.

## 8. Auth Module Rules

- Keep route ownership split across session, account, MFA login, MFA settings, and passkey management.
- MFA “method available” and “MFA enabled” are separate states and must stay separate in code.
- Do not allow removing the last primary MFA factor while MFA is enabled unless the product explicitly changes that rule.
- Backup codes are recovery factors, not primary factors.

## 9. Pull Request Rules

- Summarize architectural intent, not just file changes.
- Call out contract changes, migration changes, and security implications explicitly.
- Include test coverage notes.

## References

- Vapor routing docs: <https://docs.vapor.codes/de/basics/routing/>
- Swift API Design Guidelines: <https://www.swift.org/documentation/api-design-guidelines/>
