# Invariant Map

> NFTVoting Plugin | 17 guards | 19 inferred | 3 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`require(IERC165Upgradeable(address(_token)).supportsInterface(type(IERC721Upgradeable).interfaceId), "token is not a ERC721")` · `NFTVoting.sol:100` · the only validation of the voting token — establishes the trust boundary that every later `getPastVotes` / `getPastTotalSupply` read depends on.

#### G-2
`if (_votingSettings.supportThreshold > RATIO_BASE - 1) revert RatioOutOfBounds(RATIO_BASE - 1, ...)` · `NFTVoting.sol:485` · keeps `supportThreshold` in `[0, 10^6)` so the strict-`>` support criterion is always satisfiable (100% support could never be reached otherwise).

#### G-3
`if (_votingSettings.minParticipation > RATIO_BASE) revert RatioOutOfBounds(RATIO_BASE, ...)` · `NFTVoting.sol:491` · keeps participation ratio ≤ 100% so `_applyRatioCeiled` cannot demand more turnout than exists.

#### G-4
`if (_votingSettings.minDuration < 60 minutes) revert MinDurationOutOfBounds(60 minutes, ...)` · `NFTVoting.sol:495` · floors the voting window so a proposal cannot be opened and closed inside one short interval.

#### G-5
`if (_votingSettings.minDuration > 365 days) revert MinDurationOutOfBounds(365 days, ...)` · `NFTVoting.sol:499` · caps the window; also bounds `startDate + minDuration` so `_validateProposalDates` overflow is a corner case, not routine.

#### G-6
`if (_minApprovals > RATIO_BASE) revert RatioOutOfBounds(RATIO_BASE, ...)` · `NFTVoting.sol:526` · bounds the min-approval ratio consumed by `_applyRatioCeiled` at creation.

#### G-7
`if (totalVotingPower_ == 0) revert NoVotingPower()` · `NFTVoting.sol:572` · blocks proposal creation when no votable supply exists — prevents a proposal that can never meet participation and prevents division-by-nothing in ratio math.

#### G-8
`if (proposal_.parameters.snapshotTimepoint != 0) revert ProposalAlreadyExists(proposalId)` · `NFTVoting.sol:583` · one-shot latch: a given `proposalId` (a hash of `(actions, metadata)`) can be created exactly once, ever.

#### G-9
`if (startDate < currentTimestamp) revert DateOutOfBounds(currentTimestamp, startDate)` · `NFTVoting.sol:687` · forbids back-dated proposals so the snapshot cannot predate a chosen start.

#### G-10
`if (endDate < earliestEndDate) revert DateOutOfBounds(earliestEndDate, endDate)` · `NFTVoting.sol:701` · enforces `endDate >= startDate + minDuration` at creation.

#### G-11
`if (!_canVote(_proposalId, account, _voteOption)) revert VoteCastForbidden(...)` · `NFTVoting.sol:150` · gates every vote on: proposal open, option ≠ None, snapshot voting power > 0, and (no prior vote OR VoteReplacement mode).

#### G-12
`if (!_canExecute(_proposalId)) revert ProposalExecutionForbidden(_proposalId)` · `NFTVoting.sol:214` · gates `execute` on not-already-executed + mode/timing rules + `_hasSucceeded`.

#### G-13
`if (clockModeTimestamp != clockTimestamp) revert TokenClockMismatch()` · `NFTVoting.sol:719` · rejects a token whose ERC-6372 `CLOCK_MODE()` string disagrees with its `clock()` value, so `snapshotTimepoint` is taken in a consistent unit.

#### G-14
`modifier onlyIfProposalExists`: `if (!_proposalExists(_proposalId)) revert NonexistentProposal(_proposalId)` · `NFTVoting.sol:71-76` · applied to `canVote` / `canExecute` / `hasSucceeded` so external queries cannot read a zero-initialized proposal as real.

#### G-15
`modifier auth(MINT_PERMISSION_ID)` on `GovernanceERC721.mint` · `GovernanceERC721.sol:121` · restricts token supply growth to the DAO permission holder.

#### G-16
`modifier auth(BURN_PERMISSION_ID)` on `GovernanceERC721.burn` · `GovernanceERC721.sol:128` · restricts destruction of voting NFTs to the DAO permission holder.

#### G-17
`modifier auth(TRANSFER_PERMISSION_ID)` on `GovernanceERC721.adminTransfer` · `GovernanceERC721.sol:138` · restricts approval-bypassing force-transfer of voting NFTs to the DAO permission holder.

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Conservation` · On-chain: **Yes**

> For any proposal, `tally.yes + tally.no + tally.abstain == Σ getPastVotes(v, snapshot)` over voters `v` whose latest recorded option ≠ None.

**Derivation** — Δ-pair `NFTVoting.sol:174-179` (subtract `votingPower` from the prior bucket) ↔ `NFTVoting.sol:183-188` (add the same `votingPower` to the new bucket), with `votingPower = getPastVotes(_voter, proposal_.parameters.snapshotTimepoint)` read once at `:169`. Because `snapshotTimepoint` is a fixed past timepoint (I-9, I-11), `getPastVotes` returns the same value on a later VoteReplacement call, so subtract exactly cancels the earlier add.

**If violated** — support / participation / approval checks read a corrupted tally; a proposal could pass or fail against the wrong numbers.

---

#### I-2

`Bound` · On-chain: **Yes** (range only — see note)

> `votingSettings.supportThreshold ∈ [0, RATIO_BASE - 1]` and each proposal's copied `parameters.supportThreshold` inherits that range.

**Derivation** — guard-lift of G-2. Write sites of `votingSettings.supportThreshold`: only the whole-struct assignment in `_updateVotingSettings` (`NFTVoting.sol:503`), guarded by G-2 at `:485`. Per-proposal copy at `:591` (`supportThreshold()` reader) carries the same value. All write sites guarded.

**If violated** — n/a for the range. **Note:** the lower bound is 0 — nothing floors `supportThreshold` at 50%, so "majority" is not enforced on-chain (README §Parameterization, "not enforced by the contract code"). Treat the *semantic* floor as On-chain=**No**.

---

#### I-3

`Bound` · On-chain: **Yes** (range only)

> `votingSettings.minParticipation ∈ [0, RATIO_BASE]`; proposal `parameters.minVotingPower = _applyRatioCeiled(totalVotingPower_, minParticipation)` inherits it.

**Derivation** — guard-lift of G-3; single write site `_updateVotingSettings` (`NFTVoting.sol:503`) guarded at `:491`.

**If violated** — n/a for range. **Note:** `minParticipation` may be 0 → participation criterion (`>=` at `NFTVoting.sol:388`) is trivially satisfied. Semantic floor On-chain=**No**.

---

#### I-4

`Bound` · On-chain: **Yes**

> `votingSettings.minDuration ∈ [3600, 31_536_000]` seconds (1 hour … 365 days).

**Derivation** — guard-lift of G-4 + G-5; single write site `_updateVotingSettings` (`NFTVoting.sol:503`) guarded at `:495` and `:499`.

**If violated** — a proposal window could be arbitrarily short (flash governance) or long enough to overflow `startDate + minDuration`.

---

#### I-5

`Bound` · On-chain: **Yes**

> `minApprovals ∈ [0, RATIO_BASE]`; proposal `minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApprovals)`.

**Derivation** — guard-lift of G-6; single write site `_updateMinApprovals` (`NFTVoting.sol:530`) guarded at `:526`.

**If violated** — n/a for range; `minApprovals == 0` makes `isMinApprovalReached` (`tally.yes >= 0`) always true.

---

#### I-6

`Ratio` · On-chain: **Yes**

> `proposals[id].parameters.minVotingPower == ceil(totalVotingPower_ * minParticipation / RATIO_BASE)`, snapshotted at creation.

**Derivation** — `NFTVoting.sol:592` `proposal_.parameters.minVotingPower = _applyRatioCeiled(totalVotingPower_, minParticipation())`, where `totalVotingPower_ = getPastTotalSupply(snapshotTimepoint)` at `:570`. Read-only afterward (`isMinParticipationReached` `:388`).

**If violated** — quorum requirement drifts from the electorate size that existed at snapshot.

---

#### I-7

`Ratio` · On-chain: **Yes**

> `proposals[id].minApprovalPower == ceil(totalVotingPower_ * minApprovals / RATIO_BASE)`, snapshotted at creation.

**Derivation** — `NFTVoting.sol:594` `proposal_.minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApproval())`. Read-only afterward (`isMinApprovalReached` `:392`).

**If violated** — the absolute Yes-power bar for a proposal no longer matches the intended fraction of the snapshot supply.

---

#### I-8

`StateMachine` · On-chain: **Yes**

> `proposals[id].executed`: `false → true`, irreversible.

**Derivation** — edge `executed = true @ NFTVoting.sol:225` inside `_execute`; no other write site; `_canExecute` returns false when `executed` (`:310`) and `_isProposalOpen` returns false when `executed` (`:466`). No reverse assignment anywhere.

**If violated** — a proposal's `Action[]` could execute more than once.

---

#### I-9

`StateMachine` · On-chain: **Yes**

> `proposals[id].parameters.snapshotTimepoint`: `0 → concrete past timepoint`, one-shot latch, never rewritten.

**Derivation** — edge: guarded by G-8 (`require(snapshotTimepoint == 0)` at `:583`), then set at `:589`. `_proposalExists` uses `snapshotTimepoint != 0` as the existence test (`:665`). No other write site.

**If violated** — proposal identity / existence detection breaks; re-snapshotting would move the census under an open vote.

---

#### I-10

`Temporal` · On-chain: **Yes**

> A proposal is open iff `parameters.startDate <= block.timestamp < parameters.endDate && !executed`.

**Derivation** — temporal predicate `NFTVoting.sol:462-467` (`_isProposalOpen`), checked before every vote (via `_canVote` `:266`) and consulted by `_canExecute` / `_hasSucceeded`. `block.timestamp` cast via `SafeCastUpgradeable.toUint64`.

**If violated** — votes accepted outside the window, or early/late execution timing rules bypassed.

---

#### I-11

`Temporal` · On-chain: **Yes**

> `snapshotTimepoint == (tokenIndexedByTimestamp ? block.timestamp : block.number) - 1` at creation — strictly earlier than the creation block/timestamp.

**Derivation** — temporal predicate `NFTVoting.sol:560-568` inside an `unchecked` block; comment: "must be already mined (block) or in the past (timestamp) … protect against backrunning transactions causing census changes."

**If violated** — an actor could acquire or borrow tokens in the creation block and have them count.

---

#### I-12

`Bound` · On-chain: **Yes**

> `GovernanceERC721.nextTokenId` is strictly monotonically increasing; minted token ids are `1, 2, 3, …` and are never reused, even after `burn`.

**Derivation** — guard-lift / Δ: `_mintTo` (`GovernanceERC721.sol:147-150`) `unchecked { tokenId = ++nextTokenId; }` is the sole write site of `nextTokenId`; `burn` (`:128-130`) does not touch it. Overflow only after `2^256` mints.

**If violated** — id reuse would let a burned token's history collide with a new mint.

---

#### I-13

`StateMachine` · On-chain: **No** (re-triggering, not one-directional)

> After any inbound transfer or mint, a receiver with `delegates(to) == address(0)` becomes self-delegated (`delegates(to) == to`).

**Derivation** — edge `GovernanceERC721.sol:163-166` in `_afterTokenTransfer`: `if (to != address(0) && delegates(to) == address(0)) _delegate(to, to);`. Not a latch — a holder can call `delegate(address(0))` and the next inbound transfer re-self-delegates, and a holder who delegated elsewhere is never auto-changed.

**If violated / edge cases** — a holder who deliberately sets `delegates(self) = address(0)` between transfers has voting units that are minted-but-undelegated, so `Σ getPastVotes < getPastTotalSupply` for that snapshot (feeds X-4).

---

**Categories:** Conservation = equal-and-opposite Δ in one function body. Bound = guard lifted across all write sites. Ratio = storage var defined as a formula of other storage vars. StateMachine = guarded discrete transition with no reverse path. Temporal = predicate on `block.timestamp` / `block.number` / a stored deadline.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **Yes** (assumption holds — but reads live, not snapshot)

> `VotingPowerCondition.isGranted` assumes `PLUGIN.minProposerVotingPower()` and `PLUGIN.tokenIndexedByTimestamp()` reflect the plugin's current configuration at call time.

**Caller side** — `VotingPowerCondition.sol:40-50` — reads `minProposerVotingPower_` and branches the timepoint on `tokenIndexedByTimestamp()`, then `VOTING_TOKEN.getPastVotes(_who, _timepoint) < minProposerVotingPower_` → deny.

**Callee side** — `NFTVoting._updateVotingSettings:503` writes `votingSettings` (incl. `minProposerVotingPower`) at any time under `UPDATE_VOTING_SETTINGS_PERMISSION`; `tokenIndexedByTimestamp` is set once in `_detectTokenClock` during `initialize` and never again.

**If violated** — a DAO lowering `minProposerVotingPower` opens proposal creation immediately with no delay; raising it cannot retroactively block an already-created proposal.

---

#### X-2

On-chain: **Yes**

> `VotingPowerCondition` assumes the plugin's voting token never changes after the condition is constructed.

**Caller side** — `VotingPowerCondition.sol:24-27` — constructor caches `VOTING_TOKEN = PLUGIN.getVotingToken()` into an `immutable`.

**Callee side** — `NFTVoting.votingToken` is assigned only at `initialize` (`NFTVoting.sol:108`); there is no setter.

**If violated** — n/a on current code; if a token setter were ever added, the condition would gate against a stale token.

---

#### X-3

On-chain: **No**

> `NFTVoting` assumes the voting token's `getPastVotes` is honest, pure/view, and non-reentrant.

**Caller side** — `NFTVoting.sol:169` (`_vote`, before tally writes at `:183-190`) and `NFTVoting.sol:276` (`_canVote`) use the return value directly as vote weight; the comment at `:168` states "This could re-enter, though we can assume the governance token is not malicious."

**Callee side** — any contract passed as `_token` to `initialize` that passes the single ERC-165 `IERC721` check (G-1). A malicious token can return different values per call or re-enter `vote()` during `getPastVotes`.

**If violated** — tally corruption / double-counting within one snapshot; the `_vote` → early-execution branch (`:198-203`) could be re-entered before `executed` is set for a *different* proposal.

---

#### X-4

On-chain: **No**

> `NFTVoting` assumes `Σ getPastVotes(voters, t) <= getPastTotalSupply(t)` and that `getPastTotalSupply(t)` is a stable, correct denominator.

**Caller side** — `NFTVoting.totalVotingPower:144` feeds `_applyRatioCeiled` for `minVotingPower` / `minApprovalPower` (`:592-594`) and the subtraction `totalVotingPower(snapshot) - tally.yes - tally.abstain` in `isSupportThresholdReachedEarly:378-379`.

**Callee side** — OZ `ERC721VotesUpgradeable` / `VotesUpgradeable`: total-supply checkpoints move only on mint/burn, so for the standard token the assumption holds; an arbitrary `IVotes` (or a holder using `delegate(address(0))`, I-13) can make `getPastTotalSupply` smaller than the summed votable power.

**If violated** — `isSupportThresholdReachedEarly` reverts on underflow → `hasSucceeded` / early execution DoS; or an inflated denominator makes quorum unreachable.

---

## 4. Economic Invariants

#### E-1

On-chain: **Yes** (mechanically) / **No** (semantically — thresholds may be 0)

> A proposal can execute only if all three hold: support criterion `(RATIO_BASE - supportThreshold)·yes > supportThreshold·no` (or the early-execution worst-case variant), participation `yes+no+abstain >= minVotingPower`, and approval `yes >= minApprovalPower`.

**Follows from** — `_hasSucceeded` (`NFTVoting.sol:336-366`) chaining `isSupportThresholdReached` / `…Early`, `isMinParticipationReached`, `isMinApprovalReached`; thresholds from I-2, I-6, I-7.

**If violated** — proposals execute without genuine majority/quorum. Note the semantic gap: with `supportThreshold = minParticipation = minApprovals = 0`, a single Yes vote (with `no == 0`) satisfies all three.

---

#### E-2

On-chain: **Yes**

> A voter's weight on a proposal is fixed at proposal creation; tokens acquired, minted, borrowed, or force-transferred afterward do not change any tally.

**Follows from** — I-9 (snapshot latch) + I-11 (snapshot strictly in the past) + I-1 (tally is the sum of `getPastVotes` at that fixed timepoint).

**If violated** — flash-loan / same-block governance capture would be possible. Caveat: holds only for a standard `IVotes` token (see X-3, X-4).
