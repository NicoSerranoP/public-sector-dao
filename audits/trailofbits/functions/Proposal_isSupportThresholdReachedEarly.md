## `isSupportThresholdReachedEarly` in src/base/Proposal.sol (L161-170)

```solidity
// L161-170
function isSupportThresholdReachedEarly(uint256 _proposalId) public view virtual returns (bool) {
    Proposal storage proposal_ = proposals[_proposalId];
    IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);

    uint256 noVotesWorstCase = proposalVotingToken.getPastTotalSupply(proposal_.parameters.snapshotTimepoint)
        - proposal_.tally.yes - proposal_.tally.abstain;

    return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
        > proposal_.parameters.supportThreshold * noVotesWorstCase;
}
```

**Purpose:** Decides, while a proposal is still open, whether the "yes" side has already mathematically
locked in a passing support ratio even if every unit of voting power that has not yet voted "yes"/"abstain"
were to vote "no". It is the gate that allows `EarlyExecution`-mode proposals to execute before `endDate`
(`_hasSucceeded`, L124-134). Without it, early execution would have no support-side safety check and could
fire on a proposal that could still be flipped by remaining voters.

**Inputs & Assumptions:**
- `_proposalId` (uint256): identifies a proposal. Trust: **untrusted** — the function is `public` and carries
  no `onlyIfProposalExists` guard (contrast with `isMinParticipationReached`/`isMinApprovalReached`, which
  self-check existence at L173-175/L183-185, and with `canExecute`/`hasSucceeded`, which are guarded by the
  `onlyIfProposalExists` modifier at L81/L110). For a non-existent proposal, `proposal_.parameters` is the
  zero-valued struct, so `proposal_.parameters.votingToken == address(0)` (L163); the subsequent external call
  at L165 targets `address(0)`, which has no code, so ABI-decoding the expected `uint256` return reverts. Net
  effect: a non-existent `_proposalId` reverts rather than returning a wrong boolean, but this is incidental
  to the missing-code revert semantics, not an explicit check in this function.
- Implicit state read: `proposals[_proposalId].parameters` (`votingToken`, `snapshotTimepoint`,
  `supportThreshold`) and `proposals[_proposalId].tally` (`yes`, `abstain`) — all per-proposal storage,
  frozen at creation time except `tally`, which is mutated by `_vote` (Votes.sol L29-72).
- Precondition (unenforced by this function): `getPastTotalSupply(proposal_.parameters.snapshotTimepoint) >=
  proposal_.tally.yes + proposal_.tally.abstain`, required so the subtraction at L165-166 does not revert
  under Solidity 0.8 checked arithmetic. See "Cross-Function Dependencies" for where this is actually
  established (in `_vote`'s bookkeeping plus the external token's own accounting) and where it is not (this
  function performs no defensive check of its own).
- Precondition: `proposal_.parameters.supportThreshold <= RATIO_BASE - 1`, so `RATIO_BASE -
  proposal_.parameters.supportThreshold >= 1` and does not underflow at L168. Established by
  `_updateVotingSettings` (`src/base/Settings.sol:L122-124`, `require(supportThreshold != 0 && supportThreshold
  <= RATIO_BASE - 1)`), and copied into the proposal at creation (`Proposal.sol:L317`,
  `proposal_.parameters.supportThreshold = supportThreshold()`). Not re-validated here.
- Environment: none beyond the storage reads and one external view call; no `msg.sender`/`block.*` dependence
  inside this function itself.

**Outputs & Effects:**
- Pure `view`, returns a `bool`; no state writes, no events.
- One external call: `proposalVotingToken.getPastTotalSupply(proposal_.parameters.snapshotTimepoint)` (L165),
  a `view` call on `IVotesUpgradeable(proposal_.parameters.votingToken)`.
- Reverts (does not return `false`) if the subtraction at L165-166 underflows, or if the external call fails
  (e.g., target has no code, or the token itself reverts).

**Block-by-Block:**

```solidity
// L163
IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);
```
- **What:** Casts the address stored in the proposal's own parameters, not the plugin-wide token, to
  `IVotesUpgradeable`.
- **Why here:** This is the field that must be read for the arithmetic below to be self-consistent — see next
  block.
- **Assumes:** `proposal_.parameters.votingToken` was captured once, at proposal-creation time, from the
  plugin-wide `votingToken` state variable (`Settings.sol:L39`) via `proposal_.parameters.votingToken =
  address(votingToken)` (`Proposal.sol:L315`), and is never rewritten afterward — there is no setter for
  `proposal_.parameters.votingToken` anywhere in the contracts read for this analysis (`Proposal.sol`,
  `Votes.sol`, `Settings.sol`).
- **Establishes:** that this function (and `execute`, L45, and `_vote`, `Votes.sol:L34/L100`) always queries
  the *same* token contract that produced every `getPastVotes` value folded into `proposal_.tally` for this
  proposal, even if the DAO later calls `updateVotingToken` (`Settings.sol:L178-210`) to point the
  plugin-wide `votingToken` (`Settings.sol:L39`) at a different contract. If this line instead read the
  plugin-wide `votingToken` directly, a token swap mid-proposal-lifetime would query total supply of an
  unrelated contract at the same numeric `snapshotTimepoint`, with no relationship to `tally.yes`/`tally.abstain`,
  and the non-underflow property below would not hold.
- **Depended on by:** L165 (the external call) and, more importantly, by every place that computed
  `proposal_.tally.yes`/`.abstain` (`Votes.sol:L37,42,51,55` all key off `proposal_.parameters.votingToken`
  too), which is what keeps the two sides of the subtraction referring to the same token.

```solidity
// L165-166
uint256 noVotesWorstCase = proposalVotingToken.getPastTotalSupply(proposal_.parameters.snapshotTimepoint)
    - proposal_.tally.yes - proposal_.tally.abstain;
```
- **What:** Computes the maximum voting power that could still end up on the "no" side: total supply at the
  snapshot, minus everything already locked into "yes" or "abstain".
- **Why here:** This is the "worst case" the early-execution check must survive; it has to be computed before
  the comparison at L168-169 can be made.
- **Assumes:**
  1. `getPastTotalSupply(t)` for the fixed, already-past `t = proposal_.parameters.snapshotTimepoint` returns
     a value that is both (a) constant for the lifetime of the proposal and (b) an upper bound on the sum of
     every account's `getPastVotes(account, t)`. Neither property is enforced by this contract; both rest on
     the external token's implementation (see Cross-Function Dependencies).
  2. `proposal_.tally.yes + proposal_.tally.abstain <= getPastTotalSupply(t)`. This is the exact precondition
     for the subtraction not to revert under Solidity 0.8's checked arithmetic (no `unchecked` block wraps
     L165-166). Nothing in this function checks it directly; it is a derived property of how `tally.yes` and
     `tally.abstain` are accumulated in `_vote` (`Votes.sol:L29-72`) relative to how the token accounts for
     total supply. See Cross-Function Dependencies for the chain that is supposed to guarantee it, and the
     points at which that chain is only as strong as the external token.
- **Establishes:** `noVotesWorstCase`, an upper bound on the "no" tally that assumes every not-yet-committed
  unit of voting power eventually votes "no". Note this bound is computed independently of
  `proposal_.tally.no` — it does not add/verify against `tally.no`; it only needs `total - yes - abstain >=
  tally.no` to be a meaningful (not necessarily tight) worst case, and that holds automatically since `yes`,
  `no`, and `abstain` are mutually exclusive per-voter accumulations bounded by the same total (see below).
- **Depended on by:** L168-169, the only consumer.

```solidity
// L168-169
return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
    > proposal_.parameters.supportThreshold * noVotesWorstCase;
```
- **What:** Cross-multiplied comparison of `yes / (yes + noVotesWorstCase)` against `supportThreshold /
  RATIO_BASE`, avoiding division.
- **Why here:** Final step; mirrors `isSupportThresholdReached` (L154-158, `hasSucceeded`'s post-close
  variant) but substitutes the worst-case "no" figure for the actual, final one.
- **Assumes:** `RATIO_BASE - proposal_.parameters.supportThreshold` does not underflow (see Preconditions
  above) and that the two products do not overflow `uint256` — `tally.yes`/`noVotesWorstCase` are bounded by
  a token's total supply and `RATIO_BASE = 10**6` (`lib/osx-commons/contracts/src/utils/math/Ratio.sol:L6`),
  far short of `2**256`.
- **Establishes:** the function's return value, consumed by `_hasSucceeded` (L132) only when the proposal is
  still open and in `EarlyExecution` mode (L124-131), and also reachable directly by anyone since this
  function is `public` with no mode/open-state gating of its own.

**Cross-Function Dependencies:**

- **Callee `getPastTotalSupply` on `IVotesUpgradeable(proposal_.parameters.votingToken)`
  (external, source available for the concrete `GovernanceERC721`/OZ `Votes` implementation, otherwise a
  black box constrained only by two ERC-165 checks — see below):**
  - Interface: `IVotesUpgradeable.getPastTotalSupply` (`lib/openzeppelin-contracts-upgradeable/.../IVotesUpgradeable.sol:L40`)
    documents "This value is the sum of all available votes, which is not necessarily the sum of all delegated
    votes" — i.e., by contract, total supply is an upper bound on the sum of delegated votes, not necessarily
    equal to it.
  - Concrete implementation `VotesUpgradeable.getPastTotalSupply`
    (`lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/VotesUpgradeable.sol:L104-107`):
    `require(timepoint < clock()); return _totalCheckpoints.upperLookupRecent(timepoint);`. Two structural
    facts follow:
    1. Once `timepoint` (`proposal_.parameters.snapshotTimepoint`, fixed at creation, `Proposal.sol:L314`) is
       in the past, `_totalCheckpoints` is append-only (`_transferVotingUnits`, L170-176, only pushes new
       checkpoints keyed by the *current* `clock()`), so the returned value for that fixed `timepoint` never
       changes again — it is the same value whether read from `_vote`, `execute`, or here, at any later block.
    2. `_totalCheckpoints` is incremented only on mint (`from == address(0)`, L171-173) and decremented only
       on burn (`to == address(0)`, L174-176), each time by exactly the transferred `amount`. Every such
       change is paired, in the same call, with `_moveDelegateVotes` (L177, L183-202) moving at most that same
       `amount` into/out of a delegate's checkpoint. Consequently `getPastTotalSupply(t) >= getPastVotes(a, t)`
       for any single account `a`, and, by induction over all mint/burn events up to `t`, `getPastTotalSupply(t)
       >= Σ_a getPastVotes(a, t)`. This is the structural invariant `isSupportThresholdReachedEarly`'s
       subtraction depends on — but it is a property of `VotesUpgradeable`'s bookkeeping, established nowhere
       inside this plugin's own contracts.
  - `GovernanceERC721` (`src/erc721/GovernanceERC721.sol`) is the concrete voting-token implementation shipped
    with this plugin. It self-delegates any receiver with no prior delegate on every mint/transfer
    (`_afterTokenTransfer`, L161-172), so in practice every extant token's voting power is credited to some
    delegate, making `Σ_a getPastVotes(a,t) == getPastTotalSupply(t)` (equality, not just `<=`) for this
    specific token. This is a stronger guarantee than the interface requires but is not needed for the
    non-underflow property, which only needs the `>=` direction.
  - `_updateVotingToken` (`src/base/Settings.sol:L194-210`) only checks
    `IERC165Upgradeable.supportsInterface` for `IERC721Upgradeable` and `IVotesUpgradeable`
    (L196-203) before accepting a new plugin-wide `votingToken`. `supportsInterface` is self-reported by the
    target contract; it does not verify that `getPastTotalSupply`/`getPastVotes` are actually implemented per
    the `VotesUpgradeable` accounting described above. A token that reports these interfaces but implements
    `getPastTotalSupply` incorrectly (e.g., returning a value smaller than the sum of votes it also lets
    accounts claim via `getPastVotes` for the same timepoint) would violate the precondition at L165-166 with
    nothing in this plugin catching it before the fact — the failure mode would surface as a revert
    (arithmetic underflow) inside `isSupportThresholdReachedEarly`/`_vote`/`execute` rather than as a rejected
    `updateVotingToken` call.
  - Failure/other paths: if `proposal_.parameters.votingToken` has no code at call time (never deployed for a
    forged/nonexistent proposal, or self-destructed after being set), the external call reverts on ABI
    decoding rather than returning a value.

- **Callee `_vote` (internal, `src/base/Votes.sol:L29-72`) — the sole writer of `proposal_.tally`:** read in
  full. Relevant to the subtraction's safety:
  - `votingPower = proposalVotingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint)` (L37) uses
    the *same* `proposal_.parameters.votingToken` and the *same* `snapshotTimepoint` as
    `isSupportThresholdReachedEarly` — this pairing is what keeps the two sides of the L165-166 subtraction
    comparable.
  - Vote-replacement bookkeeping (L41-56) first subtracts the voter's previous contribution (looked up fresh
    via the same `getPastVotes` call, hence numerically identical to what was previously added) before adding
    the new one. Since `getPastVotes` for a fixed past timepoint is stable (same checkpoint-immutability
    argument as `getPastTotalSupply` above), the subtract-then-add sequence exactly cancels, so replacing a
    vote never inflates `tally.yes + tally.no + tally.abstain` beyond `Σ_a getPastVotes(a, snapshotTimepoint)`
    even under `VotingMode.VoteReplacement`.
  - `_canVote` (`Votes.sol:L93-126`) is the gate reached from both `vote()` (L18) and is itself the only path
    that can call `_vote`; it requires `proposal_.voters[_account] == VoteOption.None` unless
    `proposal_.parameters.votingMode == VotingMode.VoteReplacement` (L118-123), i.e., outside `VoteReplacement`
    mode each address contributes at most once. Combined with the previous point, for **any** voting mode,
    `tally.yes + tally.no + tally.abstain <= Σ_a getPastVotes(a, snapshotTimepoint) <=
    getPastTotalSupply(snapshotTimepoint)` (the last step from the token-callee analysis above), which gives
    `tally.yes + tally.abstain <= getPastTotalSupply(snapshotTimepoint)` — the exact precondition L165-166
    needs. This chain holds regardless of whether `isSupportThresholdReachedEarly` is invoked through
    `_hasSucceeded`'s `EarlyExecution`-only path (L128) or called directly (it is `public`) against a
    `Standard`/`VoteReplacement`-mode or already-closed proposal.
  - `_vote` itself performs no re-entrancy guard; its own comment at L36 ("This could re-enter, though we can
    assume the governance token is not malicious") flags `getPastVotes` as a potential re-entry vector during
    voting. This does not affect `isSupportThresholdReachedEarly` directly (it makes no state-changing calls),
    but note that both `_vote` (`Votes.sol:L34`) and `execute` (`Proposal.sol:L45`) independently reconstruct
    `IVotesUpgradeable(proposal_.parameters.votingToken)` from the same storage field this function reads, so
    all three sites are consistent with each other by construction (L315), not by any runtime check.

- **Callers:**
  - `_hasSucceeded` (`Proposal.sol:L121-152`) calls this only when `_isOpen && votingMode ==
    VotingMode.EarlyExecution` (L124-131), and only to gate `false` early — a `false` here short-circuits
    the rest of `_hasSucceeded` (participation/approval checks are skipped, L132-134). It assumes this
    function's `true` result means the "yes" side cannot be mathematically overtaken; that assumption rests on
    the `tally.yes + tally.abstain <= getPastTotalSupply(snapshotTimepoint)` chain above holding, plus the
    "worst case" framing itself being valid only because `EarlyExecution` mode also disallows vote replacement
    (`votingMode != VotingMode.VoteReplacement` is implied by `votingMode == VotingMode.EarlyExecution`, per
    the `VotingMode` enum at `INFTVoting.sol:L18-22` — these are mutually exclusive enum values), so a "yes" or
    "abstain" vote already cast cannot later be withdrawn or flipped to "no" during the same open period —
    enforced by `_canVote`'s single-vote-per-address rule (`Votes.sol:L118-123`) for any non-`VoteReplacement`
    mode.
  - No other in-repo caller found; it is `public virtual`, so any external account or contract can call it
    directly for any `_proposalId`, including ones for which `_hasSucceeded`'s gating conditions do not hold.

- **Shared state:** `proposals[_proposalId].tally` (written only by `_vote`, `Votes.sol:L42-56`) and
  `proposals[_proposalId].parameters` (written only once, at creation, `Proposal.sol:L312-320`). No other
  function in `Proposal.sol`/`Votes.sol`/`Settings.sol` mutates either after creation.

- **Invariant coupling:** The whole early-execution mechanism (`_canExecute`, L91-107, and `_hasSucceeded`,
  L121-152) is only sound if "already-cast yes/abstain votes are irrevocable for the remainder of the open
  period" — a property enforced by `_canVote`'s mode check, not by this function — and if
  `getPastTotalSupply`/`getPastVotes` on `proposal_.parameters.votingToken` behave as `VotesUpgradeable`
  specifies for the fixed `snapshotTimepoint`, a property enforced by the external token contract and only
  gestured at (via ERC-165 self-report) by `_updateVotingToken` (`Settings.sol:L195-203`).

**Open Questions:**
- unclear; need to inspect whether any deployment/registration path could set
  `proposal_.parameters.votingToken` to a token that reports the `IVotesUpgradeable`/`IERC721Upgradeable`
  interface IDs via ERC-165 (satisfying `Settings.sol:L196-203`) without actually implementing the
  `VotesUpgradeable` checkpoint accounting described above (e.g., a proxy or mock in test/deployment
  configurations) — that is the scenario in which `getPastTotalSupply(snapshotTimepoint) <
  tally.yes + tally.abstain` becomes reachable and L165-166 reverts.
- unclear; need to inspect whether `proposal_.parameters.votingToken`'s contract can ever be removed from
  the chain (e.g., a self-destructible legacy token) after being snapshotted into a proposal, which would
  make every future call to `isSupportThresholdReachedEarly`/`execute`/`_vote` for that proposal revert on
  the external call rather than on the arithmetic.
- unclear; need to inspect all callers of `isMinParticipationReached`/`isMinApprovalReached` and confirm
  there is no path that reaches `isSupportThresholdReachedEarly` for a proposal ID that was never created
  (the ABI-decode-revert argument above is inferred from general EVM call semantics to an empty address, not
  from a Solidity-level check in this file).
