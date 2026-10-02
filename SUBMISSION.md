# Submission note

## Highest-risk defect repaired

`transferFrom` did not check the source wallet, so an approved spender could move tokens from a frozen or revoked holder. `transfer` had the same participant-policy gap. All ordinary routes now require a real, currently eligible, non-held participant, so allowance cannot bypass policy.

## Recovery design

- `recover` is `AGENT_ROLE` only and requires a non-zero unused case ID, positive amount, and distinct real wallets.
- A source may be held or ineligible; the destination must be eligible and not held. Recovery remains available while paused.
- The case is marked before the balance move; a revert rolls the marker back atomically.
- Recovery uses `_update`, preserving total supply and emitting the normal `Transfer`, followed by exactly one `RecoveryExecuted`.
- Also repaired: explicit role grants, non-zero allowlist validation, pause-aware issuance, and participant checks for redemption.

## Listener design

- Finalized height is `head - confirmations`; only `(cursor, finalized]` is processed.
- Log identity uses `(blockNumber, txHash, logIndex)`, so distinct logs are not collapsed.
- Balances, deduplication markers, and the cursor are published inside one supplied store transaction.
- Empty eligible ranges advance the cursor; failed transactions roll everything back.
- Amount accounting and formatting use bigint/string operations only, with validation of `decimals`.

## Residual risk / unfinished work

The inherited default confirmation depth remains 2 because the specification does not define another default. The listener assumes valid on-chain transfer logs, so it does not independently reject a debit that would create a negative balance. The specification is also silent on zero-amount transfers between valid participants.

## Verification

README commands
