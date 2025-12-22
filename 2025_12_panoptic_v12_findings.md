_Note: Not all issues are guaranteed to be correct._

# Transfer allows collateral escape while netBorrows remain on account
- Severity: High

## Targets
- transfer (CollateralTracker)

## Description

The transfer (and transferFrom) implementation in CollateralTracker only accrues interest for the sender and checks that the sender has zero option positions (panopticPool().numberOfLegs(sender) == 0). It does not require that the sender's netBorrows (s_interestState[sender].leftSlot) == 0 or otherwise verify account solvency or invoke the RiskEngine. It also does not update the recipient's s_interestState or borrow index on incoming transfers. Because netBorrows are tracked separately in s_interestState and are not decreased by _accrueInterest (which only burns token shares to pay owed interest), an account with positive netBorrows can transfer away its remaining ERC20 shares, leaving the debt attached to the original account while removing collateral from on-chain control. This enables undercollateralization and allows borrowers to avoid liquidation or enforcement of collateral requirements.

## Root cause

Missing validation and accounting updates in transfer: transfer only accrues interest for the sender and checks position count, but it does not (a) require netBorrows == 0 or enforce isAccountSolvent(msg.sender) prior to moving shares, and (b) update the recipient's interest state or borrow index. The contract assumes preventing transfers while positions exist is sufficient, but borrows are tracked separately and never checked here.

## Impact

High — enables borrowers to remove on-chain collateral while leaving borrow liabilities on their account, creating undercollateralized positions, enabling escape from liquidation, and risking protocol losses.

---

# Off-by-one calldata indexing in hasNoDuplicateTokenIds — last element never checked
- Severity: High

## Targets
- hasNoDuplicateTokenIds (PanopticMath)

## Description

The assembly loop reads TokenId elements directly from calldata using calldataload(add(offset, mul(i, 0x20))) where offset := arr.offset. In Solidity ABI the dynamic array layout places the length word at arr.offset and the first element at arr.offset + 0x20. Because the implementation never adds the initial +0x20, the first calldataload returns the array length (not element 0), subsequent loads return elements 0..n-2, and the actual last element (element n-1) is never loaded. As a result some element-pairs (for example first vs last) are never compared and duplicate TokenIds can slip through undetected.

## Root cause

Incorrect calldata indexing: the assembly code treats arr.offset as if it pointed to the first element, but arr.offset points to the length word. The element loads are missing the initial +0x20 (32-byte) offset, producing an off-by-one shift in all element reads.

## Impact

High — the function is intended to assert uniqueness of TokenIds. Because the last element (and corresponding pairwise comparisons) are omitted, callers can supply arrays containing duplicates (e.g., same TokenId as first and last) that will not be detected. Depending on how this function is used, this can enable logical failures such as duplicated processing, double-mints, or violating invariants that depend on unique TokenIds.

---

# Incorrect tuple destructuring in RiskEngine.twapEMA produces wrong TWAP
- Severity: High

## Targets
- twapEMA (RiskEngine)

## Description

RiskEngine.twapEMA calls OraclePack.getEMAs() and uses positional tuple destructuring with the wrong variable order. OraclePackLibrary.getEMAs() returns (spotEMA, fastEMA, slowEMA, eonsEMA, medianTick) (i.e. spot, fast, slow, eons, median), but twapEMA binds the return values as (int256 eonsEMA, int256 slowEMA, int256 fastEMA, , ) = oraclePack.getEMAs(); This misbinds spot->eonsEMA, fast->slowEMA, slow->fastEMA and drops the real eonsEMA. The subsequent weighted average expression (6 * fastEMA + 3 * slowEMA + eonsEMA) / 10 therefore operates on the wrong EMA components (effectively computing 6*slow + 3*fast + spot instead of 6*fast + 3*slow + eons). Widening conversions (int24 -> int256) and integer arithmetic do not mitigate the logical error.

## Root cause

Fragile positional tuple destructuring: the caller (RiskEngine.twapEMA) assumes a different return order than OraclePackLibrary.getEMAs(), causing returned EMA components to be assigned to incorrect local variables. This is a deterministic logic/ordering bug rather than an arithmetic or overflow issue.

## Impact

twapEMA returns an incorrect time-weighted price signal. Any downstream system using this TWAP for pricing, risk metrics, margin calculations, or liquidation decisions will operate on wrong data. Consequences include mispriced assets, incorrect margin requirements, wrongful or missed liquidations, and broader economic distortion. While not a direct memory/safety exploit, the incorrect TWAP can be economically harmful and may be leveraged by adversaries who can influence underlying EMAs or act around predictable price signal errors.

---

# Insolvency branch in _accrueInterest leaves per-user borrow index stale, causing repeated interest charging and accounting desynchronization
- Severity: Medium

## Targets
- _accrueInterest (CollateralTracker)

## Description

In CollateralTracker::_accrueInterest the insolvency handling path (when computed shares to cover interest exceed the user's token balance and isDeposit == false) burns the user's remaining balance/shares but writes the user's stored borrow index (rightSlot) back as the old value instead of advancing it to the current global borrow index used to compute that partial payment. netBorrows is also left unchanged. Because owed interest is computed from netBorrows × (currentBorrowIndex - storedIndex), leaving the stored index stale causes the same interest delta (or a portion of it) to be recomputed and attempted to be charged again on each subsequent accrual. This produces persistent, repeating interest charges for insolvent users and desynchronizes per-user state from global interest state.

## Root cause

A logic error in the insolvency branch of _accrueInterest: after burning a user's remaining shares/balance, the code assigns the per-user borrow index from userState.rightSlot() (the pre-existing/stale value) rather than setting it to currentBorrowIndex (or otherwise marking the interest as accounted). The function also neglects to reconcile netBorrows for the principal in that path. These operations leave per-user bookkeeping stale while the global unrealized interest is adjusted.

## Impact

High for affected accounts and a protocol accounting integrity issue. Specific consequences:  
- Repeated overcharging: partially-paid interest (because of insufficient balance) is recalculated and charged again on every subsequent accrual, which can repeatedly drain collateral when users later regain balance.  
- Persistent owed-entry: insolvent positions remain recorded as owing the same interest indefinitely (no progress in stored index or netBorrows), causing noisy/repeated InsolvencyPenaltyApplied events and wasted gas.  
- Global vs user mismatch: global unrealized interest is reduced when partial payments occur but per-user stored index still implies the interest is outstanding, breaking invariants and causing reconciliation mismatches between totalAssets/totalSupply conversions.  
- UX/operational harm: users may be driven to insolvent states unexpectedly, reporting/metrics will be incorrect, and liquidation or transfer flows that rely on synchronized indices can misbehave or revert.  
- Exploitability: no privileged access required — normal accrual flow and repeated triggering of the insolvency branch (e.g., via transfers, transferFrom, or other operations that call _accrueInterest) can cause the condition to persist and be exploited to drain balances or create accounting inconsistencies.

---

# Addition-based packing of 2-bit riskPartner can carry into adjacent fields
- Severity: Low

## Targets
- addRiskPartner (TokenIdLibrary)

## Description

The function addRiskPartner encodes a 2-bit riskPartner value by arithmetic addition into a packed TokenId word at shift = 64 + legIndex*48 + 10. Because it uses '+' on the whole 256-bit word rather than clearing the target 2-bit slot and OR-ing the new value, writing into a slot that already contains a non-zero 2-bit value can overflow that 2-bit field (sum >= 4), producing a carry into higher bits and corrupting adjacent packed fields (notably the least-significant bits of the strike field located at shift + 12). addLeg constructs the leg by calling several add* functions sequentially (optionRatio, asset, isLong, tokenType, addRiskPartner, strike, width) without first clearing the slot, so the TokenId argument passed to addRiskPartner may already contain previously-set bits for the same leg, making this carry-prone addition exploitable in normal library usage.

## Root cause

Use of arithmetic addition to write packed subfields instead of masking out the previous value and OR-ing in the new bits. addRiskPartner writes (existing_word + (value << shift)) rather than performing: cleared = existing_word & ~(mask << shift); return cleared | (value << shift).

## Impact

- Corruption of adjacent packed fields (e.g., strike) due to carries from the 2-bit riskPartner addition. This can produce invalid or mutated TokenIds.
- Validation failures or unintended behavior: corrupted fields can trigger validate() reverts or cause tokens to be interpreted incorrectly by downstream logic.
- Data integrity and uniqueness issues: bit corruption can break invariants (e.g., reciprocal riskPartner checks, unique chunk identifiers), potentially causing denial-of-service (reverts) or incorrect acceptance/rejection of tokens.
- Potential for attacker or caller to craft inputs that intentionally produce carries and corrupt neighboring fields if library helpers are invoked on non-zero TokenIds, leading to subtle logic bugs in protocols that rely on packed token encoding.

---

# dispatchFrom discards updated OraclePack from _validateSolvency, leaving s_oraclePack stale
- Severity: Low

## Targets
- dispatchFrom (PanopticPool)

## Description

The PanopticPool.dispatchFrom function calls the internal view helper _validateSolvency, which in turn queries riskEngine.getSolvencyTicks(...) and may return a fresh OraclePack containing an updated oracle snapshot (ticks, timestamp, etc.). Because _validateSolvency is declared view it does not and cannot persist state; callers are expected to capture and store any non-zero OraclePack returned. dispatchFrom invokes _validateSolvency but ignores its return value and does not write the updated OraclePack into the persistent s_oraclePack. Other call paths (dispatch, pokeOracle, initialize, lock/unlock safe mode) correctly persist returned OraclePacks. The omission in dispatchFrom therefore allows the in-transaction solvency checks to use a newer snapshot while the global s_oraclePack remains stale for subsequent transactions.

## Root cause

A coding/logic omission in dispatchFrom: it relies on a view helper to compute an updated OraclePack but fails to capture and persist that result to the contract storage variable s_oraclePack. Since _validateSolvency is view and cannot mutate storage, responsibility for persisting the fresh OraclePack lies with the caller; dispatchFrom does not fulfill that responsibility.

## Impact

State inconsistency between the per-call oracle used for immediate solvency checks and the canonical on-chain oracle state (s_oraclePack). Concretely, if getSolvencyTicks produces a non-zero OraclePack, dispatchFrom will perform its internal checks using the fresh snapshot but will not persist it. Subsequent transactions and external readers that rely on s_oraclePack will continue using stale oracle data until another function updates it. An attacker able to observe or influence timings can exploit this discrepancy to:  
- Cause or avoid liquidations by manipulating which oracle snapshot future transactions see, potentially extracting funds or preventing rightful liquidations.  
- Exercise, settle, or transfer positions under stale risk assumptions, enabling arbitrage or unexpected losses.  
- Create denial-of-service or race conditions where expected risk checks fail to trigger because the global oracle remains stale.  
Overall severity: High — stale risk state persisting across transactions can lead to incorrect enforcement of margin/liquidation rules and financial loss.