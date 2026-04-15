# Backend Design (MySQL) — With Admin Controls & Indexing

## Overview

This system is designed around a strict financial principle:

> **Ledger is the source of truth. Never mutate financial history blindly.**

This version includes:

* Admin-level controls for editing/deleting entries
* Safe handling of edge cases
* Optimized indexing for performance

---

# Phase 0 — Existing Foundation

Already implemented:

* Users
* Authentication (OAuth, OTP, MFA, passkeys)

✅ No changes required

---

# Phase 1 — Groups System

## Tables

### groups

* id (PK)
* name
* created_by (FK → users.id)
* created_at

### group_members

* id (PK)
* group_id (FK)
* user_id (FK)
* role ENUM('admin','member')
* joined_at
* left_at (nullable)

### Indexes

```sql
CREATE UNIQUE INDEX uq_group_user ON group_members(group_id, user_id);
CREATE INDEX idx_group_members_user ON group_members(user_id);
```

---

## Admin Rules

* Only admins can:

  * Delete group
  * Remove members
  * Edit group name

---

## Edge Cases

* Admin leaves group → promote another admin
* Last admin cannot leave without transfer
* User leaves with pending balance → restrict or warn

---

# Phase 2 — Expenses & Splits

## Tables

### expenses

* id (PK)
* group_id
* paid_by
* amount (BIGINT)
* currency
* title
* notes
* created_at
* updated_at
* deleted_at

### expense_splits

* id (PK)
* expense_id
* user_id
* amount

---

## Indexes

```sql
CREATE INDEX idx_expenses_group ON expenses(group_id);
CREATE INDEX idx_expenses_paid_by ON expenses(paid_by);
CREATE INDEX idx_expenses_created_at ON expenses(created_at);

CREATE UNIQUE INDEX uq_expense_user ON expense_splits(expense_id, user_id);
CREATE INDEX idx_splits_user ON expense_splits(user_id);
```

---

## Admin Capabilities

Admins can:

* Edit any expense
* Delete any expense

---

## Safe Edit Strategy (VERY IMPORTANT)

Never directly modify financial data.

### Instead:

1. Soft delete old expense (`deleted_at`)
2. Insert new expense
3. Recreate splits
4. Recreate ledger entries

---

## Edge Cases

* Editing after partial payment → must rebalance ledger
* Removing a participant → adjust balances
* Changing payer → full recalculation
* Split mismatch → reject request

---

# Phase 3 — Ledger System

## Table

### ledger_entries

* id (PK)
* group_id
* user_id
* amount (BIGINT)
* reference_type ENUM('expense','payment')
* reference_id
* created_at

---

## Indexes

```sql
CREATE INDEX idx_ledger_group_user ON ledger_entries(group_id, user_id);
CREATE INDEX idx_ledger_reference ON ledger_entries(reference_type, reference_id);
CREATE INDEX idx_ledger_group ON ledger_entries(group_id);
```

---

## Rules

* Append-only (no updates/deletes)
* Every expense/payment must generate ledger entries
* Sum of ledger per group should always equal zero

---

## Admin Controls

Admins can:

* Reverse entries (not delete)

### Reversal Strategy

* Insert opposite ledger entries
* Mark original reference as reversed

---

## Edge Cases

* Duplicate ledger entries → use transactions + idempotency
* Ledger imbalance → trigger reconciliation job

---

# Phase 4 — Payments

## Table

### payments

* id (PK)
* group_id
* payer_id
* receiver_id
* amount (BIGINT)
* note
* created_at
* reversed_at (nullable)

---

## Indexes

```sql
CREATE INDEX idx_payments_group ON payments(group_id);
CREATE INDEX idx_payments_payer ON payments(payer_id);
CREATE INDEX idx_payments_receiver ON payments(receiver_id);
```

---

## Admin Capabilities

Admins can:

* Reverse payments (not delete)

---

## Edge Cases

* Partial payments
* Overpayment
* Duplicate payments (use idempotency)
* Reversal after multiple linked expenses

---

# Phase 5 — UPI Sharing

## Tables

### user_payment_methods

* id (PK)
* user_id
* type ENUM('upi_id','upi_qr')
* upi_id
* qr_url
* is_primary
* created_at

---

### group_payment_visibility (optional)

* id (PK)
* group_id
* user_id
* payment_method_id
* visible

---

## Indexes

```sql
CREATE INDEX idx_payment_methods_user ON user_payment_methods(user_id);
CREATE INDEX idx_group_payment_visibility_group ON group_payment_visibility(group_id);
```

---

## Rules

* No payment verification
* Metadata only

---

## Edge Cases

* Invalid UPI
* Multiple primary methods (prevent via constraint)
* Deleted QR but cached in UI

---

# Phase 6 — Derived Balances

## Table

### group_balances

* id (PK)
* group_id
* user_id
* balance
* updated_at

---

## Indexes

```sql
CREATE UNIQUE INDEX uq_group_balance ON group_balances(group_id, user_id);
CREATE INDEX idx_group_balance_group ON group_balances(group_id);
```

---

## Strategy

* Updated on:

  * expense creation/edit/delete
  * payment

---

## Safety

### Reconciliation Job

Run periodically:

```sql
SELECT user_id, SUM(amount)
FROM ledger_entries
WHERE group_id = ?
GROUP BY user_id;
```

Compare with stored balances.

---

# Phase 7 — Concurrency & Idempotency

## Table

### idempotency_keys

* key (PK)
* user_id
* request_hash
* created_at

---

## Indexes

```sql
CREATE INDEX idx_idempotency_user ON idempotency_keys(user_id);
```

---

## Rules

* Every write operation must:

  * Use transaction
  * Include idempotency key

---

## Edge Cases

* Double API calls
* Retry after timeout
* Parallel edits

---

# Admin-Specific Features Summary

Admins can:

* Edit/delete expenses (via safe replacement)
* Reverse payments
* Manage group members
* Resolve disputes

Admins cannot:

* Directly modify ledger entries
* Delete financial history

---

# Performance Strategy

## Key Optimizations

1. Index-heavy reads:

   * group_id
   * user_id
   * created_at

2. Avoid full table scans:

   * Always filter by group_id

3. Use pagination:

   * Expenses list
   * Activity feed

4. Add caching later:

   * Redis for balances

---

# Critical Design Principles

## 1. Ledger Integrity > Feature Speed

## 2. No Direct Mutations

All edits = new entries

## 3. Strong Consistency

Use DB transactions everywhere

## 4. Derived Data is Replaceable

Balances can be recalculated anytime

---

# Biggest Risks

* Editing expenses after payments
* Ledger inconsistency
* Concurrency bugs
* Silent balance drift

---

# Final Architecture

```text
Users
  ↓
Groups → Expenses → Splits
                   ↓
              Ledger Entries (truth)
                   ↓
             Group Balances (cache)
                   ↓
        UPI Methods (metadata only)
```

---

# Recommended Next Steps

1. Implement ledger + expense flow with transactions
2. Add admin edit/reversal logic
3. Build reconciliation job early
4. Add indexes before scaling

---

# Final Note

If ledger correctness is maintained:

* System is reliable
* Bugs are recoverable

If ledger breaks:

* Data becomes untrustworthy

Design everything around protecting it.
