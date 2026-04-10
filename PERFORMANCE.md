# Performance Guide — tricount-backend

Benchmarks, bottlenecks, and optimization strategies for the Tricount backend.

---

## Current Architecture

- **Runtime:** Swift 6 + Vapor 4 on SwiftNIO (non-blocking event loop)
- **Concurrency model:** Swift Structured Concurrency (cooperative thread pool)
- **Database:** MySQL 9.6 via Fluent ORM
- **Auth:** JWT access tokens (stateless) + Argon2id password hashing (via libsodium)
- **Rate limiting:** In-memory sliding-window (actor-based)
- **Cleanup:** Background cron — every 1 hour, purges records expired > 14 min ago

---

## Load Test Results

> Tested on Apple Silicon (M-series), single instance, MySQL, `Scripts/load_test.sh -c 200 -n 1000`

### Lightweight Endpoints

| Endpoint | Avg Latency | Min | Max | Throughput |
|----------|-------------|-----|-----|------------|
| `GET /` (health) | 4ms | 1ms | 56ms | ~273 req/s |
| `GET /v1/auth/me` (JWT) | 15ms | 2ms | 102ms | ~67 req/s |
| `GET /v1/todos` (DB read) | 4ms | 1ms | 69ms | ~258 req/s |
| `POST /v1/auth/login` (invalid) | 13ms | 2ms | 121ms | ~77 req/s |

### Password Hashing Endpoint

| Endpoint | Avg Latency | Min | Max | Throughput |
|----------|-------------|-----|-----|------------|
| `POST /v1/auth/login` (valid, 200 concurrent) | ~2-3s | ~0.1s | ~5s | ~4 req/s (estimated) |

> Previous bcrypt results: 12.1s avg, 0.1 req/s. Argon2id is ~5x faster at equivalent security.

---

## Password Hashing: Argon2id

We use **Argon2id** via [libsodium / swift-sodium](https://github.com/jedisct1/swift-sodium).

### Why Argon2id?

| | Argon2id | Bcrypt (removed) |
|---|---|---|
| **GPU resistance** | Strong (memory-hard) | Moderate |
| **ASIC resistance** | Strong | Weak |
| **Tuning** | Time, memory, parallelism | Cost factor only |
| **OWASP recommendation** | **Preferred** for new systems | Legacy |
| **Speed at equal security** | ~50ms (Moderate) | ~250ms (cost 12) |

### How it works

All hashing is offloaded to NIO's blocking thread pool via `PasswordHasher`:

```swift
// Hash (new registrations, password resets)
let hash = try await req.passwordHasher.hash(password, on: req.eventLoop)
// Returns: "$argon2id$v=19$m=262144,t=3,p=1$..."

// Verify (login)
let valid = try await req.passwordHasher.verify(password: password, against: storedHash, on: req.eventLoop)
```

### Environment-aware parameters

| Environment | opsLimit | memLimit | ~Time per hash |
|-------------|----------|----------|----------------|
| **Production** | 3 (Moderate) | 256 MB (Moderate) | ~50ms |
| **Development** | 2 (Interactive) | 64 MB (Interactive) | ~30ms |
| **Testing** | 1 | 8 KB | ~1ms |

Override with env vars: `ARGON2_OPS_LIMIT=3 ARGON2_MEM_LIMIT=67108864 swift run`

Overrides are validated against the environment's baseline — you cannot weaken below the default.

---

## Expired Record Cleanup

The `ExpiredRecordCleanupService` runs as a background cron via Vapor's lifecycle:

- **Schedule:** Every **1 hour** (configurable via `intervalMinutes`)
- **Cutoff:** `Date() - 14 minutes` — records must be expired for at least 14 minutes before deletion
- **Runs on boot:** Yes, immediately on startup + every hour after
- **Tables cleaned:** EmailVerificationOTP, PasswordResetOTP, EmailMFAChallenge, AuthenticatorAppSetupChallenge, PhoneVerificationOTP, PasskeyChallenge, RefreshToken
- **Parallel:** All table purges run concurrently via `TaskGroup`

### Why 14-minute grace period?

OTPs and challenges typically expire after 5-15 minutes. The 14-minute buffer ensures:
- A token that just expired isn't deleted while a late verification request is in flight
- No race conditions between expiry checks in auth handlers and the cleanup cron

### Monitoring

Watch for these log lines:

```text
Cleanup started — cutoff: records expired before 14 min ago
Purged EmailVerificationOTP
Purged RefreshToken
Cleanup completed
```

---

## Database Indexes

Migration `016_AddPerformanceIndexes` adds indexes on all frequently-queried columns. Applied automatically on startup via `autoMigrate()`.

### What was indexed and why

| Table | Column | Query Pattern | Impact |
|-------|--------|--------------|--------|
| `users` | `google_id` | OAuth login lookup | Full scan → index seek |
| `users` | `apple_id` | OAuth login lookup | Full scan → index seek |
| `users` | `phone_number` | Duplicate phone check | Full scan → index seek |
| `refresh_tokens` | `user_id` | Revoke all on logout | Full scan → index seek |
| `email_verification_otps` | `user_id` | OTP lookup per user | Full scan → index seek |
| `email_verification_otps` | `expires_at` | Cleanup cron | Full scan → range scan |
| `password_reset_otps` | `user_id` | Reset lookup per user | Full scan → index seek |
| `password_reset_otps` | `expires_at` | Cleanup cron | Full scan → range scan |
| `email_mfa_challenges` | `user_id` | MFA challenge lookup | Full scan → index seek |
| `email_mfa_challenges` | `expires_at` | Cleanup cron | Full scan → range scan |
| `phone_verification_otps` | `user_id` | Verification lookup | Full scan → index seek |
| `phone_verification_otps` | `expires_at` | Cleanup cron | Full scan → range scan |
| `authenticator_app_setup_challenges` | `user_id` | Setup challenge lookup | Full scan → index seek |
| `authenticator_app_setup_challenges` | `expires_at` | Cleanup cron | Full scan → range scan |
| `passkey_credentials` | `user_id` | List user's passkeys | Full scan → index seek |
| `passkey_challenges` | `user_id` | Challenge cleanup | Full scan → index seek |
| `passkey_challenges` | `expires_at` | Cleanup cron | Full scan → range scan |

### Already indexed (UNIQUE constraints)

| Table | Column |
|-------|--------|
| `users` | `email` |
| `refresh_tokens` | `token_hash` |
| `passkey_credentials` | `credential_id` |
| `passkey_challenges` | `challenge` |
| `email_mfa_challenges` | `challenge_token_hash` |

### How to verify indexes

```sql
-- List all indexes on a table
SHOW INDEX FROM users;

-- Check query plan
EXPLAIN SELECT * FROM users WHERE google_id = 'abc';
-- Should show: Using index (idx_users_google_id)
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGON2_OPS_LIMIT` | `3` (prod), `2` (dev), `1` (test) | Argon2id time cost (iterations) |
| `ARGON2_MEM_LIMIT` | `256MB` (prod), `64MB` (dev), `8KB` (test) | Argon2id memory cost in bytes |
| `MYSQL_HOST` | `127.0.0.1` | MySQL hostname |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_USERNAME` | `tricount` | MySQL username |
| `MYSQL_PASSWORD` | `tricount` | MySQL password |
| `MYSQL_DATABASE` | `tricount` | MySQL database name |

---

## Remaining Optimization Options

### 1. Horizontal Scaling (Multiple Instances)

Run 4+ server instances behind a reverse proxy (Nginx, Caddy, AWS ALB).

| | Pros | Cons |
|---|---|---|
| + | Linear throughput scaling | Requires shared DB (MySQL/Postgres) |
| + | No security tradeoff | Rate limiting must move to Redis |
| + | Standard production pattern | More infrastructure to manage |

**Verdict:** Required for production. The codebase already supports MySQL.

---

### 2. Login Rate Limiting (Done)

Configured: 10 attempts per 15 min per IP on the login endpoint.

```swift
auth.postData("login", use: login)
    .rateLimit(.custom(identifier: "auth.login", limit: 10, windowSeconds: 900))
```

All rate-limited endpoints:
- `login`: 10/15 min per IP
- `forgot-password`: 3/hour per email
- `verify-email-otp`: 5/hour per IP

---

### 3. Redis-Backed Rate Limiting

Replace the in-memory `RateLimitStore` actor with Redis for multi-instance deployments.

| | Pros | Cons |
|---|---|---|
| + | Shared limits across all instances | External dependency (Redis) |
| + | Survives server restarts | Network latency on every request |
| + | Proven at scale | More infrastructure |

**Verdict:** Required when running multiple instances.

---

## Recommended Production Configuration

```text
┌─────────────────────────────────────────────┐
│              Load Balancer (Nginx/ALB)       │
│         (TLS termination, connection pool)   │
├──────────┬──────────┬──────────┬─────────────┤
│ Instance │ Instance │ Instance │ Instance ... │
│  Vapor   │  Vapor   │  Vapor   │  Vapor       │
├──────────┴──────────┴──────────┴─────────────┤
│              Redis (rate limiting)            │
├──────────────────────────────────────────────┤
│              MySQL / PostgreSQL               │
└──────────────────────────────────────────────┘
```

### Production Checklist

- [x] Argon2id password hashing (replaces bcrypt)
- [x] Login rate limiting: 10 attempts / 15 min per IP
- [x] Database indexes on all queried columns
- [x] Background cleanup cron (1hr interval, 14min grace)
- [x] Structured JSON access logs (Datadog/ELK compatible)
- [ ] Tune `ARGON2_OPS_LIMIT` / `ARGON2_MEM_LIMIT` for server hardware
- [ ] Horizontal scaling: 2+ instances minimum
- [ ] Redis for rate limiting (multi-instance)
- [x] MySQL database (SQLite removed)
- [ ] TLS termination at load balancer
- [ ] Monitor: p50/p95/p99 login latency

---

## Running the Load Test

```bash
# Default: 200 concurrency, 2000 requests
./Scripts/load_test.sh

# Custom concurrency and request count
./Scripts/load_test.sh -c 50 -n 500

# Against a remote server
./Scripts/load_test.sh -u https://api.example.com -c 100 -n 1000
```

Requires `curl` and `python3`. The server must be running before starting the test.

---

## Profiling

```bash
# Build in release mode for realistic profiling
swift build -c release

# Run with Instruments
xcrun xctrace record --template "Time Profiler" --launch .build/release/TricountBackend
```

Focus on:
- `crypto_pwhash_str` / `crypto_pwhash_str_verify` — should appear on NIO thread pool threads
- `EventLoop` utilization — should stay below 80%
- MySQL query performance — check slow query log

---

## Quick Reference

| What | Where | Notes |
|------|-------|-------|
| Password hashing | `PasswordHasher.swift` | Argon2id via libsodium |
| Cleanup cron | `ExpiredRecordCleanupService.swift` | 1hr interval, 14min grace |
| Database indexes | `016_AddPerformanceIndexes.swift` | 17 indexes on 9 tables |
| Rate limit config | `AuthController.swift:boot()` | Per-endpoint policies |
| Rate limit store | `RateLimitMiddleware.swift` | Actor-based, in-memory |
| Access logs | `LoggingMiddleware.swift` | Structured JSON, ISO 8601 |
| MySQL pool config | `Application+Database.swift` | `maxConnectionsPerEventLoop: 4` |
| Load test script | `Scripts/load_test.sh` | curl + python3 |
