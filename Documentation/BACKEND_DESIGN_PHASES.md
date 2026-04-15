# Backend Design (Final Production Version)

## Overview

This system is designed for a production-grade expense sharing application.

Core principle:

> **Ledger is the source of truth. All balances are derived.**

This version includes:

* Existing auth system (Phase 0)
* Group lifecycle management (with icon)
* Expense + ledger system
* Payment identity (UPI / QR)
* User search & invite system
* Activity logs (full audit trail)
* Admin controls + permissions
* Debt simplification
* Strong consistency & edge case handling

---

# Phase 0 — Existing System (Already Implemented)

## Tables (Already in Codebase)

* users
* email_verification_otps
* refresh_tokens
* passkey_credentials
* passkey_challenges
* password_reset_otps
* email_mfa_challenges
* phone_verification_otps
* authenticator_app_setup_challenges
* backup_codes

---

## Capabilities

* Email/password authentication
* Google / Apple OAuth
* Passkey support
* MFA (email, phone, authenticator)
* Token-based sessions

---

## Notes

* Uses UUID (`CHAR(36)`) as primary keys
* Strong security model already implemented
* This layer should remain untouched

---

# 🔑 Core Financial Rule

## Money Precision

* Store all amounts as **BIGINT (paise)**

  * ₹100.00 → `10000`
* UI shows max 2 decimal places
* Never use FLOAT/DOUBLE

---

## Split Logic (Critical)

Example: ₹100 / 3

### Steps

1. Convert:

```
10000 / 3 = 3333.33...
```

2. Base split:

```
3333, 3333, 3333
```

3. Remainder:

```
1 paise
```

4. Distribute remainder

### Final:

```
33.34, 33.33, 33.33
```

---

## Distribution Strategy

### ✅ Deterministic (Recommended)

* Sort users (user_id / join order)
* Assign extra paise to first N users

### ⚠️ Optional

* Shuffle once and persist order

### ❌ Avoid

* Random every time (breaks trust)

---

## Edge Cases

* ₹0.01 split across many users
* Re-edit must produce same split
* Large groups (performance)

---

# Phase 1 — Groups & Membership

## Tables

### groups

* id
* name
* icon_url ✅
* created_by
* simplify_debts_enabled BOOLEAN
* allow_member_edit BOOLEAN DEFAULT true
* allow_member_delete BOOLEAN DEFAULT true
* created_at

---

### group_members

* id
* group_id
* user_id
* role ENUM('admin','member')
* status ENUM('active','left','removed')
* joined_at
* left_at

---

## Features

* Group icon upload/update
* Group rename
* Member management

---

## Rules

* Users can be added anytime
* Users can leave only if balance = 0
* At least one admin must exist

---

## Edge Cases

* Last admin cannot leave
* Rejoining user allowed
* Removed users remain in history

---

# Phase 2 — Expenses & Splits

## Tables

### expenses

* id
* group_id
* paid_by
* amount
* currency
* title
* notes
* created_at
* updated_at
* deleted_at

---

### expense_splits

* id
* expense_id
* user_id
* amount

---

## Rules

* Sum of splits = total
* Only group members allowed

---

## Edit Strategy (CRITICAL)

Never mutate:

1. Soft delete old expense
2. Create new expense
3. Recreate splits
4. Recreate ledger

---

## Edge Cases

* Editing after settlement
* Removing participants
* Duplicate entries
* Changing payer

---

# Phase 3 — Ledger (Core Engine)

## Table

### ledger_entries

* id
* group_id
* user_id
* amount
* reference_type
* reference_id
* created_at

---

## Rules

* Append-only
* Never update/delete
* Group sum must always be 0

---

# Phase 4 — Payments

## Table

### payments

* id
* group_id
* payer_id
* receiver_id
* amount
* created_at
* reversed_at

---

## Rules

* Payments offset debts
* Never delete → only reverse

---

# Phase 5 — Payment Identity (UPI / QR)

## Table

### user_payment_identity

* user_id (PK)
* upi_id
* qr_url
* updated_at

---

## Rules

* One per user
* Editable / deletable
* At least one required

---

# Phase 6 — User Search & Invite System

## Table

### group_invites

* id
* group_id
* invited_by
* invitee_contact
* invite_token
* status
* expires_at
* created_at

---

## Flow

### Existing user

* Add directly

### New user

1. Create invite
2. Send link
3. Signup → auto join

---

# Phase 7 — Activity Log (Audit System)

## Table

### group_activities

* id
* group_id
* actor_id
* type
* reference_id
* metadata
* created_at

---

# Phase 8 — Admin Controls & Permissions

## Features

* Promote/demote admin
* Toggle simplify debts
* Control member edit/delete

---

# Phase 9 — Balance & Settlement

* Compute net balance
* Block exit if balance ≠ 0

---

# Phase 10 — Simplify Debts

* Reduce transactions
* Admin controlled
* UI only

---

# Phase 11 — Derived Balances

* Cached balances
* Recomputed from ledger

---

# Phase 12 — Concurrency & Idempotency

* Transactions everywhere
* Prevent duplicate operations

---

# Final Architecture

Users
↓
Group Members
↓
Expenses → Splits
↓
Ledger Entries
↓
Payments
↓
Activity Logs
↓
Simplified Debts
↓
Balances
↓
Payment Identity

---

# Final Note

If you get these right:

1. Ledger correctness
2. Split precision
3. Transaction safety

→ Your system will scale and be trusted.

If you get them wrong:

→ Users will stop trusting your app.
