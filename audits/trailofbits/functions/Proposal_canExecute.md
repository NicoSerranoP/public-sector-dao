## `_canExecute` in src/base/Proposal.sol (L91-107)

**Purpose:** The single gate that decides whether a proposal is allowed to run its actions. It is the
choke point reached from three places — the public `canExecute` view (L76-85), the public `execute`
state-changing entrypoint (L43-55), and `Votes._vote`'s optional early-execution attempt
(`src/base/Votes.sol` L62-71) — so every execution path in the system, whether triggered explicitly or as a
side effect of the last vote cast, funnels through this one function. Its correctness rests almost entirely
on its callee `_hasSucceeded` (L121-152), which itself fans out to four more view functions; the two are
analyzed together here because `_canExecute` contains only one real branch of its own (L102-104) and the
rest of the state-machine logic — what "succeeded" means per voting mode and per open/closed state — lives
in `_hasSucceeded`.

**Inputs & Assumptions:**
- `_proposalId` (uint256): Trust: **untrusted** — the two callers that reach `_canExecute` without a prior
  existence check (`execute` at L43, and `Votes._vote` at L67) do not gate on `_proposalExists`. See "Callers"
  below for why a nonexistent proposal is still handled safely.
- Implicit: `proposals[_proposalId]` storage (`executed`, `parameters.votingMode`, `parameters.startDate`,
  `parameters.endDate`, `tally.*`), and `block.timestamp` (read inside `_isProposalOpen`, L252).
- Precondition (undocumented in this function, assumed by design): `proposal_.parameters.votingMode`,
  `.supportThreshold`, `.snapshotTimepoint`, `.votingToken`, `.minVotingPower`, and `proposal_.minApprovalPower`
  are fixed for the lifetime of the proposal once `createProposal` runs (L312-320). Established by: no other
  function in this file, in `Votes.sol`, or in `Settings.sol` writes any of these fields after L312-320 —
  `updateVotingSettings` (`Settings.sol` L109-115) only changes the *global* `votingSettings`, which is
  copied by value into a proposal only at creation (L316-318), so retroactive changes to global settings do
  not touch existing proposals.
- Precondition: `proposal_.tally.{yes,no,abstain}` are written only by `Votes._vote` (`Votes.sol` L42-56);
  confirmed by grep — no other assignment site to `.tally.` exists in `src/`. `_canExecute`/`_hasSucceeded`
  never write it themselves (both are `view`).

**Outputs & Effects:**
- Pure `view` function; returns `bool`. No state writes, no events, no external calls of its own (calls made
  inside `_hasSucceeded` are discussed there).
- Callers treat `true` as "safe to call `_execute`, which sets `proposal_.executed = true` and dispatches
  actions" (L54, L59-74; and `Votes.sol` L70).

**Block-by-Block:**

```solidity
// L94-97
if (proposal_.executed) {
    return false;
}
```
- **What:** Refuses to re-execute an already-executed proposal.
- **Why here:** First check, cheapest, and it makes every later read of `proposal_.executed` inside
  `_isProposalOpen` (L255, `&& !proposal_.executed`) redundant for this call path specifically — by the time
  L99 runs, `proposal_.executed` is already known `false`.
- **Assumes:** `proposal_.executed` is only ever set `true` in `_execute` (L62) and never reset. Confirmed by
  grep: `_execute` is the only writer of `.executed`.
- **Establishes:** `proposal_.executed == false` for the remainder of the function.
- **Depended on by:** L99 (via `_isProposalOpen`), and semantically by callers relying on "one proposal executes
  at most once."

```solidity
// L99
bool isProposalOpen = _isProposalOpen(proposal_);
```
- **What:** Computes whether the proposal is currently inside its voting window.
- **Why here:** Both later branches (L102 and the dispatch into `_hasSucceeded`) need this value, and it is
  computed once rather than twice.
- **Assumes:** `_isProposalOpen` correctly reflects `[startDate, endDate)` — see callee analysis below.
- **Establishes:** the boolean driving both the local gate (L102) and the mode selection inside
  `_hasSucceeded` (L124, L128).
- **Depended on by:** L102, L106.

```solidity
// L101-104
// For Standard and VoteReplacement modes, enforce waiting until end date
if (proposal_.parameters.votingMode != VotingMode.EarlyExecution && isProposalOpen) {
    return false;
}
```
- **What:** For the two non-early modes, refuses execution while the vote is still open, independent of the
  current tally.
- **Why here:** After the open/closed determination, before the (more expensive) success computation.
- **Assumes:** `VotingMode.EarlyExecution` is the only mode for which a result can be considered final before
  `endDate`. This is a design assumption, not something this line derives from anything else.
- **Establishes:** for the rest of this call, either `votingMode == EarlyExecution` or `isProposalOpen ==
  false` holds when `_hasSucceeded` is reached at L106.
- **Depended on by:** L106 — but see Cross-Function Dependencies: this exact condition is *also* re-checked
  inside `_hasSucceeded` (L128), independently, so this gate is not the only place the rule is enforced.

```solidity
// L106
return _hasSucceeded(_proposalId, isProposalOpen);
```
- **What:** Delegates the actual success determination, carrying forward the already-computed open/closed
  flag rather than letting the callee recompute it.
- **Why here:** Last statement; nothing after it needs the result.
- **Assumes:** `_hasSucceeded`'s `_isOpen` parameter faithfully reflects reality — it does, since it is the
  same `isProposalOpen` computed at L99 from the same storage, with no state change in between (view call, no
  reentrancy point).
- **Establishes:** the return value of `_canExecute`.
- **Depended on by:** every caller (`canExecute`, `execute`, `Votes._vote`).

**`_hasSucceeded` in src/base/Proposal.sol (L121-152) — full walk, since `_canExecute`'s correctness is
inseparable from it:**

```solidity
// L124-134
if (_isOpen) {
    if (proposal_.parameters.votingMode != VotingMode.EarlyExecution) {
        return false;
    }
    if (!isSupportThresholdReachedEarly(_proposalId)) {
        return false;
    }
} else {
    // L138-140
    if (!isSupportThresholdReached(_proposalId)) {
        return false;
    }
}
```
- **What:** Chooses which support-threshold test applies, keyed on `_isOpen` and, when open, on
  `votingMode`.
- **Why here:** This is the only place in the two functions where "early" vs. "final" success is actually
  decided; `isSupportThresholdReached` (final, closed-form, using the *actual* `tally.no`) is used whenever
  the proposal is closed **regardless of voting mode** — `isSupportThresholdReachedEarly` (worst-case bound)
  is used *only* when both open and `EarlyExecution`.
- **Assumes:** see the dedicated subsection below on `isSupportThresholdReachedEarly` — the open-branch here
  assumes that a `true` result from the worst-case check now implies the closed-form check would also pass,
  both now and at the real `endDate`.
- **Establishes:** for the lines that follow (L143, L147), a proposal that reaches them has satisfied whichever
  support-threshold flavor was appropriate for its state.
- **Note on redundancy:** L128-130 duplicates `_canExecute`'s own gate at L102-104 (`votingMode !=
  EarlyExecution && isOpen ⇒ fail`). The two are separate copies of the same rule: `_canExecute`'s copy exists
  so `canExecute`/`execute` short-circuit before calling `_hasSucceeded` at all, while `_hasSucceeded`'s own
  copy exists because `hasSucceeded` (L110-115, the public `IProposal` view) calls `_hasSucceeded` directly,
  **without** going through `_canExecute`'s gate or its `executed`-flag check. Both copies must independently
  say "not EarlyExecution and open ⇒ no early success," and nothing ties them together beyond both currently
  reading the same enum comparison; an edit to one without the matching edit to the other would make
  `canExecute(id)` and `hasSucceeded(id)` disagree about whether an open, non-early-execution proposal has
  succeeded (currently they agree: both say no).

```solidity
// L143-149
if (!isMinParticipationReached(_proposalId)) {
    return false;
}
if (!isMinApprovalReached(_proposalId)) {
    return false;
}
```
- **What:** Applies participation and approval floors identically regardless of open/closed state or voting
  mode.
- **Why here:** After the support-threshold branch, so a proposal must clear all three bars.
- **Assumes:** unlike the support-threshold check, there is **no "worst-case" open-state variant** for
  participation or approval — when called while open (only reachable in EarlyExecution mode, per the branch
  above), these two functions measure the *current* tally, not a bound on where it could still go. Executing
  early therefore locks in whatever participation/approval level exists at the moment of the early-execution
  call; it does not need to (and cannot) anticipate further increases.
- **Establishes:** the final two legs of the "succeeded" definition.
- **Depended on by:** L151's unconditional `return true`.

```solidity
// L151
return true;
```
- **What:** All three checks passed.
- **Depended on by:** `_canExecute`'s L106 return, and `hasSucceeded`'s L114 return.

**Combinations of `votingMode` x `isProposalOpen` (the full state-space `_canExecute` walks through
`_hasSucceeded`):**

| `votingMode` | `isProposalOpen` | Path taken | What must hold |
|---|---|---|---|
| Standard | `true` | `_canExecute` returns `false` at L103; `_hasSucceeded` is never called from this path. (If reached directly via `hasSucceeded()`, L128-130 would also return `false`.) | n/a |
| Standard | `false` | `_hasSucceeded(id, false)`: closed branch, L138 | `isSupportThresholdReached` (final `tally.no`) + `isMinParticipationReached` + `isMinApprovalReached`, all on final tallies |
| VoteReplacement | `true` | Same as Standard/`true` — blocked at L103 | n/a |
| VoteReplacement | `false` | Same as Standard/`false` | Same three checks on final tallies (votes can no longer be swapped once closed, since `_canVote`/`_isProposalOpen` also gate voting — `Votes.sol` L103) |
| EarlyExecution | `true` | `_canExecute` skips L103 (condition false); `_hasSucceeded(id, true)` open branch, L128 passes (mode matches), L132 | `isSupportThresholdReachedEarly` (worst-case bound) + `isMinParticipationReached` + `isMinApprovalReached` on **current, not worst-case,** tallies |
| EarlyExecution | `false` | `_canExecute` skips L103 (`isProposalOpen` false); `_hasSucceeded(id, false)` closed branch, L138 | Identical to the Standard/closed row — `isSupportThresholdReachedEarly` is **never** used once a proposal is closed, for any mode; it is exclusively an early/open-state mechanism |

**Is skipping the closed-form check while EarlyExecution+open sound?** `_hasSucceeded` never evaluates
`isSupportThresholdReached` (L138) on the EarlyExecution/open path — only `isSupportThresholdReachedEarly`
(L132) runs. This is sound *for the instant the check runs*, because `isSupportThresholdReachedEarly`'s
`noVotesWorstCase` (`getPastTotalSupply(snapshot) - tally.yes - tally.abstain`, L165-166) is always `>=` the
actual `tally.no` at that moment (since `yes + no + abstain <= totalSupply`, assuming the token's own
accounting is correct — see the callee note below). So
`(RATIO_BASE - supportThreshold) * yes > supportThreshold * noVotesWorstCase` implies
`(RATIO_BASE - supportThreshold) * yes > supportThreshold * tally.no`, i.e. the skipped closed-form
inequality would also currently hold, using the same `tally.yes`/`tally.no` that `isSupportThresholdReached`
would read. Whether it *stays* true through the real `endDate` — which is the property the "early execution"
feature is actually selling — is a separate question, addressed next; nothing in `_hasSucceeded` or
`isSupportThresholdReached`/`isSupportThresholdReachedEarly` re-checks it later, since a `true` return from
`_canExecute` is consumed immediately by `_execute` in the same transaction (L54; `Votes.sol` L66-70) and the
proposal is marked `executed` before any further voting could occur.

**Cross-Function Dependencies:**

- **Callee `_isProposalOpen` (internal, L251-256):** read in full.
  ```solidity
  function _isProposalOpen(Proposal storage proposal_) internal view virtual returns (bool) {
      uint64 currentTime = block.timestamp.toUint64();
      return proposal_.parameters.startDate <= currentTime && currentTime < proposal_.parameters.endDate
          && !proposal_.executed;
  }
  ```
  - Single path, no branches that skip the `executed` check. Returns `true` only for the half-open window
    `[startDate, endDate)`, and only if not executed.
  - `_canExecute` calls it at L99 *after* already returning early for `executed == true` (L95-97), so the
    `&& !proposal_.executed` clause (L255) is dead weight specifically on this call path — it matters for the
    other callers of `_isProposalOpen` that don't pre-check `executed`: `hasSucceeded` (L112, no `executed`
    pre-check), `getProposal` (L239), and `Votes._canVote` (`Votes.sol` L103).
  - `block.timestamp.toUint64()` (`SafeCastUpgradeable`) reverts if `block.timestamp` exceeds `type(uint64).max`
    — not reachable before the year ~584,942,417,355, so not a practical path, but structurally it is a revert
    path rather than a boolean, meaning `_canExecute` (and everything built on it) can revert instead of
    returning `false` in that (unreachable) circumstance.
  - `_canExecute` depends on this callee to establish: the open/closed classification used to select which
    branch of `_hasSucceeded` runs. Established on its one and only path — no partial-establishment concern
    here.

- **Callee `_hasSucceeded` (internal, L121-152):** analyzed block-by-block above. `_canExecute` depends on it
  to establish the actual "did this proposal pass" determination for whichever open/closed + mode combination
  applies. All four sub-paths (open+EarlyExecution, open+other via L128 fast-fail, closed regardless of mode)
  return a definite `bool`; there is no path through `_hasSucceeded` that falls through without returning
  (every branch either returns `false` early or reaches L151's `return true`).

- **Callee `isSupportThresholdReached` (public, L154-159):**
  ```solidity
  return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
      > proposal_.parameters.supportThreshold * proposal_.tally.no;
  ```
  - Single expression, no branches. Reads live storage `tally.yes`/`tally.no` — "final" only in the sense that
    `_hasSucceeded` calls it exclusively when `_isOpen == false`, at which point no further votes can be cast
    (`Votes._canVote` gates on the same `_isProposalOpen`, `Votes.sol` L103), so the tally it reads is
    genuinely frozen. Nothing in this function itself checks that voting has actually stopped — that
    guarantee is entirely supplied by the caller passing `_isOpen == false`, which in turn is entirely
    supplied by `_isProposalOpen`.
  - `proposal_.parameters.supportThreshold ∈ [1, RATIO_BASE-1]` is established by `Settings._updateVotingSettings`
    (`Settings.sol` L122-124), called from both `initialize` (`NFTVoting.sol` L49) and
    `updateVotingSettings` (`Settings.sol` L109-115) — never bypassed, since `votingSettings` (`Settings.sol`
    L36) has no other writer than L162 inside that function. This is why `RATIO_BASE - supportThreshold` never
    underflows/is never zero.

- **Callee `isSupportThresholdReachedEarly` (public, L161-170):**
  ```solidity
  uint256 noVotesWorstCase = proposalVotingToken.getPastTotalSupply(proposal_.parameters.snapshotTimepoint)
      - proposal_.tally.yes - proposal_.tally.abstain;
  return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
      > proposal_.parameters.supportThreshold * noVotesWorstCase;
  ```
  - **External call** to `IVotesUpgradeable(proposal_.parameters.votingToken).getPastTotalSupply(...)`
    (line 165) — `proposalVotingToken` is whatever address was stored as the *global* `votingToken` at the
    moment this specific proposal was created (`Proposal.sol` L315,
    `Settings._updateVotingToken` L194-210), which validates ERC-165 support for `IERC721Upgradeable` and
    `IVotesUpgradeable` (L196-203) but cannot verify the *semantics* of `getPastTotalSupply`/`getPastVotes`
    beyond interface conformance. Trust: **external, semi-trusted** — permissioned to set
    (`UPDATE_VOTING_SETTINGS_PERMISSION_ID`), but its checkpoint arithmetic is taken on faith once installed.
  - Subtraction `totalSupply - yes - abstain` is unchecked-by-code but protected by Solidity 0.8's default
    checked arithmetic: it **reverts** (rather than wrapping) if `tally.yes + tally.abstain` ever exceeds
    `getPastTotalSupply(snapshot)`. That can only happen if the token's own accounting lets voting power
    assigned via `getPastVotes` at the snapshot exceed its own `getPastTotalSupply` at the same snapshot — an
    assumption about the external token's internal consistency that nothing in this codebase checks or
    enforces (`nothing found` inside `Proposal.sol`/`Votes.sol`).
  - This is the function `_hasSucceeded` depends on, while open, to bound how much the outcome can still move.
    It depends on `getPastTotalSupply(snapshotTimepoint)` returning the **same** value every time it is
    called for a given proposal (i.e., that a past checkpoint, once finalized, is immutable in the token
    contract). That is a property of the external `IVotesUpgradeable` implementation, not of anything in this
    repository — `nothing found` here that would detect or defend against a token whose historical checkpoints
    are not actually immutable.

- **The "does `isSupportThresholdReachedEarly==true` stay true through `endDate`" question:** `_hasSucceeded`
  and `isSupportThresholdReachedEarly` do not themselves guarantee this — both simply recompute from current
  storage on every call, with no memoized "locked-in" state. The property that makes early execution
  *meaningful* (that if the DAO had instead waited for `endDate`, `isSupportThresholdReached` would still
  return `true`) reduces to three facts, none of which live in this file:
  1. `proposal_.parameters.votingMode`, `.supportThreshold`, `.snapshotTimepoint` are fixed at creation and
     never rewritten (`Proposal.sol` L312-320; confirmed no other writer of `proposal_.parameters.*` exists).
  2. `getPastTotalSupply(snapshotTimepoint)` is queried against a point already in the past and is assumed
     immutable there (external assumption, see above).
  3. `tally.yes` and `tally.abstain` are **monotonically non-decreasing** for the lifetime of an
     `EarlyExecution`-mode proposal. This is *not* enforced anywhere in `Proposal.sol`. It is a side effect of
     `Votes._canVote` (`Votes.sol` L118-123):
     ```solidity
     if (
         proposal_.voters[_account] != VoteOption.None
             && proposal_.parameters.votingMode != VotingMode.VoteReplacement
     ) {
         return false;
     }
     ```
     which refuses a second vote from the same account whenever the mode is not `VoteReplacement` — and
     `EarlyExecution != VoteReplacement`, so once an account votes Yes or Abstain in an `EarlyExecution`
     proposal, it can never later vote No or retract, because it can never vote again. Given that, for
     `EarlyExecution` proposals: `final_no <= totalSupply - final_yes - final_abstain <= totalSupply -
     yes_now - abstain_now == noVotesWorstCase_now` (since `final_yes >= yes_now`, `final_abstain >=
     abstain_now`). That inequality chain is what actually makes "early" execution equivalent to "would have
     succeeded at `endDate` anyway" — but it is **assumed by `_hasSucceeded`, established by `Votes.sol`, and
     not visible from, checked by, or re-derived anywhere in `Proposal.sol` itself.** Both `Votes._vote`
     (`Votes.sol` L29-32) and `Votes._canVote` (`Votes.sol` L93-98) are declared `virtual`; an override in any
     derived contract that permits a second vote, a retraction, or a switch away from Yes/Abstain while
     `votingMode == EarlyExecution` would silently invalidate this monotonicity, and nothing in `Proposal.sol`
     would detect it — `_hasSucceeded` would keep computing `isSupportThresholdReachedEarly` from whatever
     `tally` currently holds, oblivious to whether that tally could still move backward.
  - The same monotonicity argument also covers `isMinParticipationReached`/`isMinApprovalReached` when
    evaluated on the EarlyExecution/open path (L143, L147): `tally.yes+no+abstain` and `tally.yes` alone are
    both non-decreasing under the same `Votes.sol` L118-123 guard, so once those two checks pass while open in
    `EarlyExecution` mode, they cannot later fail by `endDate` either — again, an invariant this file consumes
    but does not establish.
  - For `VoteReplacement` mode this monotonicity does **not** hold — `Votes._vote` L41-47/50-56 lets `tally.yes`
    decrease when a voter switches away from Yes — but that is not a problem for `_hasSucceeded`, because
    `_canExecute` never lets `_hasSucceeded` evaluate anything but the closed-form branch for
    `VoteReplacement` (it is always blocked by L102-104 while open), and by the time it is closed no further
    switching is possible (`Votes.sol` L103 gates on `_isProposalOpen`).

- **Callee `isMinParticipationReached` (public, L172-180):**
  ```solidity
  function isMinParticipationReached(uint256 _proposalId) public view virtual returns (bool) {
      if (!_proposalExists(_proposalId)) {
          return false;
      }
      Proposal storage proposal_ = proposals[_proposalId];
      return proposal_.tally.yes + proposal_.tally.no + proposal_.tally.abstain >= proposal_.parameters.minVotingPower;
  }
  ```
  - Two paths: nonexistent proposal ⇒ `false`; existing proposal ⇒ live sum vs. `minVotingPower` (fixed at
    creation, `Proposal.sol` L318, via `_applyRatioCeiled`, ceiling-rounded in favor of a stricter bar). No
    path leaves an ambiguous result. The `_proposalExists` re-check here is redundant when reached through
    `_canExecute`/`_hasSucceeded` (existence is implied by the proposal having non-zero
    `snapshotTimepoint`/being processed at all — see "nonexistent proposal" note under Callers), but it is not
    redundant when this function is called directly by an external caller with an arbitrary `_proposalId`.

- **Callee `isMinApprovalReached` (public, L182-188):** same two-path shape as above, comparing
  `tally.yes >= minApprovalPower` (fixed at creation, L320). Same redundant-but-harmless existence re-check.

- **Callers of `_canExecute`:**
  - `canExecute` (public view, L76-85): guarded by `onlyIfProposalExists` (L81, L34-39) — nonexistent-`_proposalId`
    calls revert with `NonexistentProposal` before `_canExecute` runs.
  - `execute` (public, L43-55): **not** guarded by `onlyIfProposalExists`. For a nonexistent proposal,
    `proposal_.parameters` is all zero, so `_isProposalOpen` returns `false` (startDate `0 <= now` true, but
    `now < endDate(0)` false) and `votingMode` defaults to `Standard` (enum zero value); `_canExecute` reaches
    `_hasSucceeded(id, false)`, whose closed branch calls `isSupportThresholdReached` with `tally.yes ==
    tally.no == 0`, giving `0 > 0 == false`, so `_canExecute` returns `false` without reverting. `execute`'s
    `||` short-circuits (L47-50) before ever calling `proposalVotingToken.getPastVotes(...)` on the zero
    address, so no revert-on-external-call occurs either. The safety of this path is an emergent consequence
    of zero-initialized storage plus the strict `>` in `isSupportThresholdReached`, not an explicit guard —
    established implicitly, not by a checked precondition.
  - `Votes._vote` (`Votes.sol` L66-71): calls `_canExecute` after already updating `tally` in the same
    transaction (L38-58), so the tally `_canExecute` reads is the just-written one; no reentrancy window
    between the vote write and the execution check.

- **Shared state:** `proposals[_proposalId].tally` — written only by `Votes._vote`; read by
  `isSupportThresholdReached`, `isSupportThresholdReachedEarly`, `isMinParticipationReached`,
  `isMinApprovalReached`. `proposals[_proposalId].executed` — written only by `Proposal._execute` (L62); read by
  `_canExecute` (L95) and `_isProposalOpen` (L255). `proposals[_proposalId].parameters.*` — written only by
  `createProposal` (L312-320); read throughout.

- **Invariant couplings:** The soundness of "early execution" as a concept (not of any single call to
  `_canExecute`, which is always internally consistent with the storage it reads at call time) couples three
  independently-maintained facts: `votingMode` immutability (`Proposal.sol`), checkpoint immutability
  (external token), and vote non-retraction in non-`VoteReplacement` modes (`Votes.sol`). All three currently
  hold given the code in this repository, but only the first is enforced *within* `Proposal.sol`; the third is
  enforced in a sibling, separately-overridable contract, and the second is entirely external.

**Open Questions:**
- unclear; need to inspect whether any derived/override contract in this repo (or intended for future
  deployment on top of this base) overrides `Votes._vote` or `Votes._canVote` in a way that would permit
  vote retraction or replacement while `votingMode == EarlyExecution`, which is the one thing that would break
  the monotonicity `isSupportThresholdReachedEarly`'s soundness depends on. Grep of `src/` shows no such
  override today, but `_vote`/`_canVote` are declared `virtual` (`Votes.sol` L29-32, L93-98) and nothing in
  `Proposal.sol` re-verifies the property, so this is a property of the current inheritance tree, not of
  `Proposal.sol`'s own logic.
- unclear; need to inspect the concrete `votingToken` contract(s) this plugin is deployed against (e.g.
  `GovernanceERC721`, `src/erc721/GovernanceERC721.sol`) to confirm `getPastTotalSupply`/`getPastVotes`
  checkpoints are truly immutable once in the past, and that per-account voting power summed across all
  accounts can never exceed `getPastTotalSupply` at the same timepoint — `isSupportThresholdReachedEarly`
  (L165-166) reverts on underflow if that invariant is ever violated by the token.
- unclear; need to inspect whether `canExecute(id)` and `hasSucceeded(id)` are ever compared or relied upon
  to agree by any off-chain integration or governance UI, given that they currently agree only because the
  mode/open gate is independently duplicated at L102-104 and L128-130 rather than shared via one code path.
