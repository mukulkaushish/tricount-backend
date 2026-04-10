# CLAUDE.md — tricount-backend

## Priority Rules

- **Never** add `Co-Authored-By` or any Claude/AI attribution to git commit messages.
- **Never** run `git commit` or `git push` directly. Only suggest the commit message — the user will commit and push manually.

---

Server-side Swift backend for the **Tricount** Flutter expense-splitting app.
Built with [Vapor 4](https://vapor.codes), Fluent ORM, MySQL, and JWT auth.

---

## Quick start

```bash
# 1. Start MySQL (via Docker or local install)
docker compose up mysql -d

# 2. Resolve packages (must do this first after cloning or adding deps)
swift package resolve

# 3. Set required environment variables (see below)
export JWT_SECRET="your-strong-random-secret-here"

# 4. Run (auto-migrates the DB on startup)
swift run

# Server listens on http://localhost:8080
# Health check: GET /
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `JWT_SECRET` | `change-me-in-production-use-env-var` | HMAC-SHA256 signing key — **always override in prod** |
| `MYSQL_HOST` | `127.0.0.1` | MySQL hostname |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_USERNAME` | `tricount` | MySQL username |
| `MYSQL_PASSWORD` | `tricount` | MySQL password |
| `MYSQL_DATABASE` | `tricount` | MySQL database name |
| `LOG_LEVEL` | `info` | Vapor log level (`debug`, `info`, `warning`, `error`) |

---

## Project layout

```
Sources/TricountBackend/
├── configure.swift          # App bootstrap: middleware, JWT, DB, migrations, routes
├── routes.swift             # Top-level route registration (/v1/...)
├── entrypoint.swift         # main()
│
├── Controllers/
│   └── AuthController.swift # All /v1/auth/* route handlers
│
├── DTOs/
│   └── AuthDTOs.swift       # Request & response Codable structs
│
├── Middleware/
│   ├── ErrorMiddleware.swift      # Global: all errors → standard JSON shape
│   ├── JWTAuthMiddleware.swift    # Verifies Bearer JWT; defines AuthError
│   ├── LoggingMiddleware.swift    # Structured request/response logging
│   └── RateLimitMiddleware.swift  # Sliding-window in-memory rate limiter
│
├── Migrations/
│   ├── CreateUser.swift           # users table
│   └── CreateRefreshToken.swift   # refresh_tokens table
│
├── Models/
│   ├── User.swift                 # Fluent model
│   └── RefreshToken.swift         # Fluent model (stores token hash, never raw)
│
├── Payload/
│   └── UserJWTPayload.swift       # JWTPayload struct + req.jwtPayload helper
│
└── Services/
    ├── AuthService.swift          # Login, register, Google, refresh, logout
    └── GoogleAuthService.swift    # Verifies Google ID token via tokeninfo API
```

---

## API endpoints (Phase 2 — Auth)

Base URL: `GET /v1`

| Method | Path | Auth | Rate limit |
|---|---|---|---|
| `POST` | `/v1/auth/login` | — | 10/15 min per IP |
| `POST` | `/v1/auth/register` | — | 5/hour per IP |
| `POST` | `/v1/auth/forgot-password` | — | 3/hour per email |
| `POST` | `/v1/auth/google` | — | 20/15 min per IP |
| `POST` | `/v1/auth/refresh` | — | 30/hour per token |
| `GET` | `/v1/auth/me` | Bearer JWT | — |
| `POST` | `/v1/auth/logout` | Bearer JWT | — |

Full contract: `API_CONTRACT.md`

---

## Architecture decisions

### Rate limiting
Actor-based in-memory sliding-window limiter (`RateLimitStore`). Each endpoint has its own
`RateLimitMiddleware` instance with the limits from `API_CONTRACT.md`. Middleware returns
`429 Too Many Requests` with a `Retry-After` header when exceeded.

**For production:** replace with a Redis-backed store to share limits across multiple instances.

### Token strategy
- **Access token:** JWT (HMAC-SHA256), expires in 1 hour. Stateless — no DB lookup needed.
- **Refresh token:** 32-byte cryptographically random value, stored as a SHA-256 hash in `refresh_tokens`. Rotated on every use. Revoked on logout (all tokens for the user).

### Error handling
All errors flow through `TricountErrorMiddleware`, which converts `AuthError` and `AbortError`
to the standard contract shape:
```json
{ "error": "CODE", "message": "Human message", "statusCode": 401 }
```

### Google OAuth
Validated via `https://www.googleapis.com/oauth2/v3/tokeninfo?id_token=<token>`.
For production consider verifying the JWT locally using Google's public keys to avoid the
extra network hop.

### Password policy (enforced server-side)
- 8–128 characters
- At least 1 uppercase, 1 lowercase, 1 digit

---

## Adding a new endpoint

1. Add the route to `AuthController.boot(routes:)` (or create a new `RouteCollection`).
2. Add any new request/response types to `DTOs/`.
3. Implement business logic in the relevant `Service`.
4. Register the collection in `routes.swift` if new.
5. Add or update a migration if the DB schema changes.

---

## Running tests

```bash
swift test
```

Test target: `Tests/TricountBackendTests/`

---

## Docker

```bash
docker compose up --build
```

See `docker-compose.yml` and `Dockerfile` for configuration.

---

## Phase roadmap

| Phase | Status | Scope |
|---|---|---|
| 1 | Done | Project scaffold |
| 2 | **In progress** | Auth (login, register, Google, refresh, logout) |
| 3 | Planned | Groups & members |
| 4 | Planned | Expenses |
| 5 | Planned | Settlements |
| 6 | Planned | Sync queue |
