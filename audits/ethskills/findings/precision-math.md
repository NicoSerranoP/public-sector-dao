# Precision & Math findings — NFTVoting

Scope: `src/NFTVoting.sol`, `src/base/{INFTVoting,Proposal,Settings,Votes}.sol`, `src/erc721/GovernanceERC721.sol`, checked against `README.md` §"How voting works".

**Headline: the core voting formulas are correct.** `isSupportThresholdReached`, `isSupportThresholdReachedEarly`, `isMinParticipationReached`, `isMinApprovalReached` and `_applyRatioCeiled` usage all match the README spec exactly, including every `>` vs `>=` direction. The findings are in the surrounding date/token/sentinel arithmetic.

---

## [MATH-1] `_validateProposalDates` bounds the voting *duration* but not the proposal's absolute lifetime — the 365-day fix is incomplete

**Severity**: Medium
**Category**: precision-math
**Location**: `Proposal._validateProposalDates()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:366-404`; snapshot taken in `Proposal.createProposal()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:263-293`

**Description**
Commit `5c21a0d` added a ceiling on the end date:

```solidity
uint64 latestEndDate = startDate + 365 days;
if (endDate > latestEndDate) revert DateOutOfBounds(...);
```

This bounds `endDate - startDate`, but there is **no upper bound on `startDate` itself** — the only check is `startDate >= block.timestamp` (line 379). Meanwhile the census is frozen at creation time: `snapshotTimepoint = block.timestamp - 1` / `block.number - 1` (lines 263-272), and `minVotingPower` / `minApprovalPower` are derived from `totalVotingPower(snapshotTimepoint)` at that same instant (lines 296-298).

So a proposer can create a proposal today whose census is today's, but whose voting window opens an arbitrary number of years from now (up to `type(uint64).max - 365 days`). The `Settings` bound `minDuration <= 365 days` and the in-code comment ("Mirrors the 1-year ceiling already enforced on `minDuration`") both signal that a ~1-year maximum lifetime was the intent; that intent is not enforced.

Aggravating factors: there is no `cancel`/`veto` function in the plugin, and the `latestEndDate` check is only reachable in the `_end != 0` branch, so the `_end == 0` path (`endDate = startDate + minDuration`) is never lifetime-checked either.

**Proof of Concept** (compiled and run; passes today)

```solidity
uint64 farStart = uint64(block.timestamp + 100 * 365 days);
vm.prank(ALICE);
uint256 pid = plugin.createProposal("", _dummyActions(), 0, farStart, 0);
```

Observed proposal parameters (`block.timestamp = 100001`, `block.number = 11`):

```
startDate: 3153700001   (~100 years out)
endDate:   3153703601
snapshot:  10           (today's block)
now:       100001
```

A second variant with an explicit `_end = farStart + 365 days` is also accepted (`endDate2: 3185236001`), giving a ~101-year total lifetime.

Scenario: a member holding `CREATE_PROPOSAL_PERMISSION` submits a "sleeper" proposal whose actions drain the DAO treasury / re-grant `ROOT_PERMISSION`, with `_startDate = now + 5 years`. The NFT census is snapshotted today. Five years later the current membership has fully rotated (NFTs burned via `burn`, re-minted to new citizens, re-delegated), yet the *original* snapshot holders — who may no longer hold any NFT — are the only eligible voters, and `minVotingPower` is computed from the 5-year-old total supply. If the original cohort was, say, 3 holders when the DAO now has 500, three addresses can pass and execute an arbitrary treasury action against the present-day DAO. Nothing on chain invalidates the dormant proposal in the meantime.

**Recommendation**
Bound the total lifetime, not just the duration, and apply the ceiling on both branches:

```solidity
function _validateProposalDates(uint64 _start, uint64 _end)
    internal view virtual returns (uint64 startDate, uint64 endDate)
{
    uint64 currentTimestamp = block.timestamp.toUint64();

    if (_start == 0) {
        startDate = currentTimestamp;
    } else {
        startDate = _start;
        if (startDate < currentTimestamp) {
            revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
        }
        // NEW: the snapshot is taken now, so the vote must not open in the far future.
        uint64 latestStartDate = currentTimestamp + MAX_START_DELAY; // e.g. 30 days
        if (startDate > latestStartDate) {
            revert DateOutOfBounds({limit: latestStartDate, actual: startDate});
        }
    }

    uint64 earliestEndDate = startDate + votingSettings.minDuration;
    endDate = _end == 0 ? earliestEndDate : _end;

    if (endDate < earliestEndDate) {
        revert DateOutOfBounds({limit: earliestEndDate, actual: endDate});
    }
    // NEW: applied unconditionally, and measured from *now* so the total lifetime is capped.
    uint64 latestEndDate = currentTimestamp + 365 days;
    if (endDate > latestEndDate) {
        revert DateOutOfBounds({limit: latestEndDate, actual: endDate});
    }
}
```

---

## [MATH-2] `isSupportThresholdReachedEarly` underflows (panic 0x11) when the voting token is swapped while a proposal is open

**Severity**: Medium
**Category**: precision-math
**Location**: `Proposal.isSupportThresholdReachedEarly()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:151-159`; enabled by `Settings.updateVotingToken()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:158-180`

**Description**

```solidity
uint256 noVotesWorstCase =
    totalVotingPower(proposal_.parameters.snapshotTimepoint) - proposal_.tally.yes - proposal_.tally.abstain;
```

The safety of this subtraction rests on the invariant `tally.yes + tally.abstain <= getPastTotalSupply(snapshotTimepoint)`, which holds only while `votingToken` is the *same* token that produced the tallies. `votingToken` is plugin-global mutable state (`updateVotingToken`) and is **not snapshotted into `ProposalParameters`** — unlike `votingMode`, `supportThreshold`, `minVotingPower` and `minApprovalPower`, which all are. A token swap while proposals are in flight breaks the invariant: the new token returns `getPastTotalSupply(oldSnapshot) == 0` (it has no checkpoints that far back), while `tally.yes`/`tally.abstain` still hold the old token's counts, so `0 - yes - abstain` reverts with an arithmetic panic.

`tokenIndexedByTimestamp` (`src/base/Settings.sol:38`) is likewise global and re-derived by `_detectTokenClock()` on every swap, so swapping between a block-number-clocked and a timestamp-clocked token additionally re-interprets every existing `snapshotTimepoint` under the wrong unit — the same underflow, plus `getPastVotes` silently returning 0 for every voter.

`Votes._vote()` (`src/base/Votes.sol:36-46`) has the mirror-image problem: the decrement of a previous vote re-reads `votingToken.getPastVotes(...)` at vote time, so in `VoteReplacement` mode a replaced vote is debited with the *new* token's power and credited with the new token's power, silently leaving phantom votes in the tally (or reverting on underflow), rather than being a clean swap.

**Proof of Concept** (compiled and run; passes today)

```solidity
// EarlyExecution DAO, 3 NFTs: ALICE, BOB, CAROL
vm.prank(ALICE); uint256 pid = plugin.createProposal("", _dummyActions(), 0, 0, 0);
vm.prank(ALICE); plugin.vote(pid, VoteOption.Yes, false);      // tally.yes = 1
vm.prank(BOB);   plugin.vote(pid, VoteOption.Abstain, false);  // tally.abstain = 1

// DAO migrates the voting token (a legitimate, governance-approved action)
GovernanceERC721 newTok = new GovernanceERC721(IDAO(address(dao)), settings);
plugin.updateVotingToken(IVotesUpgradeable(address(newTok)));

// totalVotingPower(oldSnapshot) is now 0 -> 0 - 1 - 1 underflows
vm.expectRevert(); plugin.isSupportThresholdReachedEarly(pid); // passes
vm.expectRevert(); plugin.canExecute(pid);                     // passes
vm.expectRevert(); plugin.hasSucceeded(pid);                   // passes
```

Impact while the proposal is open: `canExecute`, `hasSucceeded` and any `vote(..., true)` attempt revert with panic 0x11, so an early-execution proposal that had already met its criteria cannot be executed and front-ends break. Confirmed in the same PoC: once `block.timestamp >= endDate` the closed path (`isSupportThresholdReached` + the *stored* `minVotingPower`/`minApprovalPower`) works again and `canExecute` returns `true` — i.e. the proposal then executes on a tally computed from a token that is no longer the voting token. So the outcome is a temporary DoS plus a semantically-stale execution, not a permanent brick.

Precondition: `UPDATE_VOTING_SETTINGS_PERMISSION_ID`, i.e. a DAO-level action. Nothing in `updateVotingToken` warns about or guards against in-flight proposals, so this is an easy-to-trip administrative footgun rather than an external attack. (Cross-referenced with the access-control pass's AC-2, same root cause, independently confirmed here with a compiled PoC.)

**Recommendation**
Snapshot the token per proposal, mirroring the treatment of every other setting:

```solidity
// INFTVoting.ProposalParameters
struct ProposalParameters {
    VotingMode votingMode;
    uint32 supportThreshold;
    uint64 startDate;
    uint64 endDate;
    uint64 snapshotTimepoint;
    uint256 minVotingPower;
    IVotesUpgradeable votingToken;   // NEW
    bool tokenIndexedByTimestamp;    // NEW
}
```

and read `proposal_.parameters.votingToken` in `isSupportThresholdReachedEarly`, `_vote` and `_canVote`. Additionally snapshot `totalVotingPower_` into the proposal at creation so the early-execution denominator is a stored constant rather than a live external call:

```solidity
proposal_.parameters.totalVotingPower = totalVotingPower_;
...
uint256 noVotesWorstCase =
    proposal_.parameters.totalVotingPower - proposal_.tally.yes - proposal_.tally.abstain;
```

If a storage change is undesirable, at minimum make `updateVotingToken` defensive and make the subtraction non-reverting:

```solidity
uint256 total = totalVotingPower(proposal_.parameters.snapshotTimepoint);
uint256 counted = proposal_.tally.yes + proposal_.tally.abstain;
uint256 noVotesWorstCase = total > counted ? total - counted : 0;
```

---

## [MATH-3] `isMinParticipationReached` / `isMinApprovalReached` return `true` for non-existent proposals

**Severity**: Low
**Category**: precision-math
**Location**: `Proposal.isMinParticipationReached()` / `Proposal.isMinApprovalReached()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:161-169`

**Description**
The four public criterion predicates lack the `onlyIfProposalExists` modifier that guards `canExecute` (line 71), `hasSucceeded` (line 100) and `canVote` (`Votes.sol:81`). For an unknown `_proposalId` every struct field reads as zero, and because the two *minimum* criteria use `>=` (correctly, per the README), they evaluate `0 >= 0` and return `true`.

This is the `>` vs `>=` boundary interacting with zero-initialised storage. The two *threshold* predicates use `>` and correctly return `false` (`0 > 0`), so the asymmetry is easy to miss.

**Proof of Concept** (compiled and run; passes today)

```solidity
uint256 ghost = uint256(keccak256("nope"));
plugin.isMinParticipationReached(ghost);      // true
plugin.isMinApprovalReached(ghost);           // true
plugin.isSupportThresholdReached(ghost);      // false
plugin.isSupportThresholdReachedEarly(ghost); // false
```

Not directly exploitable on this contract: `_canExecute` also requires `isSupportThresholdReached`, which returns `false`, and `execute()` therefore still reverts for a non-existent proposal (verified). The risk is to integrators — a subDAO, multisig condition, `IPermissionCondition`, or UI that composes `isMinParticipationReached(id) && isMinApprovalReached(id)` as its own gate will read "quorum met" for a proposal ID that was never created (e.g. an ID from a different chain, a mistyped ID, or one whose creation tx reverted).

**Recommendation**
Add the existence guard so the predicates fail loudly, consistent with the other public views:

```solidity
function isSupportThresholdReached(uint256 _proposalId)
    public view virtual onlyIfProposalExists(_proposalId) returns (bool) { ... }

function isSupportThresholdReachedEarly(uint256 _proposalId)
    public view virtual onlyIfProposalExists(_proposalId) returns (bool) { ... }

function isMinParticipationReached(uint256 _proposalId)
    public view virtual onlyIfProposalExists(_proposalId) returns (bool) { ... }

function isMinApprovalReached(uint256 _proposalId)
    public view virtual onlyIfProposalExists(_proposalId) returns (bool) { ... }
```

(`_canExecute`/`_hasSucceeded` call these after their own existence handling, so adding the modifier is behaviour-preserving on the internal paths.)

---

## [MATH-4] `unchecked { block.number - 1 }` can yield `snapshotTimepoint == 0`, colliding with the proposal-existence sentinel

**Severity**: Low
**Category**: precision-math
**Location**: `Proposal.createProposal()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:263-272, 293`; `Proposal._proposalExists()` — `:356-358`; `Proposal.canCreateProposal()` — `:176-185`

**Description**
`_proposalExists` uses `snapshotTimepoint != 0` as its existence sentinel, while `createProposal` computes `snapshotTimepoint = block.number - 1` inside an `unchecked` block for block-number-clocked tokens (which is the case for the bundled `GovernanceERC721`, since OZ 4.9.6 `VotesUpgradeable.clock()` returns `uint48(block.number)`). At `block.number == 1` the snapshot is `0`, and the proposal is created but permanently invisible to `_proposalExists`:

- `canVote`, `canExecute`, `hasSucceeded` revert with `NonexistentProposal`;
- the `if (_proposalExists(proposalId)) revert ProposalAlreadyExists(...)` guard (line 284) never fires, so a second `createProposal` with the same `(msg.sender, actions, metadata)` in the same block silently overwrites the parameters **and re-`push`es the actions** (lines 307-312), duplicating every action in the executed batch.

At `block.number == 0` the `unchecked` block wraps to `type(uint256).max` instead of reverting; `getPastTotalSupply` would then revert on the "future lookup" require, so that case is self-limiting.

The `unchecked` annotation is not load-bearing here (it saves one comparison) and is what removes the natural `block.number == 0` guard. Timestamp-clocked tokens are unaffected (`block.timestamp - 1` is never 0 on any live chain).

Realistically unreachable on any deployed network — it requires the plugin to be live at block 1 — so this is a latent correctness bug rather than an exploitable one, but the sentinel/`unchecked` pairing is fragile and worth hardening.

**Recommendation**
Use a sentinel that cannot alias a legitimate value, and drop the unnecessary `unchecked`:

```solidity
// INFTVoting.Proposal
struct Proposal {
    bool executed;
    bool exists;          // NEW explicit sentinel
    ...
}

function _proposalExists(uint256 _proposalId) private view returns (bool) {
    return proposals[_proposalId].exists;
}
```

If the storage layout must stay fixed, at least remove `unchecked` in both `createProposal` and `canCreateProposal` so `block.number == 0` reverts rather than wrapping, and reject a zero snapshot explicitly:

```solidity
uint256 snapshotTimepoint = tokenIndexedByTimestamp ? block.timestamp - 1 : block.number - 1;
if (snapshotTimepoint == 0) revert NoVotingPower();
```

---

## [MATH-5] `_detectTokenClock` infers the clock unit by numeric equality with `block.timestamp`

**Severity**: Low
**Category**: precision-math
**Location**: `Settings._detectTokenClock()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:184-191`

**Description**

```solidity
try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timePoint) {
    tokenIndexedByTimestamp = (timePoint == block.timestamp);
} catch {
    tokenIndexedByTimestamp = false;
}
```

The unit of the clock is inferred from a numeric coincidence rather than from the declared `CLOCK_MODE()` string that ERC-6372 provides for exactly this purpose. Misclassification is a unit mismatch with large consequences: every `snapshotTimepoint` would be recorded in the wrong unit, and `getPastTotalSupply` / `getPastVotes` would either revert on the "future lookup" require (blocking all proposal creation — a DoS until the token is re-set) or silently return `0` for every account.

In practice the heuristic is safe on real networks (`block.number ≈ 2.3e7` vs `block.timestamp ≈ 1.7e9`, and the timestamp grows ~12x faster, so they will not coincide). The failure mode is confined to chains or test environments where the two happen to be equal, and to clocks that are neither `block.number` nor `block.timestamp` (e.g. an epoch counter) — for which the heuristic silently picks block-number semantics. Note commit `fa8a27d` already reworked this; the residual gap is that `CLOCK_MODE()` is still unused.

**Recommendation**
Prefer the declared mode and fall back to the heuristic:

```solidity
function _detectTokenClock() private {
    try IERC6372Upgradeable(address(votingToken)).CLOCK_MODE() returns (string memory mode) {
        // ERC-6372: "mode=blocknumber&from=default" | "mode=timestamp"
        tokenIndexedByTimestamp =
            keccak256(bytes(mode)) == keccak256(bytes("mode=timestamp"));
        return;
    } catch {}

    try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timePoint) {
        tokenIndexedByTimestamp = (timePoint == block.timestamp);
    } catch {
        tokenIndexedByTimestamp = false;
    }
}
```

and sanity-check the result once at set time, e.g. call `votingToken.getPastTotalSupply(snapshot)` for the freshly-derived snapshot, so a misdetection reverts at configuration time rather than at the first `createProposal`.

---

## [MATH-6] Ratio bounds in code are narrower than the documented intervals, and the zero-case revert reports a misleading limit

**Severity**: Info
**Category**: precision-math
**Location**: `Settings._updateVotingSettings()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:116-141`; docs in `/home/nnico/public-sector/dao/src/base/INFTVoting.sol:44-51` and `/home/nnico/public-sector/dao/README.md:51-60`

**Description**
Three cosmetic/spec discrepancies, none with security impact:

1. `INFTVoting.VotingSettings` natspec states `supportThreshold ∈ [0, 10^6)` and `minParticipation ∈ [0, 10^6]`, and the README states `supportThreshold ∈ [0,1)`, `minParticipation ∈ [0,1]`. The code rejects `0` for both, so the effective intervals are `[1, 10^6-1]` and `[1, 10^6]`. The stricter code is the *desirable* behaviour — a non-zero `minParticipation` combined with `_applyRatioCeiled` is what guarantees `minVotingPower >= 1` and therefore blocks execution of a zero-turnout proposal — but the docs should say so.
2. `minApprovals` is a third execution criterion (`isMinApprovalReached`) enforced by the contract and validated to `[1, 10^6]`, but the README's "Execution Criteria" section documents only the support and participation criteria. A reader using the README as the spec would not know a proposal must also clear `yes >= ceil(N_total * minApprovals / 10^6)`.
3. The zero-value branches revert with an upper-bound limit: `RatioOutOfBounds({limit: RATIO_BASE - 1, actual: 0})` for `supportThreshold == 0` and `RatioOutOfBounds({limit: RATIO_BASE, actual: 0})` for `minParticipation == 0` / `minApprovals == 0`. An integrator decoding the error sees `limit: 999999, actual: 0` and cannot tell a lower-bound violation from an upper-bound one.

**Recommendation**
Update the natspec in `INFTVoting.sol` to `[1, 10^6)` / `[1, 10^6]`, add the `minApproval` criterion to the README's "Execution Criteria" section alongside the support and participation criteria, and split the bounds errors:

```solidity
if (_votingSettings.supportThreshold == 0) {
    revert RatioOutOfBounds({limit: 1, actual: 0});
}
if (_votingSettings.supportThreshold > RATIO_BASE - 1) {
    revert RatioOutOfBounds({limit: RATIO_BASE - 1, actual: _votingSettings.supportThreshold});
}
```

---

# Verified-correct — checklist walk

Every applicable checklist item, and what was found.

**Division before multiplication**
- The only division in the whole plugin is inside `_applyRatioCeiled` (`lib/osx-commons/contracts/src/utils/math/Ratio.sol:18-31`), which does `_value * _ratio` *then* `% RATIO_BASE` / `/ RATIO_BASE`. Multiplication precedes division — correct. No other `/` or `%` operator exists in the plugin.
- No chained library calls that hide a division; no double-division by a scaling factor.
- "Division resulting in zero for small values": `_applyRatioCeiled` **ceils**, so with `minParticipation >= 1` and `totalVotingPower >= 1` (enforced by `NoVotingPower`), `minVotingPower` and `minApprovalPower` are always `>= 1`. A zero-turnout proposal can therefore never clear participation/approval. Correct and load-bearing.

**Rounding direction**
- Ceiling is the protocol-favouring direction for both `minVotingPower` and `minApprovalPower` (a minimum must round *up* to stay a real minimum). README's worked example — 40% of 10 requires 4 — reproduces exactly: `ceil(10 * 400000 / 10^6) = 4`, and `4 >= 4` passes.
- Rounding is consistent: both call sites use `_applyRatioCeiled`, both at creation only. No second rounding anywhere, so no dust-extraction/asymmetry loop exists.
- Inverse-fee patterns: not applicable (no fees).

**Integer overflow/underflow**
- `unchecked` blocks audited individually. `Proposal.sol:177` and `:264` (`block.number/timestamp - 1`) → see MATH-4. `Proposal.sol:309` and `GovernanceERC721.sol:99` (`++i` loop counters, bounded by array length) → safe. `GovernanceERC721.sol:150` (`tokenId = ++nextTokenId`) → needs 2^256 mints, safe.
- Downcasts all use `SafeCastUpgradeable`: `block.timestamp.toUint64()` (`:233`, `:372`) and `snapshotTimepoint.toUint64()` (`:293`). No raw `uint64(...)`/`uint32(...)` casts of user-influenced values anywhere in `src/`.
- `RATIO_BASE - proposal_.parameters.supportThreshold` (`:147`, `:157`): `supportThreshold` is `uint32` bounded to `<= RATIO_BASE - 1` by `_updateVotingSettings` and is snapshotted per proposal, so the subtraction cannot underflow even if the global setting is later changed. Correct.
- Multiplication widths: `(RATIO_BASE - st) * yes` peaks at `10^6 * N_total`. With `N_total` an NFT count, overflow needs ~10^71 NFTs. Safe. Same for `_value * _ratio` in `_applyRatioCeiled`.
- `Votes._vote` tally decrement (`Votes.sol:41-45`): `getPastVotes` at a fixed past `snapshotTimepoint` is immutable for a fixed token, so the debit always equals the earlier credit and cannot underflow — *provided the token is not swapped*, which is exactly MATH-2.
- `isSupportThresholdReachedEarly`'s `total - yes - abstain` (`:154-155`): safe under the single-token invariant (`yes + no + abstain <= total delegated <= getPastTotalSupply`), including when holders `delegate(address(0))` (that reduces delegated power without touching total supply, so the inequality only gets slacker). Breaks only on token swap → MATH-2.
- No signed arithmetic and no negative-to-unsigned casts anywhere in `src/`.
- Time arithmetic uses `uint64` throughout, not narrow `int40/int64`. `startDate + minDuration` and `startDate + 365 days` (`:386`, `:398`) are *checked* (outside any `unchecked`), so they revert rather than wrap; the in-code comment at `:383-385` accurately describes this. `365 days` / `60 minutes` literals are compared/added against `uint64` operands with no truncating multiplier, so the "time literals are uint24" pitfall does not apply.

**Decimal handling** — not applicable. No oracles, no ERC-20 decimals, no cross-asset pricing. Each NFT is exactly one unit of voting power, so there is no scaling factor to mismatch.

**Accumulator & interest math** — not applicable. No staking, rewards, interest or fee shares.

**Special values**
- No assembly anywhere in `src/`, so the "assembly division by zero returns 0" pattern does not arise. All division goes through `_applyRatioCeiled` with a compile-time-constant non-zero divisor.
- No `type(uint256).max` sentinel used in arithmetic.
- No exponentiation / weighted-product math.

**Precision loss patterns**
- **Inequality directions verified line-by-line against README** ("For threshold values, `>` is used… for minimum values, `>=` is used"):
  - `isSupportThresholdReached` (`:147-148`) — `(RATIO_BASE - st) * yes > st * no`, `>` strict. Matches README exactly.
  - `isSupportThresholdReachedEarly` (`:154-158`) — `(RATIO_BASE - st) * yes > st * (total - yes - abstain)`, `>` strict. Matches the README derivation exactly, including the `N_total - N_yes - N_abstain` simplification of the worst case.
  - `isMinParticipationReached` (`:164`) — `yes + no + abstain >= minVotingPower`, `>=` inclusive. Matches README.
  - `isMinApprovalReached` (`:168`) — `yes >= minApprovalPower`, `>=` inclusive, consistent with the "minimum values use `>=`" rule.
  No `>`/`>=` is inverted or swapped between the four predicates.
- `_isProposalOpen` (`:235`) uses `startDate <= now && now < endDate` — open at `startDate`, closed at `endDate`. At the `endDate` boundary `_canExecute` switches from the early criterion to the final one; since `noVotesWorstCase >= no` always, the early criterion is strictly stronger, so a proposal executable at `endDate - 1` remains executable at `endDate`. No boundary regression.
- Proposals whose `startDate` is still in the future are treated as "not open" and therefore take the *closed* evaluation path in `_canExecute`/`_hasSucceeded`. Verified non-exploitable: no votes can have been cast (`_canVote` requires `_isProposalOpen`), so `yes = no = 0` and `isSupportThresholdReached` evaluates `0 > 0` → false. Same for a non-existent proposal reaching `execute()` (which has no `onlyIfProposalExists`): blocked by the same `0 > 0`.
- The recent fixes in git history are complete as far as this domain goes: `_hasSucceeded` (`:114-131`) returns `false` for `Standard`/`VoteReplacement` while open, and `_canExecute` (`:92-94`) blocks pre-`endDate` execution for those modes. The one incomplete fix is the 365-day bound from commit `5c21a0d` → MATH-1.
- No chained divisions, so no compounding precision loss.
- All `unchecked` blocks have explicit safety arguments recorded above; the only one whose argument is not airtight is MATH-4.
