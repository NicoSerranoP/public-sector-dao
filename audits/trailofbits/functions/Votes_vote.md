# `Votes._vote(uint256, VoteOption, address, bool)` — `src/base/Votes.sol:29-72`

## Signature and role

```solidity
function _vote(uint256 _proposalId, VoteOption _voteOption, address _voter, bool _tryEarlyExecution)
    internal
    virtual
```

Internal state-mutating function that records a vote (or a vote replacement) for `_voter` on
`_proposalId`, updates the running `Tally`, and optionally attempts early execution. It is documented
as assuming "the queried proposal exists" (`Votes.sol:24`) and does not itself check that.

The only caller in the current source tree is the public entrypoint `vote()`:

```solidity
function vote(uint256 _proposalId, VoteOption _voteOption, bool _tryEarlyExecution) public virtual {
    address account = _msgSender();
    if (!_canVote(_proposalId, account, _voteOption)) {
        revert VoteCastForbidden(...);
    }
    _vote(_proposalId, _voteOption, account, _tryEarlyExecution);
}
```
(`Votes.sol:15-22`). `_vote` is `internal virtual`, and `NFTVoting` (`src/NFTVoting.sol`) — the only
concrete contract in `src/` that inherits `Votes` — does not override `vote`, `_vote`, or `_canVote`
(`src/NFTVoting.sol:20-64`). So in the deployed system every call to `_vote` is preceded by a
`_canVote` check. That check is external to `_vote` itself; nothing inside `_vote` re-verifies its
preconditions.

## Line-by-line walkthrough

- `Votes.sol:33-34`: loads the proposal from storage (`proposal_`) and reads
  `proposal_.parameters.votingToken`, a per-proposal address captured once at proposal creation
  (`Proposal.sol:315`, `proposal_.parameters.votingToken = address(votingToken)`), into a local
  `IVotesUpgradeable` handle. This is **not** the same as the live `Settings.votingToken` state
  variable — `_vote` always uses the token that was snapshotted when this specific proposal was
  created, so a later admin call to `updateVotingToken` (`Settings.sol:178-210`) cannot change which
  token an in-flight proposal is scored against.
- `Votes.sol:36-37`: `uint256 votingPower = proposalVotingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint);`
  An external `view` call into whatever contract `proposal_.parameters.votingToken` points to. The
  comment above it reads "This could re-enter, though we can assume the governance token is not
  malicious" — see the Callee analysis section below for what this claim resolves to against the
  actual OZ implementation vs. against an arbitrary configured token.
- `Votes.sol:38`: `VoteOption state = proposal_.voters[_voter];` — reads the voter's previously recorded
  choice. This read happens **after** the external call at line 37 returns, not before it.
- `Votes.sol:41-47`: if `state` was `Yes`/`No`/`Abstain`, subtract `votingPower` (the value just fetched
  at line 37, for the *current* call) from the corresponding tally bucket. `VoteOption.None` matches no
  branch, so a first-time voter contributes no subtraction.
- `Votes.sol:50-56`: if the new `_voteOption` is `Yes`/`No`/`Abstain`, add `votingPower` to the
  corresponding bucket. If `_voteOption == VoteOption.None`, no branch matches and nothing is added —
  the net effect of the whole function for a `None` input, given a previously non-`None` `state`, is a
  pure retraction (subtract only, then `proposal_.voters[_voter]` reset to `None` at line 58).
- `Votes.sol:58`: unconditionally records `proposal_.voters[_voter] = _voteOption`, including the
  `VoteOption.None` case.
- `Votes.sol:60`: emits `VoteCast` with the just-fetched `votingPower` (the same value used in the
  arithmetic above, not a re-read).
- `Votes.sol:62-64`: if `_tryEarlyExecution` is `false`, returns immediately; no execution attempt, no
  second external call.
- `Votes.sol:66-69`: if `_tryEarlyExecution` is `true`, evaluates
  `_canExecute(_proposalId) && proposalVotingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint) > 0`.
  Because `&&` short-circuits, `getPastVotes` is only called a second time if `_canExecute` already
  returned `true`. This is a **second, independent external call** to the same token/account/timepoint
  triple already queried at line 37.
- `Votes.sol:70`: if both conditions hold, calls `_execute(_proposalId)` (`Proposal.sol:59-74`), which
  sets `proposal_.executed = true` before running the DAO's actions.

## Invariants

- **I1 — tally bucket exclusivity.** At any point, each voter contributes to at most one of
  `tally.yes`/`tally.no`/`tally.abstain`, tracked via `proposal_.voters[_voter]`. Established by the
  paired subtract-on-old-state / add-on-new-state structure (`Votes.sol:41-56`) plus the unconditional
  state overwrite at `Votes.sol:58`. This invariant is internal to `_vote` and holds regardless of how
  many times `_vote` runs for the same voter, *provided* `votingPower` is the same value on the
  subtract branch as it was when that same state was originally added (see A1 below — this is where the
  invariant's soundness actually rests).
- **I2 — tally updates precede execution eligibility checks in the same call.** The tally write
  (`Votes.sol:41-58`) always completes before `_canExecute`/`_execute` are considered
  (`Votes.sol:62-70`), so a just-cast vote is counted in the same transaction's early-execution
  decision. Established by straight-line ordering in the function body.
- **I3 — the token used is proposal-scoped, not the live admin-settable token.** `proposalVotingToken`
  is derived from `proposal_.parameters.votingToken` (`Votes.sol:34`), which is fixed at proposal
  creation time (`Proposal.sol:315`) and never rewritten afterward (no write site to
  `proposal_.parameters.votingToken` exists outside `createProposal`). A later `updateVotingToken` call
  changes `Settings.votingToken` but cannot retroactively change parameters of already-created
  proposals.
- **I4 — historical `getPastVotes` results for a fixed `(account, snapshotTimepoint)` pair are
  immutable once `snapshotTimepoint` has passed, for the genuine OZ implementation.** See Callee
  analysis; this is the fact the arithmetic subtraction (I1) actually depends on.

## Assumptions and what establishes them

- **A1 — `votingPower` subtracted from a bucket at replacement time equals the `votingPower` that was
  originally added to that bucket for the same voter.** `_vote` re-derives `votingPower` from scratch on
  every call (`Votes.sol:37`) rather than storing per-voter voting power anywhere; the subtraction at
  lines 41-47 implicitly assumes today's fresh `getPastVotes` call returns exactly what a *prior*
  `_vote` call's fresh `getPastVotes` call returned for the same voter.
  - **What establishes it, for the genuine token path:** the OZ `VotesUpgradeable.getPastVotes`
    implementation (`lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/VotesUpgradeable.sol:87-90`)
    requires `timepoint < clock()` and does a pure storage lookup
    (`_delegateCheckpoints[account].upperLookupRecent(...)`, no external call). Checkpoints are stored
    with a monotonic-non-decreasing-key invariant enforced in `_insert`
    (`lib/openzeppelin-contracts-upgradeable/contracts/utils/CheckpointsUpgradeable.sol:311`,
    `require(last._key <= key, "Checkpoint: decreasing keys")`), and every push uses the *current*
    `clock()` as the key (`VotesUpgradeable.sol:209`, `_push(...) { return store.push(SafeCast.toUint32(clock()), ...); }`).
    Since a proposal's `snapshotTimepoint` is set to `block.timestamp - 1` /
    `block.number - 1` at creation (already-mined/past — `Proposal.sol:196-203`), and voting can only
    happen once the proposal is open (`startDate <= currentTime`, itself `>= snapshotTimepoint + 1` by
    construction in `_validateProposalDates`, `Proposal.sol:394-408`), no checkpoint can ever be
    inserted with a key equal to `snapshotTimepoint` after the proposal exists — any later push uses a
    strictly larger key. Consequently `upperLookupRecent(snapshotTimepoint)` for a given voter is a
    pure function of storage that was already final before the first vote could be cast, and stays
    final forever after (further transfers/delegations only append checkpoints at keys >
    `snapshotTimepoint`, never rewrite the one at or below it). So for the concrete token actually
    wired into this plugin, `GovernanceERC721` (`src/erc721/GovernanceERC721.sol`, which inherits
    `ERC721VotesUpgradeable`/`VotesUpgradeable` without overriding `getPastVotes` or introducing any
    external call into that path), A1 holds deterministically: two calls to
    `getPastVotes(voter, snapshotTimepoint)` at any two points in time after proposal creation return
    identical values, no matter what happens to the voter's balance/delegation in between.
  - **What does *not* establish it:** `proposal_.parameters.votingToken` is only required (at
    `_updateVotingToken`, `Settings.sol:194-210`) to self-report `ERC165` support for
    `IERC721Upgradeable` and `IVotesUpgradeable` interface IDs. This is a claim the token contract makes
    about itself via `supportsInterface`; nothing checks that its `getPastVotes` implementation is
    actually a checkpoint-backed, side-effect-free, deterministic function. If the token configured by
    whoever holds `UPDATE_VOTING_SETTINGS_PERMISSION_ID` is not the genuine OZ `VotesUpgradeable`
    (e.g., a proxy or an intentionally non-conforming contract that merely declares the right interface
    IDs), nothing in `_vote`, `_canVote`, or `_updateVotingToken` prevents `getPastVotes` from returning
    different values across calls, from depending on call count, `msg.sender`, or reentrant state, or
    from making external calls / callbacks. In that scenario A1 is unenforced, and the subtraction at
    `Votes.sol:41-47` (unchecked arithmetic in Solidity ^0.8.8 default checked mode — so it would revert
    on underflow rather than wrap, but could revert unexpectedly, corrupt the tally with a stale
    subtrahend, or leave the bucket permanently over/under-counted relative to the addition it's
    supposed to net out) rests entirely on the "governance token is not malicious" comment at
    `Votes.sol:36`, which is a documented trust assumption on the plugin's token-configuring admin, not
    something the code enforces.

- **A2 — `_voteOption != VoteOption.None` when `_vote` is entered with a `state` that should be
  overwritten meaningfully.** `_vote` itself performs no check on `_voteOption` at all beyond the
  branch dispatch at lines 50-56 (which silently no-ops for `None`). The guard lives entirely in the
  caller: `_canVote` explicitly rejects `_voteOption == VoteOption.None` at `Votes.sol:108-110`, and
  `vote()` reverts with `VoteCastForbidden` before calling `_vote` if `_canVote` returns `false`
  (`Votes.sol:18-20`). Because `_vote` is `internal virtual` and the only present caller enforces this,
  the guard is an assumption from `_vote`'s own point of view, established at `Votes.sol:108-110` via
  `Votes.sol:18-20`, not inside `_vote`. Any future override that calls `_vote` directly (or an override
  of `_canVote` that drops the `None` check) removes this guard with no compensating check in `_vote`
  itself. Mechanically, if `_vote` were invoked with `VoteOption.None` while `state` was a real prior
  vote, the effect is a full retraction: the corresponding tally bucket is decremented and
  `proposal_.voters[_voter]` is reset to `None`, with a `VoteCast` event carrying `voteOption: None`.

- **A3 — repeat calls to `_vote` for the same voter on the same proposal only happen when
  `votingMode == VoteReplacement`.** `_vote`'s subtract-then-add structure is written generically to
  handle vote replacement correctly regardless of mode, but the business rule that Standard/
  EarlyExecution modes disallow revoting is enforced only by `_canVote`
  (`Votes.sol:117-123`: `if (proposal_.voters[_account] != VoteOption.None && proposal_.parameters.votingMode != VotingMode.VoteReplacement) return false;`),
  not by `_vote`. `_vote` would mechanically process a second vote correctly (net effect: the second
  vote replaces the first) even under Standard mode if ever reached without going through `_canVote`.

- **A4 — the proposal identified by `_proposalId` exists.** Documented as an assumption in the natspec
  (`Votes.sol:24`) and not checked in `_vote`. `proposal_ = proposals[_proposalId]` (`Votes.sol:33`) on
  a non-existent id yields a zero-initialized `Proposal` struct (`snapshotTimepoint == 0`,
  `votingToken == address(0)`); `IVotesUpgradeable(address(0)).getPastVotes(...)` would then be a call
  to a non-contract address. Established (for the one real caller) by `vote()`'s reliance on `_canVote`,
  which itself does not check proposal existence directly but calls `_isProposalOpen` (`Proposal.sol:251-256`,
  using `proposal_.parameters.startDate`/`endDate`, both zero for a non-existent proposal, so
  `_isProposalOpen` returns `false` and `_canVote` returns `false` before reaching the `getPastVotes`
  check) — so existence is indirectly enforced via the open/closed check, not an explicit existence
  check, for the `vote()` path. `Proposal.execute`/`canExecute` use the explicit
  `onlyIfProposalExists` modifier (`Proposal.sol:34-39,43-55,76-85`) but `_vote` and `vote()` do not.

## Callee analysis

### `IVotesUpgradeable(proposal_.parameters.votingToken).getPastVotes(_voter, snapshotTimepoint)` (lines 37 and 68)

Interface-typed call to an address that is admin-configurable at the `Settings` level (subject to the
`ERC165` self-report check in `_updateVotingToken`, `Settings.sol:194-210`) and then frozen per-proposal.
Traced against the concrete/expected implementation:

- `VotesUpgradeable.getPastVotes` (`lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/VotesUpgradeable.sol:87-90`):
  ```solidity
  function getPastVotes(address account, uint256 timepoint) public view virtual override returns (uint256) {
      require(timepoint < clock(), "Votes: future lookup");
      return _delegateCheckpoints[account].upperLookupRecent(SafeCastUpgradeable.toUint32(timepoint));
  }
  ```
  This is `view`, touches only `_delegateCheckpoints[account]` (a `Trace224` in storage) and `clock()`
  (`block.number` by default, `VotesUpgradeable.sol:58-60`). It contains **no external call, no
  delegatecall, no low-level call, and no callback hook of any kind** — it cannot reenter the caller by
  itself. `upperLookupRecent` (`CheckpointsUpgradeable.sol:250-268`) is a pure binary search over a
  storage array with `_unsafeAccess` doing raw storage-slot arithmetic, still no external interaction.
  So the natspec comment "This could re-enter" (`Votes.sol:36`) does **not** hold for the genuine OZ
  `VotesUpgradeable`/`ERC721VotesUpgradeable` implementation that `GovernanceERC721`
  (`src/erc721/GovernanceERC721.sol:38`) inherits unmodified — `getPastVotes` is not overridden there,
  and no hook it depends on (`_getVotingUnits`, `_delegateCheckpoints`) is either. The comment's
  disclaimer "we can assume the governance token is not malicious" is therefore really about the
  possibility of `proposal_.parameters.votingToken` pointing at some *other*, non-OZ contract that
  merely satisfies the two `ERC165` interface IDs checked in `_updateVotingToken` — that check does not
  verify the actual bytecode/behavior, so a token that declares conformance but implements
  `getPastVotes` with an external call (or with non-deterministic/stateful behavior) is not excluded by
  anything in `Settings.sol`, `Votes.sol`, or `Proposal.sol`.
  - Full checkpoint-immutability argument for the genuine token is under A1 above.
- Failure / adversarial outcomes not excluded by the caller, if `votingToken` is not the genuine
  implementation: reverting (DoS on `vote()`/`_execute` path since the call is unguarded by try/catch),
  returning different values across the two calls at lines 37 and 68 within the same transaction (see
  next subsection), or making an external call that reenters `vote()`/`_vote()` for the same or a
  different proposal before returning.

### Two `getPastVotes` calls within one `_vote` execution (lines 37 and 68) — are they guaranteed equal?

- For the genuine OZ implementation: yes. Both calls pass identical arguments
  (`_voter`, `proposal_.parameters.snapshotTimepoint` — the latter read from the same immutable-once-set
  storage field both times) to a pure storage-read function over state (`_delegateCheckpoints[_voter]`)
  that, per the A1 argument, cannot change its answer for that specific `(account, timepoint)` pair once
  `timepoint` is in the past — and nothing in `_vote`'s own body writes to the token's storage between
  the two calls (the only writes in between are to `proposal_` fields: `tally`, `voters`, and
  `proposal_.executed` inside `_execute`, none of which touch the token contract). So under the trust
  assumption the comment already names, the second call at line 68 is a redundant re-derivation of a
  value already held in the local `votingPower` variable from line 37 — it costs an extra external
  `STATICCALL`-equivalent but cannot observe a different answer.
- If the token is adversarial (the case the comment is implicitly conceding), the two calls are
  independent invocations and nothing ties their return values together. A divergence would mean: the
  tally arithmetic (lines 41-56) and the `VoteCast` event (line 60) are computed from one value, while
  the early-execution eligibility gate (line 68, `> 0`) is decided from a second, independently-returned
  value for the same nominal query. Whether such a divergence "matters" is a question of what the second
  call gates — it gates only whether `_execute` runs in *this* transaction; it does not feed back into
  the tally, which was already finalized using the first call's value before line 68 is reached (I2).

### `_canExecute(_proposalId)` (`Proposal.sol:91-107`), called at `Votes.sol:67`

Pure `view` function over `proposal_` storage plus one further external call
(`isSupportThresholdReachedEarly` → `proposalVotingToken.getPastTotalSupply(...)`,
`Proposal.sol:161-170`) when the proposal is still open and in `EarlyExecution` mode. Walked all
branches:
- `proposal_.executed` true → `false` (`Proposal.sol:95-97`).
- Still open and mode isn't `EarlyExecution` → `false` (`Proposal.sol:102-104`), so Standard/
  VoteReplacement proposals can never early-execute from `_vote`'s `_tryEarlyExecution` branch — the
  second `getPastVotes` call at line 68 is only ever reached for `EarlyExecution`-mode proposals still
  open, or for any-mode proposals already past `endDate`.
- Otherwise defers to `_hasSucceeded` (`Proposal.sol:106`), which itself branches on `isOpen` and
  requires participation/approval thresholds. No path in `_canExecute` writes state; it is read-only, so
  calling it does not itself create additional reentrancy surface, but it does perform the
  `getPastTotalSupply` external call noted above, on the *same* untrusted `proposalVotingToken`.

### `_execute(_proposalId)` (`Proposal.sol:59-74`), called at `Votes.sol:70`

Sets `proposal_.executed = true` (`Proposal.sol:62`) *before* invoking the DAO's configured executor
with the proposal's stored actions (`Proposal.sol:64-70`, external call to `target` via the inherited
`_execute` executor helper). This happens strictly after all of `_vote`'s own state writes to
`proposal_.tally` and `proposal_.voters[_voter]` (lines 41-58), so a reentrant call back into
`vote()`/`_vote()` for the *same* proposal from within the DAO action execution would see
`proposal_.executed == true` and be rejected by `_isProposalOpen` (`Proposal.sol:251-256`, checks
`!proposal_.executed`) → `_canVote` returns `false` → `vote()` reverts before reaching `_vote`. A
reentrant call targeting a *different* proposal is not restricted by anything in `_vote` (no
proposal-level or contract-level reentrancy guard is visible in `Votes.sol`, `Proposal.sol`, or
`Settings.sol`).

## State mutations

- `proposal_.tally.yes` / `.no` / `.abstain` — read-modify-write, at most one bucket decremented and at
  most one incremented per call (`Votes.sol:41-56`).
- `proposal_.voters[_voter]` — unconditionally overwritten with `_voteOption` (`Votes.sol:58`), including
  overwriting with `VoteOption.None`.
- `proposal_.executed` — potentially set `true` via `_execute` (`Proposal.sol:62`), only reachable when
  `_tryEarlyExecution` is `true` and both the `_canExecute` and post-vote `getPastVotes > 0` conditions
  hold (`Votes.sol:66-70`).
- No revert path exists inside `_vote` itself once entered — every branch is a plain conditional; the
  function can only "fail" by an underlying `getPastVotes`/`getPastTotalSupply`/`_execute` call
  reverting, or by the checked-arithmetic subtraction at lines 42/44/46 underflowing (reverts in
  Solidity 0.8.x) if A1 is violated.

## Reentrancy / ordering note on `state` vs. `votingPower`

`votingPower` is fetched (line 37, external call) strictly before `state` is read from storage (line
38). If the external call at line 37 were able to reenter `_vote` for the same `(_proposalId, _voter)`
before returning — which the Callee analysis shows is not possible for the genuine OZ token, but is not
excluded for an arbitrary configured token — the reentrant call would run to completion (including its
own read of `state`, its own tally update, and its own write to `proposal_.voters[_voter]` at line 58)
before the outer call's line 38 executes. The outer call's `state` read would then observe the
*reentrant* call's freshly-written value rather than the value that existed when the outer call began,
while the outer call's `votingPower` (already captured in a local variable before the reentrancy could
occur) reflects whatever the token returned on the outer call's own invocation. Nothing in `_vote`
pins `state` to the value that existed at function entry.

## Open questions

- Whether any deployment configuration or governance process outside this repo could realistically
  result in `proposal_.parameters.votingToken` pointing at a contract other than a genuine
  `ERC721VotesUpgradeable`/`GovernanceERC721` instance — i.e., how strong is the trust assumption on the
  holder of `UPDATE_VOTING_SETTINGS_PERMISSION_ID` in practice. `_updateVotingToken`
  (`Settings.sol:194-210`) only checks `ERC165` self-reported interface support, not bytecode or
  behavior.
  - Actually confirmed from source: nothing beyond `supportsInterface` checks the token's
    implementation, and no on-chain mechanism restricts `_token` to a known-good codehash. This remains
    open only in the sense of "how permissioned/trusted is that role by design," not in the sense of
    "does the code check more than this" — it does not, as shown above.
- Whether `_vote` is expected to ever be called directly by a future override without going through
  `_canVote` (e.g., a batch-voting extension). No such caller exists in `src/` today
  (confirmed via `Grep` for `_vote(` across `src/`), so A2/A3 currently hold in practice, but nothing in
  `_vote`'s own body would catch a future violation.
- Whether `proposal_.parameters.snapshotTimepoint == 0` for a genuinely nonexistent proposal is fully
  excluded on the `_vote` path by `_isProposalOpen`'s date check alone, or whether some configuration of
  `startDate == 0 && endDate == 0` could coincide with an uninitialized proposal in a way that isn't
  simply "always closed." From `_validateProposalDates` (`Proposal.sol:388-431`), `endDate` is always
  derived from a nonzero `startDate + minDuration` with `minDuration >= 60 minutes`
  (`Settings.sol:132-134`), so a real proposal always has `endDate > 0`; a zero-initialized
  (nonexistent) proposal has `endDate == 0`, and `_isProposalOpen` requires `currentTime < endDate`,
  which fails for `endDate == 0` — this appears to close the gap, but is included here as a traced-not-
  exhaustively-fuzzed claim rather than a proven invariant.
