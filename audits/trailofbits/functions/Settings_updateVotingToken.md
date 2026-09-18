## `_updateVotingToken` in src/base/Settings.sol (L194-210)

```solidity
// L194-210
function _updateVotingToken(IVotesUpgradeable _token) internal virtual {
    require(
        IERC165Upgradeable(address(_token)).supportsInterface(type(IERC721Upgradeable).interfaceId),
        "token is not a ERC721"
    );

    require(
        IERC165Upgradeable(address(_token)).supportsInterface(type(IVotesUpgradeable).interfaceId),
        "token is not a Votes Upgradeable (required getVotes and getPastTotalSupply)"
    );

    votingToken = _token;

    _detectTokenClock();

    emit VotingTokenUpdated(address(_token));
}
```

**Purpose:** Validates a candidate ERC-721 `Votes` token and, if it passes, swaps the plugin-wide `votingToken`
state variable and re-derives `tokenIndexedByTimestamp`, the flag that tells the rest of the plugin whether
checkpoints on the *current* token are indexed by `block.timestamp` or `block.number`. It is the only writer
of `votingToken` after initialization and the only place `tokenIndexedByTimestamp` is (re)computed following a
token swap.

**Inputs & Assumptions:**
- `_token` (`IVotesUpgradeable`): the candidate voting token. Trust: **semi-trusted** — it is supplied by
  whoever holds `UPDATE_VOTING_SETTINGS_PERMISSION_ID` (checked one call frame up, at the external wrapper
  `updateVotingToken`, Settings.sol:178, via the `auth` modifier), not by an arbitrary caller. Nothing in this
  function or its callee re-validates that the *bytecode* behind `_token` behaves like a well-formed
  `Votes`/ERC-6372 token beyond the two `supportsInterface` probes below; a permissioned caller can point
  `votingToken` at any contract that answers those two probes correctly.
- Implicit: current values of `votingToken` and `tokenIndexedByTimestamp` (about to be overwritten), and the
  live `block.timestamp` at the moment `_detectTokenClock` runs (Settings.sol:216).
- Precondition (assumed by the rest of the contract, not enforced here): `_token` implements ERC-721
  (`IERC721Upgradeable`, checked L196) and OpenZeppelin's `IVotesUpgradeable` (`getVotes`, `getPastVotes`,
  `getPastTotalSupply`, `delegate*`, checked L200). **Neither check requires ERC-6372 support** —
  `IVotesUpgradeable` as vendored here (`lib/openzeppelin-contracts-upgradeable/.../IVotesUpgradeable.sol:10-56`)
  declares no `clock()`/`CLOCK_MODE()` member, so a token can pass both `require`s while having no `clock()`
  function at all. That gap is exactly what `_detectTokenClock`'s `try/catch` exists to absorb (see below).
- No precondition is checked on `_token != address(0)` or `_token != votingToken` (no-op re-set is allowed and
  falls through to re-running `_detectTokenClock` against the unchanged token).

**Outputs & Effects:**
- State write: `votingToken = _token` (L205) — plugin-wide, immediately effective for every read site that
  consults the live `votingToken` variable rather than a per-proposal snapshot (enumerated below).
- State write (via callee): `tokenIndexedByTimestamp` is reassigned by `_detectTokenClock` (L207) to reflect
  the *new* `votingToken`, not the old one, because the assignment at L205 happens before the callee is
  invoked.
- Event: `VotingTokenUpdated(address(_token))` (L209).
- External interactions: two `STATICCALL`-compiled `supportsInterface` probes (L196, L200 — both declared
  `view` in `IERC165Upgradeable`) and, inside the callee, one `STATICCALL`-compiled `clock()` probe
  (Settings.sol:215, declared `view` in `IERC6372Upgradeable`, `lib/openzeppelin-contracts-upgradeable/contracts/interfaces/IERC6372Upgradeable.sol:10`).
  Because all three calls are compiled as `STATICCALL`, none of them can themselves write plugin storage
  during re-entry; they can only re-enter into other `view`/`pure` entry points and observe transient state
  (see Open Questions / Cross-Function Dependencies for what that transient state looks like).
- Postcondition on success: `votingToken` and `tokenIndexedByTimestamp` both describe the same, newly-set
  token. Postcondition does **not** extend to any proposal already stored in `proposals[...]` — those keep
  whatever token address was pinned into `proposal_.parameters.votingToken` at their own creation time
  (Proposal.sol:315), which this function never touches.

**Block-by-Block:**

```solidity
// L195-198
require(
    IERC165Upgradeable(address(_token)).supportsInterface(type(IERC721Upgradeable).interfaceId),
    "token is not a ERC721"
);
```
- **What:** Rejects `_token` unless it self-reports ERC-721 support.
- **Why here:** First gate, before any storage write, so a bad token can't get into `votingToken` at all if it
  fails this check.
- **Assumes:** `_token`'s `supportsInterface` answers truthfully and does not revert for unrelated reasons; if
  `_token` has no code or does not implement ERC-165, this call reverts the whole transaction rather than
  being caught (no `try/catch` here, unlike the clock probe).
- **Establishes:** "token claims ERC-721" — an unverified self-report, not an on-chain proof that `_token`
  actually implements the ERC-721 methods used elsewhere (`isMember`'s `balanceOf` call at Votes.sol:131).
- **Depended on by:** nothing downstream re-checks this; it is a one-time gate.

```solidity
// L200-203
require(
    IERC165Upgradeable(address(_token)).supportsInterface(type(IVotesUpgradeable).interfaceId),
    "token is not a Votes Upgradeable (required getVotes and getPastTotalSupply)"
);
```
- **What:** Rejects `_token` unless it self-reports `IVotesUpgradeable` support.
- **Why here:** Second gate; together with L196 this is the entirety of input validation for `_token`.
- **Assumes:** same self-report caveat as above. Crucially, `IVotesUpgradeable`'s own interface (vendored at
  `lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/IVotesUpgradeable.sol:10-56`) does **not**
  include `clock()`/`CLOCK_MODE()`, so this check gives no information about ERC-6372 support.
- **Establishes:** "token claims OZ `Votes` semantics" (delegation + past-votes/past-supply lookups). Does not
  establish anything about clock/checkpoint indexing.
- **Depended on by:** every later `getPastVotes`/`getPastTotalSupply` call site listed under Cross-Function
  Dependencies, all of which assume the token behaves like OZ `Votes` without re-verifying it.

```solidity
// L205
votingToken = _token;
```
- **What:** Overwrites the plugin-wide voting-token pointer.
- **Why here:** After both interface gates pass, and before `_detectTokenClock` runs, so the clock probe reads
  the *new* token, not the old one — `_detectTokenClock` (L215) reads `votingToken`, which by this point is
  `_token`.
- **Assumes:** no invariant tying `votingToken` to any specific proposal's already-pinned
  `parameters.votingToken`; those are separate storage slots (`proposal_.parameters.votingToken`, set once at
  `Proposal.sol:315`) and are never revisited here.
- **Establishes:** from this line onward (within this same transaction) any code path reading the live
  `votingToken` — including a re-entrant `view` call triggered by the clock probe below — observes the new
  token. It does **not** yet establish a matching `tokenIndexedByTimestamp`; that happens on the next line via
  an external call, leaving a transient window (see `_detectTokenClock` analysis and Open Questions).
- **Depended on by:** `_detectTokenClock` (L207/L215), `getVotingToken()` (L63-65), `totalVotingPower()`
  (L72-74), `canCreateProposal` (Proposal.sol:211), `createProposal` (Proposal.sol:295, 315),
  `_updateVotingSettings` (Settings.sol:154), `isMember` (Votes.sol:131).

```solidity
// L207
_detectTokenClock();
```
- **What:** Re-derives `tokenIndexedByTimestamp` for the just-assigned `votingToken`.
- **Why here:** Must run after L205 (needs the new token address) and before the function returns (so the two
  state variables are consistent by the time any other transaction observes them).
- **Assumes:** see the dedicated callee analysis below — the assumption that a `catch` on `clock()` implies
  block-number indexing, and that a non-timestamp return value implies block-number indexing without checking
  it against `block.number`.
- **Establishes:** `tokenIndexedByTimestamp` reflects *some* classification of the new token's clock, correct
  for the two cases the code explicitly recognizes (returns exactly `block.timestamp`, or reverts) and
  unverified for every other case (see callee).
- **Depended on by:** `canCreateProposal` (Proposal.sol:199), `createProposal` (Proposal.sol:288),
  `_updateVotingSettings` (Settings.sol:151) — all plugin-wide, forward-looking reads, never a per-proposal
  read (no `ProposalParameters` field stores this flag; see Cross-Function Dependencies).

```solidity
// L209
emit VotingTokenUpdated(address(_token));
```
- **What:** Logs the swap.
- **Why here:** Last statement, after both state writes have landed, so the event reflects final state.
- **Assumes / Establishes:** nothing further; off-chain indexers rely on this to detect the swap. No amount
  emitted for the old token, no snapshot of `tokenIndexedByTimestamp` included in the event.

---

### Callee: `_detectTokenClock` in src/base/Settings.sol (L214-221)

```solidity
// L214-221
function _detectTokenClock() private {
    try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timePoint) {
        tokenIndexedByTimestamp = (timePoint == block.timestamp);
    } catch {
        // Assuming that the token indexes by block number (the ERC-6372 default)
        tokenIndexedByTimestamp = false;
    }
}
```

Read in full; it has exactly two paths and neither is a proposal-facing read — both write the single
plugin-wide flag `tokenIndexedByTimestamp`.

- **`try` path succeeds, `timePoint == block.timestamp` (L216, true branch):** sets
  `tokenIndexedByTimestamp = true`. This is correct precisely when the token's `clock()` genuinely returns
  `block.timestamp` at the moment of the call — true for an OZ `VotesUpgradeable` configured in timestamp mode
  (returns `uint48(block.timestamp)` verbatim), and coincidentally satisfiable by any other contract whose
  `clock()` happens to equal the current timestamp for unrelated reasons (e.g. a custom clock counting
  something that is numerically equal to `block.timestamp` at this instant only).
- **`try` path succeeds, `timePoint != block.timestamp` (L216, false branch):** sets
  `tokenIndexedByTimestamp = false`, i.e. "block-number indexed." **This is asserted, not verified** — the
  code never compares `timePoint` to `block.number`. A token whose `clock()` returns neither
  `block.timestamp` nor `block.number` (e.g. an arbitrary monotonic counter, a different `CLOCK_MODE()` per
  ERC-6372's own extensibility) is silently misclassified as block-number-indexed, and every subsequent
  `snapshotTimepoint` computed from `tokenIndexedByTimestamp` (`Proposal.sol:288-293`, `:196-204`,
  `Settings.sol:150-152`) will be a `block.number`-shaped value handed to a token that does not interpret it
  that way.
- **`catch` (any revert, including "no such function"):** sets `tokenIndexedByTimestamp = false`. The comment
  at L218 frames this as "the ERC-6372 default." That framing is accurate for the specific case of an OZ
  `VotesUpgradeable`-family token that does not override `clock()`/`CLOCK_MODE()` — OZ's default
  implementation returns `block.number`, so a *reverting* `clock()` call would actually mean "no ERC-6372
  support at all," not "ERC-6372 present and block-number-moded." The `catch` branch cannot distinguish "token
  has no `clock()` function" from "token has a `clock()` that reverts for some other reason" (out-of-gas
  inside the callee, a state precondition not met, a deliberately-reverting implementation) — both land here
  identically because `_updateVotingToken`'s own interface gates (L196, L200) never require
  `IERC6372Upgradeable` support in the first place (see above: `IVotesUpgradeable` as vendored does not
  include it).
- **Assumes:** the two-way split ("== block.timestamp" vs "everything else, including revert, means
  block-number") exhaustively covers every token's real indexing scheme. Nothing enforces this; it is an
  assumption the rest of the plugin inherits.
- **Establishes:** `tokenIndexedByTimestamp` for the token that is live in `votingToken` at the moment this
  runs — i.e., the token just written at L205, not any token pinned into an existing proposal.
- **Depended on by:** the same three read sites as `_updateVotingToken`'s L207 entry above; none of them are
  per-proposal reads (see next section).

**Reentrancy shape of the external call at L215:** `IERC6372Upgradeable.clock()` is declared `external view`
(`lib/openzeppelin-contracts-upgradeable/contracts/interfaces/IERC6372Upgradeable.sol:10`), so Solidity
compiles this call as a `STATICCALL`. If the token supplied to `_updateVotingToken` is adversarial, its
`clock()` implementation can re-enter the plugin during this call, but only into other `view`/`pure` entry
points (a `STATICCALL` context forbids state-changing sub-calls, which would revert). During that reentrant
window, storage holds `votingToken == _token` (new, written at L205) together with `tokenIndexedByTimestamp`
still equal to its *previous* value (the L216/L219 write has not happened yet, since it is what the `try`/
`catch` around this very call is going to produce). Any `view` function reachable in that window that reads
both variables together — `canCreateProposal` (Proposal.sol:194-212, reads `tokenIndexedByTimestamp` at L199
and `votingToken` at L211) is the only such function — would see the new token's address paired with the old
token's clock classification. Because the call context is a `STATICCALL`, nothing observed there can be
written back to plugin storage during the same call chain; whether a re-entrant read of this transient,
inconsistent pair can be leveraged across transactions is not something this function's code answers (see
Open Questions).

**Cross-Function Dependencies:**

- **Read sites for an existing (already-created) proposal — all use the per-proposal pinned
  `proposal_.parameters.votingToken`, never the live `votingToken` state variable, and are therefore
  unaffected by a mid-flight `_updateVotingToken` call:**
  - `Proposal.execute` (Proposal.sol:43-55): reads `proposal_.parameters.votingToken` at L45, calls
    `getPastVotes` on it at L49. Pinned.
  - `Proposal._canExecute` (Proposal.sol:91-107): reads no token directly; delegates to `_isProposalOpen`
    (parameters/executed flag only, L251-256) and `_hasSucceeded`.
  - `Proposal._hasSucceeded` (Proposal.sol:121-152): for the open/EarlyExecution branch calls
    `isSupportThresholdReachedEarly` (pinned, see below); for the closed branch calls
    `isSupportThresholdReached`, which reads only `proposal_.tally` and
    `proposal_.parameters.supportThreshold` (Proposal.sol:154-159) — **no token read at all**, so it cannot be
    affected by a token swap either way. `isMinParticipationReached`/`isMinApprovalReached`
    (Proposal.sol:172-188) are likewise tally-only.
  - `Proposal.isSupportThresholdReachedEarly` (Proposal.sol:161-170): reads
    `proposal_.parameters.votingToken` at L163 and calls `getPastTotalSupply` on it at L165. Pinned.
  - `Votes._vote` (Votes.sol:29-72): reads `proposal_.parameters.votingToken` at L34, calls `getPastVotes` on
    it at L37 and L68. Pinned. (Comment at L36 already notes this call "could re-enter" and assumes the
    governance token is not malicious — a pre-existing assumption this analysis does not re-litigate beyond
    noting it exists.)
  - `Votes._canVote` (Votes.sol:93-126): reads `proposal_.parameters.votingToken` at L100, calls
    `getPastVotes` at L113. Pinned.
  - **Structural point that makes the above hold even for `tokenIndexedByTimestamp`:** `ProposalParameters`
    (`INFTVoting.sol:96-104`) stores `votingToken` (address) and a pre-computed `snapshotTimepoint`
    (`uint64`, set once at `Proposal.sol:314` from a value computed under whatever `tokenIndexedByTimestamp`
    was *at creation time*, `Proposal.sol:284-293`). There is **no per-proposal field caching
    `tokenIndexedByTimestamp` itself** — but none is needed for correctness of existing proposals, because
    every pinned read above passes `snapshotTimepoint` (already a concrete number) to the *pinned* token's
    `getPastVotes`/`getPastTotalSupply`, and that pinned token's own interpretation of that number was fixed
    when the proposal was created and does not change when `_updateVotingToken` later swaps the live
    `votingToken`/`tokenIndexedByTimestamp` pair for a *different* token object.

- **Read sites that use the live `votingToken` / `tokenIndexedByTimestamp` and are therefore immediately
  affected by `_updateVotingToken`, by design (all are forward-looking / plugin-wide, not tied to one
  proposal):**
  - `Settings.getVotingToken` (L63-65) — returns live `votingToken` verbatim.
  - `Settings.totalVotingPower` (L72-74) — `votingToken.getPastTotalSupply(_timePoint)` on the live token.
    Called from `Proposal.createProposal` (L295, for a proposal about to be created) and from
    `Settings._updateVotingSettings` (L154, to bound a new `minProposerVotingPower` against current supply).
    Neither caller is evaluating an existing proposal.
  - `Proposal.canCreateProposal` (L194-212) — reads live `tokenIndexedByTimestamp` (L199) to pick
    `block.timestamp - 1` vs `block.number - 1`, then reads live `votingToken.getPastVotes` (L211). Used both
    standalone (external view) and inside `createProposal` (L278) as a creation gate — never inside a stored
    proposal's evaluation.
  - `Proposal.createProposal` (L271-337) — computes `snapshotTimepoint` from live `tokenIndexedByTimestamp`
    (L288-293), reads live `totalVotingPower` (L295), and — only at this point — pins the live `votingToken`
    address into the new proposal's `parameters.votingToken` (L315). This is the one place the "live" and
    "pinned" worlds meet: whatever `votingToken`/`tokenIndexedByTimestamp` pair is live at proposal-creation
    time becomes that proposal's permanent, immutable frame of reference.
  - `Settings._updateVotingSettings` (L146-160) — reads live `tokenIndexedByTimestamp` (L151) and live
    `totalVotingPower` (L154) to validate a new `minProposerVotingPower` bound; unrelated to any specific
    proposal.
  - `Votes.isMember` (L129-132) — reads live `votingToken.getVotes`/`balanceOf`; a point-in-time membership
    check, not proposal-scoped.
  - **Consistency of the live pair:** because `votingToken` (L205) and `tokenIndexedByTimestamp`
    (`_detectTokenClock`, L207) are written in the same transaction with no attacker-controlled
    state-changing call in between (the only external call in between is the `STATICCALL`-limited `clock()`
    probe), any transaction that begins **after** `_updateVotingToken` returns observes a consistent pair.
    The only place a mismatched pair could theoretically be observed is the reentrant `STATICCALL` window
    documented above, which cannot itself commit a state change.

- **Callers of `_updateVotingToken`:**
  - `updateVotingToken` (Settings.sol:178-180), external, gated by
    `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` (`DaoAuthorizableUpgradeable.sol:34-37`, which itself defers
    to the DAO's permission manager and adds no reentrancy guard of its own). Callable at any time after
    initialization, including while proposals are open — this is the "mid-flight" call the task asks about.
  - `NFTVoting.initialize` (`src/NFTVoting.sol:50`), called once via the proxy initializer, after
    `_updateVotingSettings` (`:49`); at this point `proposals` is necessarily empty, so none of the
    pinned-vs-live distinctions above are yet in play.

- **Shared state:** `votingToken` and `tokenIndexedByTimestamp` are shared with every function listed in the
  two bullets above; `votingSettings.maxBoundDate`/`minDuration` (read by `_updateVotingSettings`,
  `_validateProposalDates`) are a separate, unrelated piece of shared state not touched here.

- **Invariant coupling:** The system's central per-proposal invariant — "a proposal's voting-power arithmetic
  is evaluated against the same token and the same clock convention throughout its lifetime" — is upheld
  structurally by `ProposalParameters.votingToken` + the pre-computed `snapshotTimepoint` being copied once at
  creation (`Proposal.sol:314-315`) and never re-read from `Settings`. `_updateVotingToken` never writes
  `proposals[...]`, so it cannot violate that invariant for any proposal that already exists. The invariant it
  *does* own — "`votingToken` and `tokenIndexedByTimestamp` describe the same token" — holds at every point
  observable from a top-level transaction, per the consistency note above, but is not itself checked by any
  assertion; it is a byproduct of write ordering (L205 before L207) that nothing would flag if a future edit
  reordered those two lines or interleaved a state-changing external call between them.

**Open Questions:**
- unclear; need to inspect whether `canCreateProposal` (the only function that reads both `votingToken` and
  `tokenIndexedByTimestamp` together, Proposal.sol:194-212) is reachable as a re-entrant `STATICCALL` target
  from a malicious token's `clock()` implementation in a way that produces an observable effect outside that
  same call frame (e.g., surfaced through a return value the token contract forwards elsewhere), given that
  the call context forbids any state write during the window.
- unclear; need to inspect whether any ERC-6372 token used in practice (beyond `GovernanceERC721`, which
  implements no custom `clock()`/`CLOCK_MODE()` and therefore relies on OZ's default block-number `clock()`,
  confirmed absent by grep) returns a `clock()` value that is neither `block.timestamp` nor `block.number` —
  that is the case `_detectTokenClock`'s false-branch assumption (L216/L219 both collapsing to
  `tokenIndexedByTimestamp = false`) does not actually verify.
- unclear; need to inspect the full permission-manager path behind `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)`
  (`_auth` in `lib/osx-commons/contracts/src/permission/auth/auth.sol`, not read here) to know whether it
  imposes any additional preconditions (e.g., DAO-level timelock, multisig quorum) on who can trigger a
  mid-flight token swap, since that governs how "semi-trusted" `_token` actually is in practice.
