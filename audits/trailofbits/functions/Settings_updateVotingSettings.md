## `_updateVotingSettings` in src/base/Settings.sol (L119-173)

**Purpose:** Validates a caller-supplied `VotingSettings` struct field-by-field and, if it passes, atomically
overwrites the plugin-wide `votingSettings` storage struct (L162) that every proposal-creation and vote-tally
check in the plugin reads from (`votingMode()`, `supportThreshold()`, `minParticipation()`, `minDuration()`,
`minProposerVotingPower()`, `minApproval()`, and the `maxBoundDate` field consumed directly in
`Proposal.sol`). It is the single write site for this struct (confirmed below), so every bound it does or does
not enforce here is the only bound that will ever exist for that field until the next call.

**Inputs & Assumptions:**
- `_votingSettings` (`VotingSettings calldata`, 7 fields: `votingMode`, `supportThreshold`, `minParticipation`,
  `minDuration`, `maxBoundDate`, `minProposerVotingPower`, `minApprovals`): caller-supplied. Trust: **untrusted
  data, but access-controlled** — reachable only via the two paths below, and this function is `internal` so
  it does no authorization itself.
- Implicit reads: `votingSettings.maxBoundDate` (the *old*, currently-stored value, L147), `tokenIndexedByTimestamp`
  (L151), `votingToken` (via `totalVotingPower` -> `votingToken.getPastTotalSupply`, L154), `block.timestamp`/
  `block.number` (L151).
- Precondition (implicit, not checked here): `votingToken` must already point at a live, correctly-behaving
  `IVotesUpgradeable` contract whenever the branch at L147-160 executes, since L154 calls
  `votingToken.getPastTotalSupply(...)` unconditionally on that branch. See Cross-Function Dependencies.
- Precondition: the two callers must each apply their own gating (permission or `initializer`) — nothing
  inside this function re-checks authorization.

**Outputs & Effects:**
- No return value.
- Reverts (no state change) on any of: `supportThreshold == 0 || > RATIO_BASE-1` (L122-124, `RatioOutOfBounds`);
  `minParticipation == 0 || > MAX_GOVERNANCE_RATIO` (L128-130, `RatioOutOfBounds`); `minDuration < 60 minutes`
  (L132-134, `MinDurationOutOfBounds`); `minDuration > maxBoundDate` (L136-138, `MinDurationOutOfBounds`,
  compares the *new* `minDuration` against the *new* `maxBoundDate`, both from `_votingSettings`);
  `minApprovals == 0 || > MAX_GOVERNANCE_RATIO` (L142-144, `RatioOutOfBounds`); and, only when
  `votingSettings.maxBoundDate != 0` (old value), `minProposerVotingPower > currentTotalVotingPower` (L155-159,
  `RatioOutOfBounds`).
- State write: `votingSettings = _votingSettings` (L162) — a full-struct overwrite; every field is replaced in
  one statement, so no stale field can survive a successful call.
- Event: `VotingSettingsUpdated` (L164-172), emitting every new field verbatim from `_votingSettings`.
- No external interactions except the read-only call to `votingToken.getPastTotalSupply` inside
  `totalVotingPower` (L154), gated by the L147 condition.

**Field-by-field bound audit (the seven `VotingSettings` fields):**
- `votingMode` (enum, 3 values per `INFTVoting.sol` L18-22): **no bound check in this function.** Whether an
  out-of-range raw value in calldata is rejected earlier by Solidity's calldata-to-enum decode validation, or
  reaches L162 unvalidated, is not established by this function — see Open Questions.
- `supportThreshold` (uint32): bounded to `[1, RATIO_BASE-1]` = `[1, 999_999]` at L122-124. Matches the
  `INFTVoting.sol` L45 doc comment `[0, 10^6)` only loosely — the doc says the interval is left-closed at 0,
  the code excludes 0 (comment at L120-121 explains why: `>` is used in the support criterion so `0` would
  never gate anything, and `> RATIO_BASE-1` would be unreachable).
- `minParticipation` (uint32): bounded to `[1, MAX_GOVERNANCE_RATIO]` = `[1, 900_000]` at L128-130. Matches
  `INFTVoting.sol` L47 comment exactly.
- `minDuration` (uint64): bounded below by `60 minutes` (L132-134) and above by **the new `maxBoundDate` from
  the same calldata struct** (L136-138) — not by any fixed constant such as "1 year". The `MinDurationOutOfBounds`
  doc comment at `INFTVoting.sol` L155-158 ("less than one hour or greater than 1 year") describes a stronger
  bound than what L136 actually enforces; the enforced upper bound floats with whatever `maxBoundDate` the
  caller supplies in the same call.
- `maxBoundDate` (uint64): **no standalone upper bound.** It is only constrained indirectly — it must be
  `>= minDuration` (L136, i.e. `>= 3600` given the L132 floor) — and it is read (old value) as the
  initialization-detection flag at L147. There is no check anywhere in this function capping `maxBoundDate` at
  any absolute maximum (e.g. a year), despite it flowing into `startDate`/`endDate` bound arithmetic in
  `Proposal.sol` L405-406 and L425 (`startDate + maxBoundDate`, `currentTimestamp + maxBoundDate`) — overflow
  behavior of that downstream arithmetic is out of scope for this function but the unbounded input to it
  originates here.
- `minProposerVotingPower` (uint256): bounded by `<= currentTotalVotingPower` at L155, **but only on the
  branch where the stored (old) `votingSettings.maxBoundDate != 0`** (L147). On the very first call (from
  `NFTVoting.initialize`, see below) this branch is skipped entirely, so on that call
  `minProposerVotingPower` has **no bound check found** — it can be set to any `uint256` value, including
  values no NFT-total-supply could ever reach.
- `minApprovals` (uint256): bounded to `[1, MAX_GOVERNANCE_RATIO]` = `[1, 900_000]` at L142-144, same shape as
  `minParticipation` and matching the `INFTVoting.sol` L52 comment.

**Block-by-Block:**

```solidity
// L136-138
if (_votingSettings.minDuration > _votingSettings.maxBoundDate) {
    revert MinDurationOutOfBounds({limit: _votingSettings.maxBoundDate, actual: _votingSettings.minDuration});
}
```
- **What:** Ties the new `minDuration` to the new `maxBoundDate`, both taken from the same incoming struct.
- **Why here:** Placed right after the `minDuration >= 60 minutes` floor check, before any commitment to
  storage.
- **Assumes:** `_votingSettings.maxBoundDate` is a value the caller intends as a real cap; nothing here checks
  that value against anything of its own (see field audit above).
- **Establishes:** for a call that reaches L162, `maxBoundDate >= minDuration >= 3600`. Combined with the L162
  full-struct write, this means **`votingSettings.maxBoundDate` can never be stored as `0` by this function**,
  since `minDuration >= 3600` forces `maxBoundDate >= 3600` on every successful path.
- **Depended on by:** L147's `votingSettings.maxBoundDate != 0` initialization gate — see next block. This is
  the invariant that makes that gate reliable *after* the first successful call; it says nothing about the
  gate's correctness *before* any call has succeeded (that rests on storage being genuinely zero at deploy,
  also discussed below).

```solidity
// L146-160
// For updates after initialization, check if votingSettings.maxBoundDate has not being set.
if (votingSettings.maxBoundDate != 0) {
    uint256 snapshotTimepoint;
    unchecked {
        snapshotTimepoint = tokenIndexedByTimestamp ? block.timestamp - 1 : block.number - 1;
    }
    uint256 currentTotalVotingPower = totalVotingPower(snapshotTimepoint);
    if (_votingSettings.minProposerVotingPower > currentTotalVotingPower) {
        revert RatioOutOfBounds({limit: currentTotalVotingPower, actual: _votingSettings.minProposerVotingPower});
    }
}
```
- **What:** Skips the `minProposerVotingPower` sanity check entirely when the *old* stored `maxBoundDate` is
  `0`; otherwise computes total voting power one block/timestamp unit in the past and requires the new
  `minProposerVotingPower` not exceed it.
- **Why here:** Placed after the field is available and before the L162 commit; uses the *pre-update* value of
  `votingSettings.maxBoundDate` (read from storage, not from `_votingSettings`) specifically to distinguish
  "first-ever call" from "subsequent update".
- **Assumes:** (a) storage `votingSettings.maxBoundDate == 0` really means "never successfully initialized" —
  true only if clone storage starts at zero and this function is the only writer, both confirmed below/above;
  (b) `votingToken` is already a working `IVotesUpgradeable` whenever this branch runs, since `totalVotingPower`
  unconditionally calls `votingToken.getPastTotalSupply(snapshotTimepoint)` (Settings.sol L72-74) — on the
  first call this branch is skipped precisely because `votingToken` is still unset at that point (see
  Cross-Function Dependencies: `NFTVoting.initialize` call order); (c) `block.number` / `block.timestamp` are
  `>= 1` at call time so the `unchecked` subtraction at L151 does not wrap — not enforced anywhere in this
  function, see Open Questions.
- **Establishes:** on the branch taken, `minProposerVotingPower <= currentTotalVotingPower` *as measured at
  `snapshotTimepoint`, at the moment of this call*. On the skipped branch (first call), establishes nothing
  about `minProposerVotingPower` at all.
- **Depended on by:** nothing later in this function re-reads or re-checks `minProposerVotingPower` before the
  L162 write. Downstream, `Proposal.sol` L206-211 reads `minProposerVotingPower()` and compares it against a
  *single account's* `getPastVotes`, not against total supply — so satisfying this function's bound (aggregate
  supply at update time) does not by itself imply any individual account can ever meet the threshold; that is
  a separate, unrelated property this function does not touch.

```solidity
// L162
votingSettings = _votingSettings;
```
- **What:** Commits every validated (and every unvalidated) field to storage in one assignment.
- **Why here:** After every check above; no field can be partially written on a failing call because Solidity
  reverts discard the whole transaction's storage writes.
- **Assumes:** all preceding `if`/`revert` checks together represent every bound the system requires. Per the
  field audit above, that assumption does not hold for `votingMode` (no check at all here) and for
  `maxBoundDate`/`minProposerVotingPower` on the first-call path (both effectively unbounded on that path).
- **Establishes:** `votingSettings` reflects exactly `_votingSettings` from this point until the next
  successful call to this function (the only other writer of the full struct — confirmed by grep, no other
  `votingSettings = ...` or `votingSettings.<field> = ...` assignment exists in `src/`).
- **Depended on by:** every reader in Settings.sol (`votingMode()`, `supportThreshold()`, `minParticipation()`,
  `minDuration()`, `minProposerVotingPower()`, `minApproval()`) and `votingSettings.maxBoundDate` reads in
  `Proposal.sol` L405, L406, L425.

**Cross-Function Dependencies:**
- **Callee `totalVotingPower` (internal, Settings.sol L72-74):** `return votingToken.getPastTotalSupply(_timePoint);`
  — a single external call with no path-dependent logic of its own. This function inherits whatever
  `getPastTotalSupply` does: it is trusted to (a) not revert for a legitimately-past `_timePoint`, and (b)
  return a total-supply figure that has not been manipulated. Nothing in `_updateVotingSettings` or in
  `totalVotingPower` re-derives or sanity-checks that number; the only gate on `votingToken`'s identity is the
  ERC-165 interface-ID check performed once, in `_updateVotingToken` (L196-203), which confirms the target
  *claims* to implement `IERC721Upgradeable` and `IVotesUpgradeable` but says nothing about the correctness of
  its checkpoint accounting.
- **Callee `votingToken.getPastTotalSupply` (external, black box — concrete implementation is whatever token
  was passed to `updateVotingToken`/`initialize`, e.g. `GovernanceERC721`):** assumed to implement OZ
  `Votes`-style checkpoint semantics where querying a timepoint strictly before the current block/timestamp
  succeeds and later timepoints revert; the `block.number - 1` / `block.timestamp - 1` construction at L151 is
  structured around that assumption but nothing in this function verifies the token actually behaves that way.
- **Caller `updateVotingSettings` (external, Settings.sol L109-115):** gated by
  `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` (L112). This caller supplies the DAO-permission trust boundary;
  `_updateVotingSettings` itself performs no access control and assumes the caller already established it.
- **Caller `NFTVoting.initialize` (external, src/NFTVoting.sol L41-55):** calls `_updateVotingSettings` at
  L49, **before** `_updateVotingToken` at L50. Two consequences read only from this call site:
  1. At the moment `_updateVotingSettings` executes during `initialize`, `votingToken` is still the
     zero-initialized `IVotesUpgradeable` (unset) — so if the L147 branch were somehow taken during this call,
     `totalVotingPower` would call `getPastTotalSupply` on `address(0)`, a call to non-contract code. The L147
     gate is what prevents this from ever being reached: it depends on `votingSettings.maxBoundDate` being `0`
     precisely at this call.
  2. `initialize` is guarded by the `initializer` modifier (OZ `Initializable`, applied via
     `__PluginCloneable_init` -> `__DaoAuthorizableUpgradeable_init`); per `PluginCloneable.sol` L44-48, the
     constructor of the **implementation** contract calls `_disableInitializers()`, but each deployed **clone**
     (EIP-1167 minimal proxy, per `PluginCloneable.sol` L15-17 and `pluginType()` at L67-69 returning
     `PluginType.Cloneable`) has its own storage, freshly zeroed at deployment, separate from the
     implementation's disabled-initializer state. So for a genuinely freshly-deployed clone,
     `votingSettings.maxBoundDate` reading `0` at L147 during the first `initialize` call is consistent with
     clone storage never having been written before. Whether any deployment path in this codebase could
     redeploy/reuse a clone's storage (e.g. `CREATE2` + `selfdestruct` + redeploy, or an upgrade path this
     `PluginCloneable` base does not itself support) is not established by anything in `Settings.sol` or
     `PluginCloneable.sol` — see Open Questions.
- **Shared state:** `votingSettings` (read by every getter in `Settings.sol` L78-104, and by `Proposal.sol`
  L405-406, L425, L206-211 via `minProposerVotingPower()`); `votingToken` and `tokenIndexedByTimestamp` (both
  set only in `_updateVotingToken`/`_detectTokenClock`, L194-221, and read here at L151/L154).
- **Invariant coupling:** the L147 "already initialized" gate and the L136 `minDuration <= maxBoundDate` check
  jointly guarantee `votingSettings.maxBoundDate` is either exactly `0` (never successfully written) or
  `>= 3600` (written at least once) — there is no reachable state in between via this function. This is a
  derived invariant, not an explicit one; nothing declares it, and it holds only as long as L162 remains the
  sole writer of the struct (confirmed by grep above) and L136's relative bound remains unchanged.

**Open Questions:**
- unclear; need to inspect whether Solidity's calldata-to-enum ABI decoding for `_votingSettings.votingMode`
  (an `external`/`calldata` struct field, `INFTVoting.sol` L54) reverts on an out-of-range raw value before
  this function body executes, or whether an out-of-range value could reach the L162 store and later be read
  back as an enum outside `{Standard, EarlyExecution, VoteReplacement}`.
- unclear; need to inspect every `PluginSetup`/factory contract that deploys this plugin's clones to confirm
  no code path can call `initialize` a second time on a clone whose storage was not genuinely fresh (e.g. a
  clone address reused after `selfdestruct`, or any custom upgrade mechanism layered on top of
  `PluginCloneable` elsewhere in this repo) — this function's initialization-detection gate at L147 is only as
  reliable as that external guarantee.
- unclear; need to inspect all `GovernanceERC721`/other supported voting-token implementations' `clock()` and
  `getPastTotalSupply` behavior to confirm the `unchecked` subtraction at L151 (`block.timestamp - 1` /
  `block.number - 1`) never underflows in practice, and that a query at that timepoint never reverts for a
  freshly-deployed token with no checkpoints yet.
- unclear; need to inspect `Proposal.sol` L400-430 to determine what happens downstream when `maxBoundDate` is
  set to an extreme value (this function places no upper bound on it) — specifically whether the
  `startDate + maxBoundDate` / `currentTimestamp + maxBoundDate` arithmetic there has its own overflow guard.
