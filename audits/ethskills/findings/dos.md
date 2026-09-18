# DoS & Griefing Findings — NFTVoting

All findings below were validated empirically with a compiled PoC suite (6/6 passing), not just by reading.

Permission model confirmed reachable: OSx `PermissionManager._grant` only restricts `ANY_ADDR` for `ROOT_PERMISSION_ID` and the DAO's own restricted set (`DAO.isPermissionRestrictedForAnyAddr` = EXECUTE/UPGRADE_DAO/SET_METADATA/SET_TRUSTED_FORWARDER/REGISTER_STANDARD_CALLBACK). Neither covers the plugin's `CREATE_PROPOSAL_PERMISSION_ID` / `EXECUTE_PROPOSAL_PERMISSION_ID`, so both `ANY_ADDR` grants in the install script succeed and literally any EOA can create and execute proposals.

Summary: 3 Medium (DOS-1 unbounded actions vs. the executor's 256 cap with a lying `canExecute`; DOS-2 permissionless execute + discarded `allowFailureMap`; DOS-3 `updateVotingToken` bricking in-flight proposals via underflow), 4 Low, 1 Info.

---

## [DOS-1] `createProposal` accepts more actions than the executor will ever run, creating permanently unexecutable proposals while `canExecute()` reports `true`
**Severity**: Medium
**Category**: dos
**Location**: `Proposal.createProposal()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:307-312`; interacts with `Proposal._canExecute()` `src/base/Proposal.sol:81-97`
**Description**:
`createProposal` pushes every element of the caller-supplied `Action[] calldata _actions` into storage with no upper bound. The contract that ultimately runs those actions enforces a hard cap: both `DAO.execute()` (`lib/osx/packages/contracts/src/core/dao/DAO.sol:71,284`) and `osx-commons` `Executor.execute()` declare `uint256 internal constant MAX_ACTIONS = 256;` and revert `TooManyActions()` above it.

The plugin never mirrors that bound, so the invariant is only checked at the very end of the lifecycle:
1. A proposal with 257+ actions is accepted and stored.
2. It can be voted on normally for the full voting period.
3. `canExecute(proposalId)` returns **`true`** — `_canExecute` only inspects `executed`, open/closed state and tallies; it never looks at `actions.length`.
4. `execute(proposalId)` reverts `TooManyActions()` — permanently. Actions are written only at creation; there is no edit, cancel or expiry.

Two-sided impact. As a mistake: a well-intentioned proposer batching a large treasury/permission migration burns a full voting cycle (up to 365 days here) before discovering the proposal can never execute. As griefing: since anyone can create proposals, an attacker plants proposals that pass every off-chain "is this executable?" check, consuming voter attention and gas, and breaking keepers/bots that gate on `canExecute() == true` and therefore submit a tx that always reverts.

Related latent inconsistency: the `allowFailureMap` bit index is `uint8(i)` in the executor, so only indices 0–255 are addressable. The plugin accepts a map for action indices it can store but that can never be referenced. Enforcing `MAX_ACTIONS` at creation fixes both.

**Proof of Concept**: (`test_poc_tooManyActions`, `test_poc_256ActionsOk` — both pass)
```
1. DAO + NFTVoting, 3 NFTs (ALICE x2, BOB x1), Standard mode, default settings.
2. ALICE (or any address — see DOS-7) calls createProposal("", actionsN(257, noop), 0, 0, 0)
   MEASURED: 13,253,490 gas for 257 actions each with a 4-byte calldata payload
   -> comfortably inside a single 30M-gas mainnet block, near-free on an L2 (~51.6k gas/action).
3. ALICE votes Yes; warp past endDate.
4. assertTrue(plugin.canExecute(pid))   // PASSES — the plugin says it is executable
5. plugin.execute(pid) -> reverts TooManyActions()
6. warp +365 days; canExecute(pid) STILL returns true. Permanently stuck.
Boundary confirmed: the identical flow with exactly 256 actions executes successfully,
so 257 is the first failing length.
```
This is not a gas-limit self-DoS — cost scales linearly and is cheap and repeatable.

**Recommendation**:
```solidity
// src/base/Proposal.sol
/// @notice Mirrors `MAX_ACTIONS` in `DAO`/`Executor`; actions beyond this can never be executed,
///         and `allowFailureMap` bits are only addressable for indices 0..255.
uint256 internal constant MAX_ACTIONS = 256;

/// @notice Thrown if the action array is longer than the executor supports.
error TooManyActions(uint256 limit, uint256 actual);

function createProposal(...) public virtual auth(CREATE_PROPOSAL_PERMISSION_ID) returns (uint256 proposalId) {
    if (_actions.length > MAX_ACTIONS) {
        revert TooManyActions({limit: MAX_ACTIONS, actual: _actions.length});
    }
    ...
}
```
Defence in depth: also make `_canExecute` honest so `canExecute()` can never claim a proposal is executable when `execute()` is guaranteed to revert.

---

## [DOS-2] Permissionless `execute()` + `allowFailureMap` lets any address consume a passed proposal with its actions skipped
**Severity**: Medium
**Category**: dos
**Location**: `Proposal.execute()` / `Proposal._execute()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:41-64`
**Description**:
`_execute` sets `proposal_.executed = true` and then forwards the actions. For any index `i` whose bit is set in `allowFailureMap`, the executor records the failure in its returned `failureMap` and **does not revert**. The plugin discards that returned `failureMap` entirely — not stored, not emitted, not checked.

Combined with `EXECUTE_PROPOSAL_PERMISSION_ID` granted to `ANY_ADDR`, **any** address — no tokens, no stake, no participation in the vote — chooses the block in which a passed proposal executes. If an allowed-to-fail action's success depends on state the attacker can influence (swap slippage/deadline, a revoked allowance, a blocklisted recipient, a contract the attacker can put into a reverting state), the attacker front-runs the honest executor, flips that state, and calls `execute()`. The proposal is consumed: `executed == true`, `ProposalExecuted` emitted as if everything succeeded, and there is no way to re-run the skipped action — only a brand-new proposal and a fresh voting cycle.

The `gasAfter < gasBefore / 64` check in the executor guards only the *gas-based* variant (forcing OOG via a tight gas limit). It does nothing against the state-based variant below.

Even with `allowFailureMap == 0`, the permissionless executor still gets unilateral choice of execution block for every passed proposal — a pure MEV/timing surface for price- or state-sensitive treasury actions. (Overlaps with the governance pass's GOV-7, which covers the timing-choice angle in more depth.)

**Proof of Concept**: (`test_poc_allowFailureMapGrief` — passes)
```
1. DAO + NFTVoting, 3 NFTs, Standard mode. `Flaky.doWork()` reverts while `broken`.
2. ALICE creates a proposal with one action -> Flaky.doWork(), allowFailureMap = 1 (bit 0 set).
3. ALICE votes Yes; proposal passes; warp past endDate.
4. RANDOM_ADDRESS (zero tokens, never voted) calls flaky.setBroken(true) then
   plugin.execute(pid)  -> SUCCEEDS.
5. getProposal(pid).executed == true, ProposalExecuted emitted,
   flaky.workDone() == 0  -> the approved action NEVER RAN.
6. plugin.execute(pid) again -> reverts. Permanently consumed.
```
Attacker cost: one state-flipping tx plus execution gas.

**Recommendation**: Two independent steps.
1. Surface the failure map instead of silently discarding it:
```solidity
function _execute(uint256 _proposalId) internal virtual {
    Proposal storage proposal_ = proposals[_proposalId];
    proposal_.executed = true;
    (, uint256 failureMap) = _execute(
        proposal_.targetConfig.target, bytes32(_proposalId),
        proposal_.actions, proposal_.allowFailureMap, proposal_.targetConfig.operation
    );
    emit ProposalExecuted(_proposalId);
    if (failureMap != 0) emit ProposalPartiallyExecuted(_proposalId, failureMap); // new event
}
```
2. Do not grant `EXECUTE_PROPOSAL_PERMISSION_ID` to `ANY_ADDR` by default (`script/InstallNFTVoting.s.sol:200`). Restrict to token holders or a keeper role via `grantWithCondition`. If open execution is deliberate, document it and discourage non-zero `allowFailureMap` for state-sensitive actions.

---

## [DOS-3] `updateVotingToken` permanently bricks every in-flight proposal (arithmetic underflow + vote lockout)
**Severity**: Medium
**Category**: dos
**Location**: `Settings._updateVotingToken()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:164-180`; manifests in `Proposal.isSupportThresholdReachedEarly()` `src/base/Proposal.sol:151-159` and `Votes._canVote()` `src/base/Votes.sol:111`
**Description**:
Proposals snapshot a **time point** but never snapshot **which token** it belongs to. `votingToken` and `tokenIndexedByTimestamp` are plugin-wide mutable state. When the DAO swaps the voting token — a legitimate governance op (migration, fixing a misconfigured token) — every open proposal resolves its historical census against a token with no history at that time point:
- `totalVotingPower(snapshotTimepoint)` → `newToken.getPastTotalSupply(oldTimepoint)` → `0`.
- `isSupportThresholdReachedEarly` computes `0 - tally.yes - tally.abstain` **outside `unchecked`** → `Panic(0x11)` underflow (confirmed in the forge trace).
- Propagates through `_hasSucceeded` → `_canExecute`, so `canExecute()`, `hasSucceeded()` and `execute()` **all revert** for every open EarlyExecution proposal — permanently unexecutable and permanently un-queryable (front-ends/indexers get a raw panic).
- Independently, in **all** voting modes `_canVote` reads `getPastVotes(_account, oldTimepoint)` → `0` → every further vote reverts `VoteCastForbidden`. In-flight Standard/VoteReplacement proposals freeze at a partial tally and then resolve on it, which can flip an outcome.

Same brick is reachable without a "wrong" token: `_detectTokenClock()` re-detects `tokenIndexedByTimestamp` globally, so swapping a block-number-indexed token for a timestamp-indexed one makes existing proposals interpret a stored block number as a timestamp — again `0`, same underflow.

Trigger requires `UPDATE_VOTING_SETTINGS_PERMISSION_ID`, held by the DAO, i.e. a passing proposal. But nothing in code or NatSpec warns that a routine token migration silently destroys concurrent proposals, and the damage is irreversible. (This is the single most cross-confirmed finding in the audit — independently found with passing PoCs by the general pass as GEN-2, the precision-math pass as MATH-2, and the ERC-721 pass as NFT-1, and covered from the governance angle as GOV-4.)

Also confirmed from this checklist item and **not** an issue: the ERC-165 probes at `Settings.sol:165-173` fail safe. A token with no code returns empty data and `abi.decode` reverts; a reverting token propagates. Either way `votingToken` is untouched and nothing is bricked.

**Proof of Concept**: (`test_poc_updateVotingTokenBricksInflight` — passes)
```
1. DAO + NFTVoting in EarlyExecution mode, 3 NFTs (ALICE x2, BOB x1).
2. ALICE creates a proposal and votes Yes. canExecute(pid) == true.  (healthy baseline)
3. DAO deploys a new GovernanceERC721 and calls plugin.updateVotingToken(newToken)
   -- an ordinary migration proposal.
4. plugin.canExecute(pid)   -> revert Panic(0x11) arithmetic underflow
   plugin.hasSucceeded(pid) -> revert Panic(0x11)
   plugin.execute(pid)      -> revert Panic(0x11)
   Trace: GovernanceERC721::getPastTotalSupply(10) -> 0, then 0 - 2 - 0 underflows.
5. No recovery: the snapshot time point is immutable; the proposal cannot be re-pointed.
```

**Recommendation**: Snapshot the token per proposal and make the early-support maths underflow-proof.
```solidity
struct ProposalParameters {
    VotingMode votingMode;
    uint32 supportThreshold;
    uint64 startDate;
    uint64 endDate;
    uint64 snapshotTimepoint;
    uint256 minVotingPower;
    IVotesUpgradeable snapshotToken;   // NEW: bind the census to the token it was taken against
    uint256 snapshotTotalVotingPower;  // NEW: cache it; immutable once taken
}
```
Set both in `createProposal`; read them in `_canVote`, total-power lookups and `isSupportThresholdReachedEarly` instead of the mutable `votingToken`. Caching the total also removes an external call from the hot path.

Minimum viable fix if the struct change is too invasive — clamp, and reject token updates while proposals are open:
```solidity
function isSupportThresholdReachedEarly(uint256 _proposalId) public view virtual returns (bool) {
    Proposal storage proposal_ = proposals[_proposalId];
    uint256 total = totalVotingPower(proposal_.parameters.snapshotTimepoint);
    uint256 counted = proposal_.tally.yes + proposal_.tally.abstain;
    // Cannot underflow even if the voting token was swapped out from under this proposal.
    uint256 noVotesWorstCase = total > counted ? total - counted : 0;
    return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
        > proposal_.parameters.supportThreshold * noVotesWorstCase;
}
```

---

## [DOS-4] A single reverting action permanently blocks an approved proposal, with no cancel, retry-with-skip or expiry path
**Severity**: Low
**Category**: dos
**Location**: `Proposal._execute()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:50-64`
**Description**:
With the default `allowFailureMap == 0` (both `createProposal` overloads default to `0`, and the plugin only stores a non-zero map), execution is atomic: `DAO.execute` reverts `ActionFailed(i)` on the first failing action and the whole tx rolls back, including `proposal_.executed = true`. The proposal correctly stays un-executed and retryable — no state corruption. But if the failure is *permanent* (passed deadline, self-destructed/reconfigured target, revoked allowance, blocklisted recipient), the approved decision is stuck forever. There is no `cancel`, no way to re-execute with that action skipped, and no execution deadline — `_canExecute` keeps returning `true` indefinitely after `endDate`. Only remedy: a whole new proposal and voting cycle.

Related permanent-failure variant: `DAO.execute`/`Executor.execute` copy every action's full return data into memory and the whole `bytes[]` is ABI-decoded back in the plugin's frame. A proposer can point an action at a contract returning a multi-megabyte blob; quadratic memory expansion makes execution exceed the block gas limit forever. Same "passes the vote, can never execute" outcome as DOS-1, but the low-level call lives in the OSx dependency, not this codebase.

Rated Low because an attacker cannot generally *choose* to make an arbitrary honest proposal's action revert — it depends on the specific targets. This is a missing-recovery-path issue, not an open griefing primitive.

**Proof of Concept**: (`test_poc_revertingActionBlocksForever` — passes)
```
1. DAO + NFTVoting, 3 NFTs. ALICE creates a proposal with one action calling a non-existent
   selector on the DAO (always reverts), allowFailureMap = 0.
2. ALICE votes Yes; proposal passes; warp past endDate. canExecute(pid) == true.
3. plugin.execute(pid) -> reverts.
4. getProposal(pid).executed == false  -- state correctly rolled back, but
5. the action can never succeed, so 3-4 repeat forever. The approved decision is dead, and
   canExecute() keeps advertising it as executable to every UI and keeper.
```

**Recommendation**: Give governance a way out — execution deadline plus an explicit terminal state:
```solidity
// in ProposalParameters
uint64 executionDeadline; // e.g. endDate + executionWindow, set at creation

function _canExecute(uint256 _proposalId) internal view virtual returns (bool) {
    Proposal storage proposal_ = proposals[_proposalId];
    if (proposal_.executed) return false;
    if (block.timestamp > proposal_.parameters.executionDeadline) return false; // expired
    ...
}
```
Optionally add `cancel(uint256)` gated behind a permission held by the DAO (or the proposer before `startDate`), emitting `ProposalCancelled`.

---

## [DOS-5] `vote(..., _tryEarlyExecution = true)` reverts the voter's whole transaction when execution would revert
**Severity**: Low
**Category**: dos
**Location**: `Votes._vote()` — `/home/nnico/public-sector/dao/src/base/Votes.sol:61-71`
**Description**:
`_vote` writes the tally, emits `VoteCast`, then unconditionally calls `_execute(_proposalId)` if `_canExecute(...)` and the permission check pass. `_execute` is not wrapped in `try`/`catch`, so any execution failure — a reverting action (DOS-4), a >256-action proposal (DOS-1), the underflow in DOS-3 — reverts the entire transaction, **including the vote itself**.

The NatSpec at `Votes.sol:27-28` explicitly promises the opposite: *"The call does not revert if early execution is not possible."* That holds for the *eligibility* checks (guarded by the `if`) but not for execution failure.

Concretely, in EarlyExecution mode whichever voter's ballot crosses the early-support threshold cannot cast it at all while using `_tryEarlyExecution = true` — what front-ends typically default to. Anyone can create proposals, so an attacker can cheaply plant a proposal whose actions always revert and burn the gas of every voter trying to be decisive. Bounded: the voter retries with `false` and the vote lands; only voters who opted into that proposal are affected.

**Recommendation**: Honour the documented best-effort semantics by isolating the execution attempt:
```solidity
if (
    _canExecute(_proposalId)
        && dao().hasPermission(address(this), _voter, EXECUTE_PROPOSAL_PERMISSION_ID, _msgData())
) {
    // Best-effort per the NatSpec: a failing execution must never invalidate a valid vote.
    try this.executeFromVote(_proposalId) {} catch {}
}
```
with an `executeFromVote(uint256) external { require(msg.sender == address(this)); _execute(_proposalId); }` trampoline (an external call is required for `try`/`catch` to isolate the revert). This changes semantics from "atomic vote+execute" to "vote always lands", which is the documented intent. Alternative: document that `true` can revert and have front-ends default it to `false`.

---

## [DOS-6] No upper guardrail on `minParticipation` / `minApprovals` lets a single settings proposal permanently lock the DAO
**Severity**: Low
**Category**: dos
**Location**: `Settings._updateVotingSettings()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:116-153`
**Description**:
`_updateVotingSettings` validates `minParticipation` and `minApprovals` only against `RATIO_BASE` (100%) as an **inclusive** upper bound, and `minDuration` up to 365 days. Setting `minParticipation = RATIO_BASE` makes `minVotingPower = _applyRatioCeiled(totalVotingPower, RATIO_BASE) = totalVotingPower` — **every single token in existence must vote**. Since `GovernanceERC721` counts total supply (not just delegated supply) in `getPastTotalSupply`, one NFT behind a lost key, in a contract that cannot call `vote`, or held by an inactive member makes the threshold mathematically unreachable.

No proposal can then ever pass — including the one that would fix the settings, because `UPDATE_VOTING_SETTINGS_PERMISSION_ID` is granted only to the DAO and the DAO can only act through this plugin. Same for `minApprovals = RATIO_BASE`. `minDuration = 365 days` compounds it by making every recovery attempt take a year. (Covered in more depth by the governance pass as GOV-6.)

Rated Low because it requires a passing proposal — governance harming itself rather than an external attacker. **Severity calibration note**: in the default `createDaoAndInstall` flow there is an unintended escape hatch — `DAOFactory.createDao` is called with an empty `PluginSettings[]`, and per `DAOFactory.sol:182-184` that grants `EXECUTE_PERMISSION_ID` on the DAO to the **deploying EOA**, which the script never revokes (`InstallNFTVoting.s.sol:115` — see GOV-1/AC-1/GEN-1). That key could re-point the settings. In a genuinely decentralised deployment (permission revoked, or `installOnExistingDao` against a mature DAO) the lock is **permanent and unrecoverable**.

**Recommendation**:
```solidity
/// @notice Participation/approval ratios above this can become mathematically unreachable
///         (lost keys, contract-held tokens) and would permanently lock governance.
uint32 internal constant MAX_PARTICIPATION_RATIO = 900_000; // 90%

if (_votingSettings.minParticipation == 0 || _votingSettings.minParticipation > MAX_PARTICIPATION_RATIO) {
    revert RatioOutOfBounds({limit: MAX_PARTICIPATION_RATIO, actual: _votingSettings.minParticipation});
}
if (_votingSettings.minApprovals == 0 || _votingSettings.minApprovals > MAX_PARTICIPATION_RATIO) {
    revert RatioOutOfBounds({limit: MAX_PARTICIPATION_RATIO, actual: uint32(_votingSettings.minApprovals)});
}
```
Independently, keep a permissioned break-glass path (guardian/multisig holding `UPDATE_VOTING_SETTINGS_PERMISSION_ID` alongside the DAO) so settings can be repaired without going through the plugin the bad settings disabled.

---

## [DOS-7] Any address with zero tokens can create unlimited proposals under the default install
**Severity**: Low
**Category**: dos
**Location**: `Proposal.canCreateProposal()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:175-193`; `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:197,248`
**Description**:
`canCreateProposal` short-circuits to `true` whenever `minProposerVotingPower() == 0`, and the install script defaults `MIN_PROPOSER_VOTING_POWER` to `0` while granting `CREATE_PROPOSAL_PERMISSION_ID` to `ANY_ADDR`. The standard deployment lets an address that holds no NFT, never held one, and has no stake create an unbounded number of proposals for the cost of gas.

There is no shared mutable state across proposals — each lives under its own `proposals[id]` key with its own snapshotted parameters — so this is **not** a protocol-wide DoS and does not degrade honest proposals' storage or execution. Impact is off-chain: event-log and UI flooding, drowning legitimate proposals, forcing indexers/front-ends to build their own spam filtering. It is also the enabling precondition that makes DOS-1 and DOS-5 cheap for an unaffiliated attacker rather than limited to token holders. (Independently confirmed by the access-control pass as AC-7 and the general pass as GEN-7.)

**Proof of Concept**: (`test_poc_anyoneCanCreate` — passes)
```
1. DAO + NFTVoting with a single NFT minted to ALICE. Default NFTDAOBuilder settings.
2. vm.prank(RANDOM_ADDRESS)  // holds no NFT and never did
   plugin.createProposal("spam", noActions, 0, 0, 0)  -> SUCCEEDS
   Repeat indefinitely; each call costs only base proposal-storage gas.
```

**Recommendation**:
```solidity
// script/InstallNFTVoting.s.sol
// Default to requiring at least one NFT to propose; operators may lower it explicitly.
params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(1));
```
Better: replace the `ANY_ADDR` grant with `grantWithCondition` using a token-holding condition, so the permission layer — not just a settings value — enforces membership. Document loudly if a fully open proposal surface is intended.

---

## [DOS-8] `GovernanceERC721.initialize` mints in an unbounded loop
**Severity**: Info
**Category**: dos
**Location**: `GovernanceERC721.initialize()` — `/home/nnico/public-sector/dao/src/erc721/GovernanceERC721.sol:96-102`
**Description**:
The loop over `_settings.receivers` calls `_mintTo` per entry with no cap; each entry costs several SSTOREs plus checkpoint writes and the self-delegation `_delegate(to, to)` (~90-100k gas per receiver). The install script amplifies this by expanding `NFT_COUNT` into an `nftCount`-length array of the same address, minting that many *separate* NFTs rather than one balance.

No security impact: `initialize` is `initializer`-gated and, in the only supported path, called from the constructor (which then calls `_disableInitializers()`). Parameters are entirely deployer-controlled and one-shot. An oversized array simply makes the deployment tx run out of gas and revert atomically — nothing partially minted, no state persists, retry with a smaller batch.

**Proof of Concept**: N/A — no adversarial scenario. Deployment reverts out-of-gas; no contract is created.

**Recommendation**: No fix required. If a large genesis distribution is anticipated, add a permissioned batch-mint so it can be split across transactions after deployment:
```solidity
function mintBatch(address[] calldata _to) external virtual auth(MINT_PERMISSION_ID) {
    for (uint256 i; i < _to.length;) { _mintTo(_to[i]); unchecked { ++i; } }
}
```

---

## Checklist items reviewed and found NOT exploitable

- **`getProposal()` unbounded-read DoS — NOT exploitable.** The checklist hypothesis was that a huge `actions` array could OOG `getProposal()`. It cannot: `actions` are written *only* inside `createProposal`, so the whole array must fit in one transaction, bounding stored action data at roughly `blockGasLimit / 22,100` ≈ 1,350 fresh slots (~43 KB) on a 30M-gas chain. Reading that back costs ~2,100 gas/cold slot ≈ 2.8M gas — an order of magnitude under the ~50M `eth_call` budget of typical public RPCs. Creation gas is the binding constraint and sits far below read limits, so no "poison `getProposal`" proposal is constructible. The real consequence of an oversized array is DOS-1, not a broken getter.
- **`execute()` missing `onlyIfProposalExists` — benign.** Unlike `canExecute`/`hasSucceeded`/`canVote`, `execute` has no existence modifier. Traced for a non-existent id: `executed == false`, `_isProposalOpen` false (`now < endDate == 0` fails), `votingMode == Standard`, falls through to `_hasSucceeded(id, false)` → `isSupportThresholdReached` evaluates `(RATIO_BASE - 0) * 0 > 0 * 0` → `0 > 0` → false. Reverts `ProposalExecutionForbidden` as intended. No phantom-proposal execution.
- **`isSupportThresholdReachedEarly` underflow from normal voting — not reachable.** `getPastTotalSupply` on OZ `Votes` tracks total supply *including* undelegated tokens, while `tally.yes + tally.abstain` can only ever sum delegated power, so `total - yes - abstain` cannot underflow through ordinary voting. The only route is the token swap in DOS-3.
- **`_updateVotingToken` ERC-165 probe — fails safe.** No-code token → empty returndata → `abi.decode` reverts; reverting token propagates. Either way `votingToken` is unchanged and no update path is bricked.
- **Proposal-ID collision front-running — already fixed, not re-reported.** `_createProposalId(keccak256(abi.encode(_msgSender(), _actions, _metadata)))` includes the sender (commit `5298852`), so a griefer can no longer pre-register a victim's `(actions, metadata)` pair to force `ProposalAlreadyExists`. Verified present in current source.
- **Early-execution outcome griefing — none found.** `execute()` in EarlyExecution mode is only reachable once `isSupportThresholdReachedEarly` holds, which by construction means no remaining voter can change the outcome. A third party executing early cannot alter *what* passes. The residual concern is *when*, captured in DOS-2 and GOV-7. No execution reward exists, so no first-executor value capture to race for.
- **Repeated failed `execute()` attempts — no shared-state cost.** No cooldown, but a failing attempt reverts entirely; the griefer pays their own gas and consumes no other user's state or gas. Not a finding.
- **Cross-proposal interference — none.** Each proposal snapshots `votingMode`, `supportThreshold`, `minVotingPower`, `minApprovalPower` and `targetConfig` at creation, so `updateVotingSettings` and `setTargetConfig` cannot retroactively alter in-flight proposals. The sole exception is the voting *token*, which is not snapshotted — that is DOS-3.
- **Pause-related DoS — N/A, confirmed.** No pause, freeze or circuit-breaker anywhere. Intentionally absent.
- **Oracle DoS — N/A, confirmed.** No price feed, no `latestRoundData`, no external data source. The only external reads are `IVotesUpgradeable` census calls against the DAO's own governance token.
- **Gas griefing via untrusted external call / returndata — N/A in this codebase, confirmed.** No `.call(`/`delegatecall`/`staticcall` in `src/`. All action dispatch happens inside `DAO.execute`/`Executor.execute` in the `osx`/`osx-commons` dependencies (out of scope); the plugin only calls `IExecutor(target).execute(...)` through the typed `PluginCloneable._execute` helper. The one dependency-side observation worth carrying forward (returndata-bomb memory expansion making an approved proposal permanently unexecutable) is folded into DOS-4.

Deliberately *not* reported as findings: the "proposer submits a huge array against their own proposal" framing (the real bug there is the missing `MAX_ACTIONS` check + dishonest `canExecute`, which is what DOS-1 reports), and the `getProposal` OOG theory, which was disproven with gas arithmetic rather than assumed.
