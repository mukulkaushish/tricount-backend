# Auth Module Architecture

This document describes the intended structure for the auth module in `tricount-backend`.

## Goals

- Keep route ownership small and obvious.
- Keep controllers thin and focused on HTTP transport concerns.
- Keep business logic in services.
- Keep persistence logic in Fluent models and migrations.
- Preserve the public API contract while allowing the codebase to scale.

## Applied Pattern

The auth module uses a feature-oriented RouteCollection composition pattern:

- `AuthController`: module composer only
- `AuthSessionController`: public session/authentication endpoints
- `AuthMFALoginController`: public second-step MFA verification
- `AuthAccountController`: authenticated account/profile endpoints
- `AuthMFASettingsController`: authenticated MFA setup and preference endpoints
- `AuthPasskeyManagementController`: authenticated passkey enrollment and lifecycle endpoints

This structure follows two practical rules:

1. Group routes by capability, not by HTTP verb or model.
2. Treat controllers as adapters from HTTP to application services.

## Responsibility Boundaries

### Controllers

Controllers should:

- register routes
- validate request-shape concerns that are HTTP-specific
- call a single service entry point
- return DTOs or standard responses

Controllers should not:

- contain database queries beyond trivial route-parameter lookups
- build security-sensitive flows inline
- duplicate business rules already owned by a service

### Services

Services should own:

- authentication business logic
- MFA orchestration
- token issuance and rotation
- security decisions
- coordination across models and dispatchers

### Models

Models should remain persistence-focused:

- table/schema mapping
- relationships
- lightweight computed helpers tied to stored state

## Future Refactor Direction

`AuthService` still contains multiple capabilities. To keep scaling cleanly, future work should split it by bounded context:

- `AuthSessionService`
- `AuthProfileService`
- `AuthMFAService`
- `AuthRecoveryService`

When that happens, keep `Request` factories as the composition point so controllers still read clearly.

## Endpoint Ownership Map

### Public

- `AuthSessionController`
  - `/auth/login`
  - `/auth/register`
  - `/auth/forgot-password`
  - `/auth/reset-password`
  - `/auth/google`
  - `/auth/apple`
  - `/auth/refresh`

- `AuthMFALoginController`
  - `/auth/mfa/*/verify`
  - `/auth/mfa/passkeys/authenticate/*`
  - `/auth/passkeys/authenticate/*`

### Authenticated

- `AuthAccountController`
  - `/auth/me`
  - `/auth/logout`
  - `/auth/verify-profile/*`

- `AuthMFASettingsController`
  - `/auth/mfa/enable`
  - `/auth/mfa/disable`
  - `/auth/mfa/email/*`
  - `/auth/mfa/authenticator-app/*`
  - `/auth/mfa/backup-codes/*`
  - `/auth/phone/*`

- `AuthPasskeyManagementController`
  - `/auth/passkeys`
  - `/auth/passkeys/register/*`
  - `/auth/passkeys/remove`
  - `/auth/passkeys/reset`

## Design Notes

- Keep DTOs in `DTOs/` until they become large enough to justify feature folders.
- Add a new RouteCollection before expanding an existing one past a single concern.
- Prefer additive migrations for schema changes.
- Keep route paths stable even if internals are reorganized.

## References

- Vapor routing docs: <https://docs.vapor.codes/de/basics/routing/>
- Swift API Design Guidelines: <https://www.swift.org/documentation/api-design-guidelines/>
