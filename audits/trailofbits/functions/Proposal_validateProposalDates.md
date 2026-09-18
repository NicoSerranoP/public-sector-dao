# `_validateProposalDates(uint64,uint64)` — `src/base/Proposal.sol` L388-431

## Summary

Internal `view` helper called once, from `createProposal` (`src/base/Proposal.sol:301`), to turn the
caller-supplied `_startDate`/`_endDate` (each may be `0` to request a default) into a concrete
`(startDate, endDate)` pair for a new proposal, enforcing that both dates sit inside a window anchored on
`block.timestamp` and sized by the plugin's `votingSettings` (`minDuration`, `maxBoundDate`). It performs no
state writes; it only reads `block.timestamp` and the storage variable `votingSettings` (declared in
`src/base/Settings.sol:36`), and it either returns two `uint64` values or reverts.

```solidity
function _validateProposalDates(uint64 _start, uint64 _end)
    internal
    view
    virtual
    returns (uint64 startDate, uint64 endDate)
```

## Caller

`createProposal` (`src/base/Proposal.sol:271-337`) calls it at line 301:

```solidity
(_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);
```

and then stores the *returned* values verbatim into `proposal_.parameters.startDate` /
`proposal_.parameters.endDate` (lines 312-313), and emits them in `ProposalCreated` (line 336, via
`_emitProposalCreatedEvent`). Nothing after line 301 re-validates the dates — `createProposal` treats a
non-reverting return from this function as proof that the pair is well-formed and within policy. Both
`createProposal` overloads route through this single internal function (the 5-arg overload at line 271 is
the one that actually calls it; the `IProposal`-shaped overload at line 352-367 forwards into the 5-arg one).

## Step-by-step walkthrough

### 1. Snapshot "now" (L394)

```solidity
uint64 currentTimestamp = block.timestamp.toUint64();
```

`SafeCastUpgradeable.toUint64` (`lib/openzeppelin-contracts-upgradeable/contracts/utils/math/SafeCastUpgradeable.sol:426-429`)
is `require(value <= type(uint64).max, ...)` then a cast — it can only revert if `block.timestamp` itself
exceeds `type(uint64).max` (~5.8×10^11 seconds past epoch, i.e. not reachable on any real chain for a very
long time). For all practical purposes `currentTimestamp == block.timestamp`.

### 2. Resolve `startDate` (L396-408)

- **`_start == 0`** (L396-397): `startDate = currentTimestamp`. No further bound is applied to this branch —
  by construction it equals "now", so it is trivially within any window that requires `startDate >= now`.
- **`_start != 0`** (L398-408): `startDate = _start` (L399), then two checked bounds against `now`:
  - L401-403: `startDate < currentTimestamp` → revert `DateOutOfBounds(limit: currentTimestamp, actual: startDate)`.
    This is the *only* place `startDate` is bounded below by `block.timestamp`; it forbids a start strictly in
    the past but allows `startDate == currentTimestamp` exactly.
  - L405-407: `startDate > currentTimestamp + votingSettings.maxBoundDate` → revert `DateOutOfBounds(limit:
    currentTimestamp + votingSettings.maxBoundDate, actual: startDate)`. This bounds `startDate` above,
    relative to `now`, by `maxBoundDate` — i.e. it bounds `startDate - block.timestamp`, not any
    end-minus-start duration.

  Net effect of this branch: `currentTimestamp <= startDate <= currentTimestamp + maxBoundDate`. The addition
  `currentTimestamp + votingSettings.maxBoundDate` is evaluated twice (once in the `if`, once again inside the
  revert's `limit:` argument) — both under Solidity 0.8's default checked-arithmetic mode (no `unchecked`
  wraps this function), so if the sum overflows `uint64` the first evaluation (the `if` condition) reverts
  with a `Panic(0x11)` before the custom `DateOutOfBounds` is ever constructed.

### 3. Compute the minimum end date (L410-413)

```solidity
// Since `minDuration` is limited to 1 year,
// `startDate + minDuration` can only overflow if the `startDate` is after `type(uint64).max - minDuration`.
// In this case with Solidity 0.8+ overflow checks, the proposal creation will revert and another date can be picked.
uint64 earliestEndDate = startDate + votingSettings.minDuration;
```

This line runs unconditionally (for both the `_end == 0` and `_end != 0` cases below).

- **Overflow-safety claim, checked against 0.8 semantics**: the arithmetic conclusion is correct — `+` on two
  `uint64` operands with no surrounding `unchecked{}` block is checked in Solidity ^0.8.8, so if
  `startDate + votingSettings.minDuration > type(uint64).max` the statement reverts (Panic 0x11) rather than
  wrapping; it cannot silently produce a too-small `earliestEndDate`. Nothing is corrupted by an overflow here.
- **The comment's premise is not established by any code found**: "`minDuration` is limited to 1 year" is not
  enforced anywhere. `Settings._updateVotingSettings` only requires `minDuration >= 60 minutes`
  (`src/base/Settings.sol:132-134`) and `minDuration <= maxBoundDate` (`src/base/Settings.sol:136-138`);
  `maxBoundDate` itself has no upper bound anywhere in `_updateVotingSettings` (no `MAX_..._RATIO`-style cap
  exists for it — contrast with the explicit `MAX_GOVERNANCE_RATIO` cap applied to `minParticipation` and
  `minApprovals`, `src/base/Settings.sol:33,128-129,142-143`). So `minDuration` can be configured up to
  `type(uint64).max` (bounded only by whatever `maxBoundDate` the same call sets). Grepped the whole `src/`
  tree for `365 days` / a duration cap constant — none exists. The overflow-revert behavior the comment
  predicts is real and does not depend on the false "1 year" premise (it is true for *any* `minDuration`
  value, checked arithmetic reverts on overflow regardless of operand size); the practical consequence is that
  with a large enough `minDuration`/`maxBoundDate` configured by governance, ordinary (non-adversarial)
  `startDate` values close to `block.timestamp` could already be within overflow range of `type(uint64).max`,
  turning proposal creation into an unconditional revert until settings are changed again.

### 4. Resolve `endDate` (L415-430)

- **`_end == 0`** (L415-416): `endDate = earliestEndDate` (`startDate + minDuration`). No independent ceiling
  check is applied to `endDate` in this branch — the `latestEndDate` check at L425-429 is only inside the
  `else`. The absence of an explicit ceiling here is not itself a live gap only because of an invariant
  established elsewhere (see Invariants, below): `Settings._updateVotingSettings` guarantees
  `minDuration <= maxBoundDate` (`src/base/Settings.sol:136-138`) for every value `votingSettings` can ever
  hold (the only write site is `src/base/Settings.sol:162`, gated by that check — confirmed by grep, no other
  assignment to `votingSettings` exists in `src/`). Given that invariant, `startDate + minDuration <= startDate
  + maxBoundDate`, so the default `endDate` can never exceed what the explicit ceiling in the other branch
  would have allowed — but this is a fact this function relies on being true of `votingSettings`, not
  something it re-derives itself.
- **`_end != 0`** (L417-430): `endDate = _end` (L418), then:
  - L420-422: `endDate < earliestEndDate` → revert `DateOutOfBounds(limit: earliestEndDate, actual: endDate)`.
    Enforces a *minimum duration* of `minDuration` (lower bound on `endDate - startDate`).
  - L424-429: `uint64 latestEndDate = startDate + votingSettings.maxBoundDate;` then `endDate > latestEndDate`
    → revert `DateOutOfBounds(limit: latestEndDate, actual: endDate)`. This bounds `endDate - startDate` above
    by `maxBoundDate` — i.e. it bounds the *duration*, reusing the same `maxBoundDate` field that, in step 2,
    bounded `startDate - block.timestamp` (the *offset*). Both quantities are capped by the identical
    constant, but they are different quantities; the comment at L424 ("Mirrors the configurable ceiling
    already enforced on `minDuration` in `Settings`") documents the reuse but the two ceilings (offset-from-now
    for `startDate`, and duration for `endDate - startDate`) are independent and additive: in the worst case
    (`startDate` pushed all the way to `currentTimestamp + maxBoundDate`, then `endDate` pushed all the way to
    `startDate + maxBoundDate`), `endDate` can reach `currentTimestamp + 2 * maxBoundDate` — `maxBoundDate`
    alone does not bound how far `endDate` can be from `block.timestamp`, only from `startDate` and from `now`
    separately.
  - The `startDate + votingSettings.maxBoundDate` addition at L425 is checked (0.8 default); it reverts with a
    Panic if it overflows rather than silently wrapping into a small `latestEndDate` that would then wrongly
    reject valid `endDate`s (fail-closed, not fail-open, if it were ever to overflow).

## Invariants

- **`endDate > startDate` on every non-reverting return.** Established by: `earliestEndDate = startDate +
  votingSettings.minDuration` (L413) together with `minDuration >= 60 minutes` guaranteed by
  `Settings._updateVotingSettings` (`src/base/Settings.sol:132-134`, the only write path to `votingSettings`),
  so `earliestEndDate > startDate` strictly; and both the `_end == 0` branch (`endDate = earliestEndDate`,
  L416) and the `_end != 0` branch (`endDate >= earliestEndDate` enforced at L420-422) can only produce
  `endDate >= earliestEndDate > startDate`. This is depended on by `_isProposalOpen`
  (`src/base/Proposal.sol:251-256`), whose openness window `startDate <= currentTime < endDate` would be
  permanently false (proposal never open) if `endDate <= startDate` were possible.
- **`currentTimestamp <= startDate <= currentTimestamp + maxBoundDate`** whenever `_start != 0` (established
  by L401-407 in this function); when `_start == 0`, `startDate == currentTimestamp` exactly (L397), which is
  the tightest possible instance of the same bound.
- **`startDate < endDate <= startDate + maxBoundDate`** whenever `_end != 0` (L420-429, this function).
- **`votingSettings.minDuration <= votingSettings.maxBoundDate`** at the time this function reads
  `votingSettings` — this is an invariant of `Settings`, not of this function; established at every write of
  `votingSettings` by `Settings._updateVotingSettings:136-138`, and this function's `_end == 0` branch (no
  independent ceiling check on the default `endDate`) relies on it without re-verifying it.
- **`votingSettings.minDuration >= 60 minutes` (hence `> 0`)** — established by
  `Settings._updateVotingSettings:132-134`; relied on for the strict `endDate > startDate` invariant above.

## Assumptions (and what establishes or fails to establish them)

- **Assumption: `votingSettings.maxBoundDate` is small enough that `currentTimestamp + maxBoundDate` and
  `startDate + maxBoundDate` do not overflow `uint64`.** Nothing in `Settings._updateVotingSettings`
  (`src/base/Settings.sol:119-173`) enforces an upper bound on `maxBoundDate` — the only constraint tying it
  to anything is `minDuration <= maxBoundDate` (a lower bound on `maxBoundDate`, not an upper one). If this
  assumption is violated by a governance-set `maxBoundDate` close to `type(uint64).max`, the additions at
  L405, L406, L413 (for large `minDuration`) and L425 revert via `Panic(0x11)` rather than the custom
  `DateOutOfBounds`/`MinDurationOutOfBounds` errors — the function still fails closed (no dates are produced,
  no state is written), but the caller-facing revert reason changes and, depending on how large the
  misconfigured value is, proposal creation could become permanently impossible until settings are corrected.
- **Assumption: `minDuration` is bounded to a "reasonable" value (comment says "1 year").** Not established by
  any code found in `src/` — see step 3 above. The only actual ceiling on `minDuration` is
  `maxBoundDate`, which is itself unbounded.
- **Assumption depended on by the `_end == 0` branch: `minDuration <= maxBoundDate` always holds for the
  currently stored `votingSettings`.** Established by `Settings._updateVotingSettings:136-138` for every value
  `votingSettings` is ever assigned (single write site, `src/base/Settings.sol:162`, confirmed by repo-wide
  grep for `votingSettings\s*=`). This function does not re-check the relationship itself; it is a pure
  consumer of the invariant.
- **Assumption: `block.timestamp` fits in `uint64`.** Established (as a revert-if-not, not a silent
  truncation) by `SafeCastUpgradeable.toUint64` at L394 — see step 1.

## Callees

- **`block.timestamp.toUint64()`** (`SafeCastUpgradeable.toUint64`,
  `lib/openzeppelin-contracts-upgradeable/contracts/utils/math/SafeCastUpgradeable.sol:426-429`). Source
  available. Single path: `require(value <= type(uint64).max)` then cast. No path returns an unchecked/silently
  truncated value; the only failure mode is a `require` revert, which is unreachable in practice given current
  and near-future `block.timestamp` magnitudes. Relied upon only to make `currentTimestamp` a `uint64` safely.
- **`votingSettings` (storage read)**, populated exclusively via `Settings._updateVotingSettings`
  (`src/base/Settings.sol:119-173`), which this function relies on (without re-checking) for: `minDuration >=
  60 minutes` (L132-134) and `minDuration <= maxBoundDate` (L136-138). Walked all paths through
  `_updateVotingSettings`: every path either reverts before reaching L162 (`RatioOutOfBounds` for
  `supportThreshold`/`minParticipation`/`minApprovals` out of range, `MinDurationOutOfBounds` for the two
  duration checks, or `RatioOutOfBounds` for the post-initialization `minProposerVotingPower` check gated by
  `votingSettings.maxBoundDate != 0` at L147) or falls through to the single assignment at L162 with all five
  checks above satisfied. There is no path that assigns `votingSettings` without having passed the
  `minDuration`/`maxBoundDate` checks. No cap on `maxBoundDate` itself exists on any path.

## State / side effects

None. The function is `view`; it does not write `votingSettings`, `proposals`, or any other storage, and makes
no external calls. All effects it enables happen in the caller (`createProposal`) after it returns.

## Open questions

- Is there a deployment-time or off-chain (e.g., plugin-setup / DAO governance process) constraint that keeps
  `maxBoundDate` and `minDuration` within sane bounds in practice, compensating for the absence of an on-chain
  upper-bound check in `Settings._updateVotingSettings`? Unclear from `src/`; would need to inspect the plugin
  setup contract / deployment scripts to know what values are actually reachable in a real deployment.
- Is the comment at L410-412 ("`minDuration` is limited to 1 year") a stale reference to a check that used to
  exist, or to a constraint intended to live in a different layer (e.g., a UI/SDK-level restriction) that was
  never ported to `Settings.sol`? Unclear; nothing in `src/` currently enforces it.
- Is the reuse of `maxBoundDate` for two distinct quantities (max `startDate` offset from `now`, and max
  `endDate - startDate` duration), yielding a worst-case `endDate` of `currentTimestamp + 2*maxBoundDate`,
  intentional design or an oversight of the L424 comment's "mirrors" framing? Needs a design-intent read (e.g.
  from `INFTVoting.sol`'s NatSpec on `maxBoundDate`, `src/base/INFTVoting.sol:49,128`) that only says "The
  maximum allowed offset in seconds for proposal start/end dates" — which is consistent with either a single
  shared cap or the additive worst case observed here; the doc comment doesn't disambiguate.
