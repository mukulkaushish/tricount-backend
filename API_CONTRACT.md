# tricount — Auth API Contract

> **Base URL:** `https://api.splitser.dev/v1`
> Replace with your actual server URL before deploying.

> **Generated route docs:** Startup writes `routes.md`, Postman collection, and HTML docs automatically. By default they go to `Generated/` in local/prod runs and `.build/generated-route-docs/` in tests. Override with `ROUTE_DOCS_OUTPUT_DIR`.

---

## Conventions

| Concern | Detail |
|---|---|
| Protocol | HTTPS only |
| Format | JSON (`Content-Type: application/json`) |
| Auth | Bearer token in `Authorization` header |
| Timestamps | ISO 8601 strings (`2024-01-15T10:30:00Z`) |
| IDs | UUID v4 strings |
| Error shape | `{ "error": "...", "message": "...", "statusCode": N }` |
| Success shape | `{ ... }` (flat JSON, no envelope) |

---

## Authentication

All protected endpoints require:

```
Authorization: Bearer <accessToken>
```

Tokens expire after **1 hour**. Use `POST /auth/refresh` to obtain a new pair.

---

## Endpoints

### 1. Sign In — Email / Password

```
POST /auth/login
```

**Request body**

```json
{
  "email": "alex@example.com",
  "password": "Secret123"
}
```

**Success — 200 OK**

```json
{
  "requiresMFA": false,
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refreshToken": "dGhpcyBpcyBhIHJlZnJlc2ggdG9rZW4...",
  "expiresIn": 3600,
  "user": {
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "displayName": "Alex Smith",
    "email": "alex@example.com",
    "avatarUrl": null,
    "isEmailVerified": false,
    "verifiedAt": null,
    "createdAt": "2024-01-15T10:30:00Z"
  },
  "mfaChallenge": null
}
```

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing or malformed fields |
| 401 | Invalid email or password |

---

### 2. Register — Email / Password

```
POST /auth/register
```

**Request body**

```json
{
  "email": "alex@example.com",
  "password": "Secret123",
  "displayName": "Alex Smith"
}
```

**Success — 201 Created**

```json
{
  "requiresMFA": false,
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refreshToken": "dGhpcyBpcyBhIHJlZnJlc2ggdG9rZW4...",
  "expiresIn": 3600,
  "user": {
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "displayName": "Alex Smith",
    "email": "alex@example.com",
    "avatarUrl": null,
    "isEmailVerified": false,
    "verifiedAt": null,
    "createdAt": "2024-01-15T10:30:00Z"
  },
  "mfaChallenge": null
}
```

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing fields / password too weak |
| 409 | Email already registered |
| 422 | Validation failure (e.g. invalid email format) |

---

### 3. Forgot Password

```
POST /auth/forgot-password
```

**Request body**

```json
{
  "email": "alex@example.com"
}
```

**Success — 200 OK**

```json
{
  "message": "If the account exists, a password reset link will be sent."
}
```

> **Implementation note:** Always return 200 even if the email is not registered
> to avoid account enumeration.
> Password reset completion / change-password flow is not part of this contract yet.

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing or invalid email |
| 429 | Too many requests |

---

### 4. Sign In — Google OAuth

```
POST /auth/google
```

**Request body**

```json
{
  "idToken": "<Google ID token obtained from google_sign_in SDK>"
}
```

**Success — 200 OK**

Same shape as `/auth/login` success response.

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing idToken |
| 401 | Invalid / expired Google token |
| 409 | Google account is already linked to another profile |

---

### 5. Refresh Token

```
POST /auth/refresh
```

**Request body**

```json
{
  "refreshToken": "dGhpcyBpcyBhIHJlZnJlc2ggdG9rZW4..."
}
```

**Success — 200 OK**

```json
{
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refreshToken": "bmV3UmVmcmVzaFRva2Vu...",
  "expiresIn": 3600
}
```

**Errors**

| Status | Scenario |
|---|---|
| 401 | Refresh token invalid or expired |

---

### 6. Sign In — Apple OAuth

```
POST /auth/apple
```

**Request body**

```json
{
  "idToken": "<Apple identity token obtained from Sign in with Apple>"
}
```

**Success — 200 OK**

Same shape as `/auth/login` success response.

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing idToken |
| 401 | Invalid / expired Apple token |
| 422 | Apple identity token does not expose an email for first-time linking |
| 409 | Apple account is already linked to another profile |

---

### 7. Get Current User 🔒

```
GET /auth/me
Authorization: Bearer <accessToken>
```

**Success — 200 OK**

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "displayName": "Alex Smith",
  "email": "alex@example.com",
  "avatarUrl": "https://storage.splitser.dev/avatars/a1b2.jpg",
  "isEmailVerified": true,
  "verifiedAt": "2024-01-15T10:45:00Z",
  "createdAt": "2024-01-15T10:30:00Z"
}
```

**Errors**

| Status | Scenario |
|---|---|
| 401 | Missing or expired token |

---

### 8. Verify Profile — Google 🔒

Use this after email/password registration to confirm that the stored email matches
the user's Google account and to link that Google identity for future sign-in.

```
POST /auth/verify-profile/google
Authorization: Bearer <accessToken>
```

**Request body**

```json
{
  "idToken": "<Google ID token obtained from google_sign_in SDK>"
}
```

**Success — 200 OK**

Returns the updated user object.

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing idToken |
| 401 | Invalid / expired access token or Google token |
| 409 | Google email does not match the stored profile email |

---

### 9. Verify Profile — Apple 🔒

Use this when the Apple account shares the same email address as the stored profile.
If Apple returns a relay address or omits the email claim, use the email OTP flow instead.

```
POST /auth/verify-profile/apple
Authorization: Bearer <accessToken>
```

**Request body**

```json
{
  "idToken": "<Apple identity token obtained from Sign in with Apple>"
}
```

**Success — 200 OK**

Returns the updated user object.

**Errors**

| Status | Scenario |
|---|---|
| 400 | Missing idToken |
| 401 | Invalid / expired access token or Apple token |
| 409 | Apple email does not match the stored profile email |
| 422 | Apple identity token does not expose an email for verification |

---

### 10. Verify Profile — Email OTP 🔒

Request a one-time code:

```
POST /auth/verify-profile/email/request-otp
Authorization: Bearer <accessToken>
```

**Success — 200 OK**

```json
{
  "message": "Verification code sent to alex@example.com."
}
```

Confirm the code:

```
POST /auth/verify-profile/email/confirm
Authorization: Bearer <accessToken>
```

**Request body**

```json
{
  "code": "123456"
}
```

**Success — 200 OK**

Returns the updated user object.

**Errors**

| Status | Scenario |
|---|---|
| 400 | Malformed code |
| 401 | Invalid or expired code |

---

### 11. Sign Out 🔒

```
POST /auth/logout
Authorization: Bearer <accessToken>
```

**Request body** — empty `{}`

**Success — 204 No Content**

> The server invalidates the refresh token. The client must delete both tokens
> and the cached user locally regardless of the response.

**Errors**

| Status | Scenario |
|---|---|
| 401 | Already signed out / invalid token (still clear client-side) |

---

## Standard Error Response

```json
{
  "error": "INVALID_CREDENTIALS",
  "message": "Invalid email or password.",
  "statusCode": 401
}
```

| Field | Type | Description |
|---|---|---|
| `error` | string | Machine-readable error code |
| `message` | string | Human-readable message (safe to display) |
| `statusCode` | integer | Mirrors the HTTP status code |

---

## User Object Reference

```json
{
  "id":          "uuid-v4",
  "displayName": "Alex Smith",
  "email":       "alex@example.com",
  "avatarUrl":   "https://... or null",
  "isEmailVerified": true,
  "verifiedAt": "2024-01-15T10:45:00Z or null",
  "createdAt":   "2024-01-15T10:30:00Z"
}
```

| Field | Nullable | Notes |
|---|---|---|
| `id` | No | UUID v4, immutable |
| `displayName` | No | 2–64 chars |
| `email` | No | Lowercased server-side |
| `avatarUrl` | Yes | Absolute HTTPS URL |
| `isEmailVerified` | No | `true` after Google, Apple, or email OTP verification |
| `verifiedAt` | Yes | First successful verification timestamp |
| `createdAt` | No | ISO 8601 |

---

## Password Policy (enforced server-side)

- Minimum **8 characters**
- At least **1 uppercase** letter
- At least **1 lowercase** letter
- At least **1 digit**
- Maximum **128 characters**

---

## Rate Limits

| Endpoint | Limit |
|---|---|
| `POST /auth/login` | Disabled |
| `POST /auth/register` | Disabled |
| `POST /auth/forgot-password` | 3 requests / hour per email |
| `POST /auth/google` | Disabled |
| `POST /auth/apple` | Disabled |
| `POST /auth/refresh` | Disabled |
| `POST /auth/verify-profile/email/request-otp` | Disabled |
| `POST /auth/verify-profile/email/confirm` | Disabled |
| All other routes | Disabled unless explicitly configured in code |

Exceeded limits return **429 Too Many Requests** with a `Retry-After` header when a custom or default policy is enabled.

---

*This contract covers Phase 2 — Auth. Group, expense, settlement and sync endpoints will be defined in subsequent phase contracts.*
