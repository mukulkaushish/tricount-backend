# Tricount Backend

Server-side Swift backend for the Tricount expense-splitting app. Built with Vapor 4, Fluent ORM, MySQL, and JWT auth.

## Features

- JWT authentication with refresh token rotation
- Google and Apple social sign-in
- Multi-factor authentication (email, phone, authenticator app, passkeys)
- Group management with role-based access (admin/member)
- Expense tracking with flexible splits
- Double-entry ledger system for balance computation
- Debt simplification algorithm
- Payment recording and reversals
- Group invite system with token-based acceptance

## Quick Start

```bash
docker compose up mysql -d
swift package resolve
export JWT_SECRET="your-secret"
swift run
```

Server runs at `http://localhost:8080`.

## Documentation

- **[CLAUDE.md](CLAUDE.md)** — Architecture, API endpoints, patterns, and development guide
- **[Documentation/FEATURE_TEMPLATE.md](Documentation/FEATURE_TEMPLATE.md)** — Template for new features

## Tech Stack

- Swift 6 + Vapor 4
- MySQL via Fluent ORM
- JWT (HMAC-SHA256) authentication
- SwiftNIO async runtime
