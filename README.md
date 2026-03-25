# merit-badge

Verifiable on-chain skill credentials, issued by registered authorities and held by individuals.

## What This Is

`merit-badge` is a lightweight credentialing registry for protocols that need to gate access, assign roles, or signal competency without relying on off-chain identity systems. Credential issuers register as authorities; authorities issue, renew, and revoke badges; badge-holders use them as on-chain proof of qualification.

It deliberately avoids staking and treasury mechanics — the contract is purely a credentialing ledger. External contracts can read from it to enforce role-based access.

---

## Core Concepts

**Authority** — An approved issuer. Registered by the contract deployer. Maintains a quota of how many badges it may issue per epoch.

**Badge Type** — A named credential category owned by an authority. Has optional expiry duration.

**Issuance** — An authority assigns a specific badge type to a principal. The record stores issue-height and computed expiry.

**Revocation** — Authorities can revoke their own issuances. Revoked badges remain in the ledger for audit purposes but fail validity checks.

---

## Architecture

```
authorities       principal → name, quota-per-epoch, issued-this-epoch, epoch-start, active
badge-types       (authority, type-id) → name, expiry-blocks, transferable
issuances         (holder, authority, type-id) → issued-at, expires-at, revoked
```

The two-level key on `issuances` means a holder can accumulate badges from multiple authorities.

---

## Function Descriptions

### Deployer Functions

| Function | Description |
|---|---|
| `register-authority(principal, name, quota)` | Approve a new badge issuer with a per-epoch quota |
| `deactivate-authority(principal)` | Suspend an authority's issuing capability |

### Authority Functions

| Function | Description |
|---|---|
| `define-badge-type(type-id, name, expiry-blocks)` | Create a new badge category under this authority |
| `issue-badge(recipient, type-id)` | Grant a badge; respects quota and epoch tracking |
| `revoke-badge(holder, type-id)` | Mark an existing issuance as revoked |
| `reset-epoch()` | Advance epoch and reset issued-this-epoch counter |

### Query Functions

| Function | Description |
|---|---|
| `check-badge(holder, authority, type-id)` | Returns true only if badge exists, is not revoked, and hasn't expired |
| `get-issuance(holder, authority, type-id)` | Full issuance record |
| `get-authority(principal)` | Authority profile |
| `get-badge-type(authority, type-id)` | Badge type definition |

---

## Example Usage

```clarity
;; Deployer registers an authority
(contract-call? .merit-badge register-authority
    'SPISSUER...
    u"Clarity Certification Board"
    u100)

;; Authority defines a badge type (valid for ~1 year)
(contract-call? .merit-badge define-badge-type u1 u"Clarity Developer" u52560)

;; Authority issues badge to a developer
(contract-call? .merit-badge issue-badge 'SPDEVELOPER... u1)

;; External contract gates access
(asserts! (contract-call? .merit-badge check-badge caller 'SPISSUER... u1) ERR-NOT-CERTIFIED)
```

---

## Integration Pattern

Any Clarity contract can use `merit-badge` as a gating oracle:

```clarity
(define-private (is-certified (who principal))
    (contract-call? .merit-badge check-badge who CERTIFICATION-AUTHORITY BADGE-TYPE-ID)
)
```

---

## Design Decisions

- Issuances are keyed by `(holder, authority, type-id)` — one badge per type per authority per holder. An authority cannot issue the same badge type twice to the same person without first revoking.
- Quota resets are explicitly triggered by the authority — this avoids block-height arithmetic in every `issue-badge` call and is simpler to reason about.
- The deployer cannot issue badges — they only administer the authority list, maintaining a separation of privilege.

---

## Security Considerations

- Only the contract deployer can register or deactivate authorities — no self-promotion
- Quota prevents a compromised authority key from mass-issuing credentials
- Revoked badges fail `check-badge` silently — external consumers don't need to handle revocation events
- Badge type expiry of `u0` means non-expiring — always valid until explicitly revoked

## Testing Notes

- Non-deployer calling `register-authority` → `ERR-ONLY-DEPLOYER` ✓
- Deactivated authority attempting `issue-badge` → `ERR-AUTH-INACTIVE` ✓
- Issuing same badge type twice to same recipient → `ERR-ALREADY-ISSUED` ✓
- Issuing beyond quota → `ERR-QUOTA-EXCEEDED` ✓
- `check-badge` on revoked issuance → `false` ✓
- `check-badge` on expired issuance (simnet block advance) → `false` ✓
- `check-badge` on non-expiring badge → `true` indefinitely ✓

## Future Improvements

- [ ] Re-activation path for deactivated authorities (separate admin function)
- [ ] Transferable badge support (currently `is-transferable` stored but not enforced)
- [ ] Authority self-service registration with deployer approval queue
- [ ] Badge renewal — extend expiry without revoke/re-issue cycle
- [ ] Multi-type batch issuance for efficiency
