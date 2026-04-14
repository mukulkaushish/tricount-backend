# Auth Module Architecture

This document describes the intended structure for the auth module in `tricount-backend`.

## Goals

- Keep route ownership small and obvious.
- Keep controllers thin and focused on HTTP transport concerns.
- Keep business logic in services.
- Keep controller-facing services aligned with route capability ownership.
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

Controllers should use `req.authServices.<capability>` rather than depending on the internal `AuthService` shape directly.

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

## Internal Workflow Structure

`AuthService` is now organized into bounded workflow files:

- `AuthService.swift`: shared dependencies, security helpers, validation helpers
- `AuthService+Session.swift`: login, registration, social sign-in, token issuance, passkey auth
- `AuthService+Account.swift`: current-user and profile/email verification flows
- `AuthService+Recovery.swift`: forgot-password and password-reset flows
- `AuthService+MFA.swift`: MFA setup, MFA login verification, phone verification, backup codes, passkey factor lifecycle

The repo still uses `AuthServices` as the controller-facing composition point, so route handlers stay stable even when internal auth workflows are reorganized.

If one workflow file starts accumulating multiple reasons to change, the next step is to extract it into a dedicated internal service type rather than growing `AuthService` again.

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
- Add new auth workflow code to the matching `AuthService+<Capability>.swift` file before touching unrelated auth files.
- Keep runtime configuration reads out of auth services; prefer `Application.runtimeConfiguration`.
- Prefer additive migrations for schema changes.
- Keep route paths stable even if internals are reorganized.

## References

- Vapor routing docs: <https://docs.vapor.codes/de/basics/routing/>
- Swift API Design Guidelines: <https://www.swift.org/documentation/api-design-guidelines/>
- Spring Boot structuring guidance: <https://docs.spring.io/spring-boot/docs/2.6.6/reference/html/using.html>
- Rails project structure and autoloading: <https://guides.rubyonrails.org/v7.0.0/autoloading_and_reloading_constants.html>
