# Backend Architecture

This document captures the project-level structure for `tricount-backend` using patterns that generalize well across Vapor, Spring Boot, and Rails.

## Goals

- Keep HTTP transport concerns separate from domain workflows.
- Centralize runtime configuration and environment parsing.
- Group code by bounded capability before files grow into cross-cutting containers.
- Favor secure production defaults with explicit local-development escape hatches.
- Keep the public API stable while allowing internals to evolve.

## Generic Patterns Applied

### 1. Root composition, feature-first modules

The app boot path should stay small:

- `entrypoint.swift` starts the app.
- `configure.swift` composes infrastructure.
- `routes.swift` wires top-level modules.

Inside the module, group by feature capability:

- `Controllers/Auth/*`
- `Services/*`
- `Models/*`
- `Migrations/*`

This follows the same broad direction used in:

- Spring Boot root-package composition and structured modules.
- Rails autoloaded project structure and namespaced classes.
- Vapor route collections and request/application services.

### 2. Typed runtime configuration

Runtime configuration is centralized in `Application+RuntimeConfiguration.swift`.

This means:

- environment variables are parsed once
- invalid values fail fast during startup
- downstream services read typed config instead of stringly typed env values
- production-only safety rules live in one place

This is the same operational idea as:

- Spring Boot externalized configuration bound into structured properties
- Rails `config.x` custom configuration
- Vapor service/config access through `Application`

### 3. Controllers depend on capability services

Controllers should talk to a capability-scoped service surface, not a giant internal service.

In this codebase, controllers now use:

- `req.authServices.session`
- `req.authServices.account`
- `req.authServices.mfaLogin`
- `req.authServices.mfaSettings`
- `req.authServices.passkeys`

That keeps route ownership aligned with service ownership and makes future internal splits safer.

### 4. Internal core services may still exist

It is acceptable to keep a broader internal service while the codebase is being migrated, as long as:

- controllers do not depend on it directly
- new code is added behind capability boundaries
- the core service is treated as an implementation detail, not a public architectural pattern

### 5. Security defaults should be explicit

The backend now treats production safety as configuration behavior, not convention:

- production rejects the default JWT secret
- production rejects `MYSQL_TLS_MODE=insecure`
- log level is centralized and explicit
- route-doc output and auth/security settings come from one runtime configuration source

## Current Module Boundaries

### App composition

- `configure.swift`: infrastructure bootstrap
- `routes.swift`: route root composition
- `Configuration/*`: app-wide infrastructure concerns

### Auth domain

- `AuthController`: module composer
- `AuthSessionController`: login/register/social/refresh/reset
- `AuthAccountController`: profile and identity verification
- `AuthMFALoginController`: second-step MFA verification
- `AuthMFASettingsController`: MFA setup and factor lifecycle
- `AuthPasskeyManagementController`: passkey enrollment and management

### Domain service access

- `AuthServices.swift` exposes capability-scoped service access for controllers
- `AuthService.swift` now holds shared auth dependencies and helpers
- `AuthService+Session.swift`, `AuthService+Account.swift`, `AuthService+Recovery.swift`, and `AuthService+MFA.swift` hold the bounded auth workflows
- `PasskeyService.swift` remains its own specialized domain service

## Scaling Rules

When a domain grows, split in this order:

1. Split the controller by capability.
2. Add a capability-scoped service interface for the controller.
3. Move shared rules into internal helpers or smaller domain services.
4. Centralize new configuration in runtime config before wiring it through features.
5. Add tests around the seam you just introduced.

## Anti-Patterns To Avoid

- Direct `Environment.get(...)` calls scattered through services.
- Controllers that query the database and make business decisions inline.
- One service type absorbing every auth, MFA, and passkey workflow forever.
- Security-sensitive defaults hidden in multiple files.
- Adding new feature files by technical layer only when the feature boundary is clearer.

## References

- [Spring Boot: Structuring Your Code](https://docs.spring.io/spring-boot/docs/2.6.6/reference/html/using.html)
- [Spring Boot: Externalized Configuration](https://docs.spring.io/spring-boot/docs/1.1.2.RELEASE/reference/html/boot-features-external-config.html)
- [Rails Guides: Configuring Rails Applications](https://guides.rubyonrails.org/v8.0.0/configuring.html)
- [Rails Guides: Autoloading and Reloading Constants](https://guides.rubyonrails.org/v7.0.0/autoloading_and_reloading_constants.html)
- [Vapor Docs: Validation](https://docs.vapor.codes/basics/validation/)
- [Vapor Docs: Upgrading to Vapor 4](https://docs.vapor.codes/nl/upgrading/)
