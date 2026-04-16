# Feature: [FEATURE_NAME]

> Copy this template to `Documentation/features/[feature-name].md` when starting a new feature.

---

## 1. Overview

**What:** One sentence describing the feature.
**Why:** Business reason or user need this addresses.
**Phase:** Which roadmap phase this belongs to.

---

## 2. Data Model

### New Tables

| Table | Column | Type | Constraints | Description |
|-------|--------|------|-------------|-------------|
| `table_name` | `id` | `UUID` | PK | |
| | `field` | `VARCHAR(255)` | NOT NULL | |

### Modified Tables

| Table | Change | Migration File |
|-------|--------|---------------|
| `existing_table` | Add column `new_col` | `AddNewCol.swift` |

---

## 3. API Endpoints

| Method | Path | Auth | Rate Limit | Request Body | Response |
|--------|------|------|------------|--------------|----------|
| `POST` | `/v1/resource` | Bearer JWT | — | `CreateResourceRequest` | `201` `CreateResourceResponse` |
| `GET` | `/v1/resource` | Bearer JWT | — | — | `200` `ListResourceResponse` |

### Request/Response Examples

```json
// POST /v1/resource
// Request:
{ "name": "example" }

// Response (201):
{ "id": "uuid", "name": "example", "created_at": "2026-01-01T00:00:00Z" }
```

---

## 4. Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `Models/Resource.swift` | Fluent model |
| `DTOs/ResourceDTOs.swift` | Request/response types |
| `Controllers/ResourceController.swift` | Route handlers |
| `Migrations/CreateResource.swift` | DB migration (wrapped in transaction) |

### Modified Files

| File | Change |
|------|--------|
| `Services/GroupService.swift` | Add helper method |
| `routes.swift` | Register new controller |

---

## 5. Architecture Checklist

Use this to ensure the feature follows project patterns:

- [ ] **Controller** is a thin orchestrator — no business logic
- [ ] **Service** is instance-based via `req.services.*` (registered in `ResourceServices.swift`)
- [ ] **Middleware** — group-scoped routes use `GroupMemberMiddleware` (no manual `assertUserIsMember`)
- [ ] **Auth** — all protected routes wrapped in `JWTAuthMiddleware`
- [ ] **DTOs** — request types use `Content`, response CodingKeys map to `snake_case`
- [ ] **Model → Response** — mapping lives as extension on model (e.g., `model.toResponse()`)
- [ ] **Existing helpers used** — `req.authenticatedUserID`, `req.requireUUIDParameter()`, `req.groupContext`, `User.requireFind()`, `user.toBasicInfo()`, `member.toResponse(with:)`
- [ ] **Migration** — wrapped in `req.db.transaction { ... }` so partial failures roll back
- [ ] **Activity logging** — mutations call `req.services.groups.logActivity(...)` 
- [ ] **Error format** — use `Abort(.status, reason:)` or domain-specific `AbortError` enum

---

## 6. Edge Cases & Validation

| Scenario | Expected Behavior |
|----------|-------------------|
| Unauthorized user | `403 Forbidden` |
| Resource not found | `404 Not Found` |
| Invalid input | `400 Bad Request` with reason |

---

## 7. Testing

| Test | Type | Description |
|------|------|-------------|
| `testCreateResource` | Integration | Happy path |
| `testCreateResourceUnauthorized` | Integration | Non-member gets 403 |
| `testCreateResourceBadInput` | Unit | Validation rejects invalid data |

---

## 8. Status

- [ ] Data model & migration
- [ ] Service layer
- [ ] DTOs
- [ ] Controller & routes
- [ ] Tests
- [ ] CLAUDE.md updated
