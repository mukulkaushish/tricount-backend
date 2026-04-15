# Backend Design (Final Production Version)

## Overview

This system is designed for a production-grade expense sharing application.

Core principle:

> **Ledger is the source of truth. All balances are derived.**

---

# 🔑 Core Financial Rule (MOST IMPORTANT)

## Money Precision

* Store all amounts as **BIGINT (paise)**

  * ₹100.00 → `10000`
* UI shows 2 decimal places only
* Never use FLOAT/DOUBLE

---

## Split Logic (Critical)

Example: ₹100 / 3

### Steps

1. Convert:

   ```
   10000 / 3 = 3333.33...
   ```

2. Floor:

   ```
   3333, 3333, 3333
   ```

3. Remainder:

   ```
   10000 - 9999 = 1
   ```

4. Distribute remainder:

### Final:

```
33.34, 33.33, 33.33
```

---

## Distribution Strategy

### ✅ Recommended (Deterministic)

* Sort users (by user_id or join order)
* Assign extra paise to first N users

### ⚠️ Optional (Pseudo-random)

* Shuffle users once per expense
* Store order (important for consistency)

### ❌ Avoid

* True randomness without persistence

---

## Edge Cases

* ₹0.01 split across many users
* Very large groups (100+ users)
* Re-editing expense must produce same split

---

# Phase 0 — Existing System

Already implemented:

* Users
* Auth (OAuth, OTP, MFA, passkeys)

---

# Phase 1 — Groups & Membership

## Tables

### groups

* id
* name
* created_by
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

## Rules

* Users can be added anytime
* Users can be removed only if balance = 0
* At least one admin must exist

---

## Edge Cases

* Admin leaves → must assign another admin
* Rejoining user → reuse or create new membership
* Removed users still appear in history

---

# Phase 2 — Expenses & Splits

## Tables

### expenses

* id
* group_id
* paid_by
* amount (BIGINT)
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
* amount (BIGINT)

---

## Rules

* Sum of splits = total amount
* Only group members allowed

---

## Edge Cases

* Duplicate participants
* Payer not in group
* Editing expense after settlement
* Removing participant mid-history

---

## Edit Strategy

Never mutate:

1. Soft delete old expense
2. Create new expense
3. Recreate splits
4. Recreate ledger

---

# Phase 3 — Ledger (Core Engine)

## Table

### ledger_entries

* id
* group_id
* user_id
* amount (BIGINT)
* reference_type (expense/payment)
* reference_id
* created_at

---

## Rules

* Append-only
* Never update/delete
* Group sum must always be 0

---

## Edge Cases

* Duplicate insertion → use transactions
* Partial failures → rollback
* Ledger mismatch → reconciliation job

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

* Payments offset debt
* Never delete → only reverse

---

## Edge Cases

* Partial payments
* Overpayment
* Duplicate payment submission
* Payment reversal after multiple splits

---

# Phase 5 — Payment Identity (UPI / QR)

## Design

👉 One user = one payment identity

---

## Table

### user_payment_identity

* user_id (PK)
* upi_id (nullable)
* qr_url (nullable)
* updated_at

---

## Rules

* User can add/update/delete
* At least one of:

  * upi_id
  * qr_url

---

## Edge Cases

* Both null → delete case
* Invalid UPI → reject
* QR replaced → overwrite
* No payment identity → allowed

---

# Phase 6 — User Search & Invite System

## Table

### group_invites

* id
* group_id
* invited_by
* invitee_contact
* invite_token
* status ENUM('pending','accepted','expired')
* expires_at
* created_at

---

## Flow

### Existing User

* Add directly to group

---

### New User

1. Create invite
2. Generate link:

   ```
   /invite?token=XYZ
   ```
3. Send via WhatsApp/SMS/Email

---

### On Signup

* Validate contact
* Add to group
* Mark invite accepted

---

## Edge Cases

* Duplicate invites
* Expired token
* Wrong email/phone signup
* Already joined user
* Link reuse

---

# Phase 7 — Activity Log

## Table

### group_activities

* id
* group_id
* actor_id
* type
* reference_id
* metadata (JSON)
* created_at

---

## Types

* group_created
* user_added
* user_removed
* expense_added
* expense_updated
* expense_deleted
* payment_made
* payment_reversed
* role_updated

---

## Edge Cases

* Bulk operations → log individually
* Editing expense → log both old + new
* Invite join → mark source

---

# Phase 8 — Admin Management

## Features

* Promote member → admin
* Demote admin → member

---

## Rules

* At least one admin required
* Only admins can manage roles

---

## Edge Cases

* Last admin cannot demote
* Concurrent updates → use locking
* Removed users cannot be promoted

---

# Phase 9 — Derived Balances

## Table

### group_balances

* group_id
* user_id
* balance
* updated_at

---

## Rules

* Derived from ledger
* Used for fast reads

---

## Safety

Recalculate periodically from ledger

---

# Phase 10 — Concurrency & Idempotency

## Table

### idempotency_keys

* key
* user_id
* request_hash
* created_at

---

## Rules

* All writes must be transactional
* Prevent duplicate operations

---

## Edge Cases

* Retry after timeout
* Double clicks
* Parallel requests

---

# 🧠 Hidden Edge Cases (Most People Miss)

### Financial

* Floating point drift
* Re-editing expense after payment
* Cyclic debts

---

### Membership

* User removed with pending balance
* User added after many expenses

---

### Sync

* Duplicate expense creation
* Partial DB writes

---

### Trust Issues

* Incorrect rounding
* Missing activity logs
* Silent balance mismatch

---

# Final Architecture

```text
Users
  ↓
Group Members (role + status)
  ↓
Expenses → Splits
  ↓
Ledger Entries (source of truth)
  ↓
Payments
  ↓
Activity Logs
  ↓
Group Balances (derived)
  ↓
Payment Identity (UPI/QR)
```

---

# Final Note

If you get these 3 right:

1. Ledger correctness
2. Split precision
3. Transaction safety

→ Your system will be solid.

If you get them wrong:

→ Users will stop trusting your app.

Design everything to protect correctness.
