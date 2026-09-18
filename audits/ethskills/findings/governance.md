# Governance audit of NFTVoting

10 findings (1 Critical, 1 High, 5 Medium, 1 Low, 2 Info).

Scope read in full: `src/NFTVoting.sol`, `src/base/{INFTVoting,Proposal,Settings,Votes}.sol`, `src/erc721/GovernanceERC721.sol`, `script/InstallNFTVoting.s.sol`, `README.md`, plus `.env.example`. Library behaviour verified against vendored sources in `lib/`: OSx `PermissionManager`, OSx `DAOFactory`, osx-commons `ProposalUpgradeable`/`Plugin`/`Ratio`, OZ 4.x `VotesUpgradeable`.

---

## [GOV-1] Deployer keeps permanent `EXECUTE_PERMISSION` on the DAO — governance plugin is bypassable forever
**Severity**: Critical
**Category**: governance
**Location**: `InstallNFTVotingScript.createDaoAndInstall()` / `_buildPermissionActions()` — `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:110-131`, `:188-209`

**Description**:
`createDaoAndInstall` creates the DAO with an empty plugin-settings array:
```solidity
(dao_,) = _daoFactory.createDao(_daoSettings, new DAOFactory.PluginSettings[](0));
```
In `DAOFactory.createDao`, that branch does (`lib/osx/packages/contracts/src/framework/dao/DAOFactory.sol:182-184`):
```solidity
} else {
    // if no plugin setting is provided, grant EXECUTE_PERMISSION_ID to msg.sender
    createdDao.grant(daoAddress, msg.sender, EXECUTE_PERMISSION_ID);
}
```
The script relies on that grant to run `_dao.execute(bytes32(0), actions, 0)` during install, but **never revokes it**. `_buildPermissionActions` builds 6 (or 10) actions, all `_grantAction`; `grep -rn "revoke" script/` returns nothing.

After a default `just deploy`, the deployer EOA holds `EXECUTE_PERMISSION_ID` on the DAO permanently, in parallel with the plugin. It can call `dao.execute()` with arbitrary actions, bypassing NFTVoting entirely: drain the treasury, `grant` itself `ROOT_PERMISSION_ID`, mint unlimited `GovernanceERC721` NFTs to itself (the DAO holds `MINT_PERMISSION_ID` and the deployer drives the DAO), revoke the plugin's `EXECUTE_PERMISSION`, or rewrite voting settings. The NFT governance process is decorative while that key exists.

Made worse by the documented ceremony, which tells the operator to use a throwaway key and then walk away from it (`README.md:231`, `:265`): "I have created a new burner wallet with `cast wallet new`…" / "I have transferred the remaining funds of the deployment wallet to the address that originally funded it". A burner key expected to be discarded retains god-mode. Any later leak (backup, shell history, CI log, `.env`, the `broadcast/` artifacts the README says to upload) is a full DAO compromise.

(Independently confirmed by the access-control pass as AC-1 and the general pass as GEN-1 — the same root cause found by three angles.)

**Proof of Concept**:
1. Run `just deploy` with `EXISTING_DAO_ADDRESS` unset and default `.env`.
2. `DAOFactory.createDao(settings, [])` grants `EXECUTE_PERMISSION_ID` on the new DAO to the deployer EOA.
3. `installOnExistingDao` consumes it once for the permission batch; no action in `actions[0..9]` revokes it.
4. Verify: `cast call $DAO "hasPermission(address,address,bytes32,bytes)(bool)" $DAO $DEPLOYER $(cast keccak "EXECUTE_PERMISSION") 0x` → `true`.
5. Six months later, with NFTs distributed and governance live, one transaction:
```solidity
Action[] memory a = new Action[](1);
a[0] = Action({to: address(dao), value: 0,
    data: abi.encodeCall(PermissionManager.grant, (address(dao), attacker, dao.ROOT_PERMISSION_ID()))});
dao.execute(bytes32("pwn"), a, 0);
```
Attacker has `ROOT_PERMISSION_ID`. No proposal, no vote, no quorum.

**Recommendation**:
Revoke the deployer's `EXECUTE_PERMISSION` as the **last** action of the same install batch (permission is checked once on entry to `dao.execute`, so self-revoking mid-batch is safe; the DAO holds `ROOT_PERMISSION_ID` on itself). Keep it opt-out for the existing-DAO flow.
```solidity
 function installOnExistingDao(DAO _dao, InstallParams memory _params) public returns (...) {
     ...
-    Action[] memory actions = _buildPermissionActions(_dao, plugin_, token_, mintedNewToken);
+    Action[] memory actions =
+        _buildPermissionActions(_dao, plugin_, token_, mintedNewToken, _params.revokeDeployerExecute);
     _dao.execute(bytes32(0), actions, 0);
 }
```
```solidity
 function _buildPermissionActions(
     DAO _dao, NFTVoting _plugin, IVotesUpgradeable _token,
     bool _mintedNewToken, bool _revokeDeployerExecute
 ) internal view returns (Action[] memory actions) {
-    actions = new Action[](_mintedNewToken ? 10 : 6);
+    uint256 n = (_mintedNewToken ? 10 : 6) + (_revokeDeployerExecute ? 1 : 0);
+    actions = new Action[](n);
     ...
+    // MUST be last: the DAO revokes the deployer's direct execute rights on itself, so the
+    // NFTVoting plugin becomes the only route to `dao.execute`.
+    if (_revokeDeployerExecute) {
+        actions[n - 1] = Action({to: address(_dao), value: 0,
+            data: abi.encodeCall(PermissionManager.revoke,
+                (address(_dao), deployer, _dao.EXECUTE_PERMISSION_ID()))});
+    }
 }
```
Default `revokeDeployerExecute = true` for the new-DAO flow. Add a post-deployment checklist item asserting `hasPermission(dao, deployer, EXECUTE_PERMISSION) == false`, and state that until then the deployer key is a full DAO backdoor.

---

## [GOV-2] `_startDate` is unbounded into the future — proposals can be pinned to an arbitrarily stale census
**Severity**: High
**Category**: governance
**Location**: `Proposal._validateProposalDates()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:366-404`, with `Proposal.createProposal()` — `:263-293`

**Description**:
`snapshotTimepoint` is frozen at creation, and `minVotingPower`/`minApprovalPower` derive from `totalVotingPower(snapshotTimepoint)` at that instant. The *voting window* can be scheduled arbitrarily far ahead:
```solidity
if (_start == 0) { startDate = currentTimestamp; }
else {
    startDate = _start;
    if (startDate < currentTimestamp) {          // only a LOWER bound
        revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
    }
}
uint64 earliestEndDate = startDate + votingSettings.minDuration;
if (_end == 0) {
    endDate = earliestEndDate;                    // no cap checked at all in this branch
} else {
    ...
    uint64 latestEndDate = startDate + 365 days;  // caps duration RELATIVE TO startDate only
    if (endDate > latestEndDate) { revert ... }
}
```
The 365-day ceiling added in `5c21a0d` bounds `endDate - startDate`, not `startDate - block.timestamp`. `_startDate = block.timestamp + 10 years` with `_endDate = 0` is accepted and skips the `latestEndDate` check entirely.

Result: a proposal whose electorate is today's census but whose vote happens years later. Voting power is `getPastVotes(_voter, snapshotTimepoint)` (`Votes.sol:36`, `:111`) and is immutable, so: whoever held NFTs at creation can still vote after selling/transferring/being force-transferred out of every token; everyone who joined later has 0 power and cannot vote, abstain or oppose; and there is no cancel/veto anywhere, with `proposals[id]` never cleared. Since `CREATE_PROPOSAL_PERMISSION_ID` is `ANY_ADDR` and `minProposerVotingPower` defaults to 0, *anyone* — including a non-holder — can pick the census block and let a colluding holder vote later. (Independently confirmed by the precision-math pass as MATH-1 and the general pass as GEN-4.)

**Proof of Concept**:
1. At `t0` the founding cohort holds ≥ quorum + majority. Under install defaults this is one address: `NFT_COUNT=1` minted to the deployer → 100%.
2. It calls:
```solidity
plugin.createProposal(
    metadata,
    [ Action({to: dao, value: 0, data: abi.encodeCall(PermissionManager.grant,
              (address(dao), attacker, dao.ROOT_PERMISSION_ID()))}) ],
    0,
    uint64(block.timestamp + 3650 days),  // _startDate: accepted, no upper bound
    0                                     // _endDate == 0 -> startDate + minDuration, cap skipped
);
```
`snapshotTimepoint = t0 - 1`; `minVotingPower = ceil(N_t0 * 10%)`; `minApprovalPower = 1`.
3. Proposal is dormant and invisible to normal UIs (neither open nor succeeded). Creator sells every NFT. Over a decade the DAO mints to hundreds of citizens; the original cohort fully rotates out.
4. At `t0 + 10y` the window opens for `minDuration` (1 hour default). Attacker votes Yes with `getPastVotes(attacker, t0-1)` = decade-old holdings → 100% support and participation against the `t0` census.
5. Current members cannot counter-vote (`_canVote` returns false at `Votes.sol:111`) and cannot cancel. `EXECUTE_PROPOSAL_PERMISSION_ID` is `ANY_ADDR`, so the attacker executes immediately. Full capture by a long-departed member.

Same mechanism lets any coalition that *ever* held quorum park time-bomb proposals for arbitrary future dates, live forever.

**Recommendation**:
```solidity
+/// @notice The furthest into the future a proposal's voting window may be scheduled. Bounds how
+///     stale the frozen `snapshotTimepoint` census can be when voting actually starts.
+uint64 internal constant MAX_START_OFFSET = 30 days;

 function _validateProposalDates(uint64 _start, uint64 _end)
     internal view virtual returns (uint64 startDate, uint64 endDate)
 {
     uint64 currentTimestamp = block.timestamp.toUint64();
     if (_start == 0) { startDate = currentTimestamp; }
     else {
         startDate = _start;
         if (startDate < currentTimestamp) {
             revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
         }
+        uint64 latestStartDate = currentTimestamp + MAX_START_OFFSET;
+        if (startDate > latestStartDate) {
+            revert DateOutOfBounds({limit: latestStartDate, actual: startDate});
+        }
     }
     uint64 earliestEndDate = startDate + votingSettings.minDuration;
+    // Absolute ceiling measured from creation, so the snapshot can never be older than
+    // MAX_START_OFFSET + 365 days when the vote closes. Applies to the defaulted end date too.
+    uint64 latestEndDate = currentTimestamp + MAX_START_OFFSET + 365 days;
     if (_end == 0) {
         endDate = earliestEndDate;
+        if (endDate > latestEndDate) {
+            revert DateOutOfBounds({limit: latestEndDate, actual: endDate});
+        }
     } else {
         endDate = _end;
         if (endDate < earliestEndDate) { revert DateOutOfBounds({limit: earliestEndDate, actual: endDate}); }
-        uint64 latestEndDate = startDate + 365 days;
         if (endDate > latestEndDate) { revert DateOutOfBounds({limit: latestEndDate, actual: endDate}); }
     }
 }
```
Also consider a cancel path (a `CANCEL_PROPOSAL_PERMISSION_ID` held by the DAO, or letting the proposer withdraw before `startDate`) so a hostile dormant proposal is not irrevocable.

---

## [GOV-3] Succeeded proposals never expire — unbounded execution window
**Severity**: Medium
**Category**: governance
**Location**: `Proposal._canExecute()` / `Proposal._hasSucceeded()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:81-142`

**Description**: `_canExecute` checks only `executed`, open/closed state, and the three static tally criteria. Nothing bounds *when* execution may happen after `endDate`. A proposal that reached its thresholds is executable forever, and with `EXECUTE_PROPOSAL_PERMISSION_ID` on `ANY_ADDR` the executor is arbitrary. Since `Action[]` payloads are frozen at creation, an approved action can be held back and fired at a moment of the holder's choosing, long after the circumstances the electorate approved it under changed — e.g. a proposal approving `transfer(contractor, 50 ETH)` passes when the treasury is empty so nobody objects, and a year later anyone executes it against a funded treasury. `Tally` and thresholds are historical, so re-evaluation gives the same answer forever.

**Proof of Concept**:
1. Proposal with `endDate = T` reaches support/participation/approval and closes at `T`. Nobody executes it (deliberately, or the treasury cannot cover it yet).
2. `canExecute(id)` keeps returning `true` indefinitely: `executed == false`, `_isProposalOpen == false` so the `votingMode != EarlyExecution && isProposalOpen` early-return at `Proposal.sol:92` is not taken, and `_hasSucceeded(id, false)` re-reads the same frozen tally.
3. At `T + 2 years`, after the electorate, treasury and integrations changed, any address calls `plugin.execute(id)`.

**Recommendation**:
```solidity
+/// @notice How long after `endDate` a succeeded proposal stays executable.
+uint64 internal constant EXECUTION_GRACE_PERIOD = 14 days;

 function _canExecute(uint256 _proposalId) internal view virtual returns (bool) {
     Proposal storage proposal_ = proposals[_proposalId];
     if (proposal_.executed) { return false; }
     bool isProposalOpen = _isProposalOpen(proposal_);
     if (proposal_.parameters.votingMode != VotingMode.EarlyExecution && isProposalOpen) { return false; }
+    // A proposal that was approved but left unexecuted expires, so stale actions cannot be fired
+    // against a state the electorate never evaluated.
+    if (!isProposalOpen && block.timestamp > proposal_.parameters.endDate + EXECUTION_GRACE_PERIOD) {
+        return false;
+    }
     return _hasSucceeded(_proposalId, isProposalOpen);
 }
```
Make the grace period a validated voting setting if a fixed constant is too rigid.

---

## [GOV-4] `updateVotingToken` corrupts or permanently bricks in-flight proposals
**Severity**: Medium
**Category**: governance
**Location**: `Settings.updateVotingToken()` / `_updateVotingToken()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:158-180`; consumed at `src/base/Votes.sol:36`, `:111` and `src/base/Settings.sol:69-71`

**Description**: `snapshotTimepoint` is stored per proposal, but the **token is not**. Every voting-power read resolves `votingToken` from current storage: `Votes._vote:36`, `Votes._canVote:111`, and `Proposal.isSupportThresholdReachedEarly:155` (via `totalVotingPower`). `updateVotingToken` has no guard for open proposals. Swapping the token while proposals are live produces three failures:

1. **Tally underflow/corruption (VoteReplacement).** `_vote` decrements the previous vote using the power read *now*, assuming it equals what was added:
```solidity
uint256 votingPower = votingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint);
...
if (state == VoteOption.Yes) { proposal_.tally.yes = proposal_.tally.yes - votingPower; }
```
After a swap the new token returns a different number. Larger → underflow revert (that voter can never change or re-cast). Smaller → tally permanently inflated, proposal can pass on votes nobody cast.
2. **Permanent revert of `execute`/`canExecute` (EarlyExecution).** `totalVotingPower(snapshot) - tally.yes - tally.abstain` (`Proposal.sol:154-155`) is only underflow-safe because tallies accumulated against that same checkpoint tree. Against a different token's `getPastTotalSupply` it can underflow → `_canExecute` reverts → `execute()`/`canExecute()` revert forever.
3. **`Votes: future lookup` revert across the board.** OZ 4.x requires `timepoint < clock()` (`VotesUpgradeable.sol:104-107`). If the old token was timestamp-clocked (`snapshotTimepoint ≈ 1.7e9`) and the new one block-number-clocked (`clock() ≈ 2.3e7`), *every* `getPastVotes`/`getPastTotalSupply` call for open proposals reverts: `vote()`, `canVote()`, `execute()`, `canExecute()` permanently bricked. `_detectTokenClock()` refreshes `tokenIndexedByTimestamp` for *future* proposals but does nothing for stored `snapshotTimepoint` values.

(Independently confirmed with passing PoCs by the general pass as GEN-2, the precision-math pass as MATH-2, the ERC-721 pass as NFT-1, and the DoS pass as DOS-3 — the single most cross-confirmed finding in this audit.)

**Proof of Concept**:
1. Plugin installed with token A (block-number clock), `votingMode = VoteReplacement`.
2. Proposal P created at block `B`; `snapshotTimepoint = B-1`. Alice holds 3 NFTs on A, votes Yes → `tally.yes = 3`.
3. A census-migration proposal passes and calls `updateVotingToken(B)` with a new timestamp-clocked `GovernanceERC721`.
4. Alice tries to change her vote. `_canVote` calls `B.getPastVotes(alice, B-1)`; since `B.clock() == block.timestamp` and `B-1` is a small block number, the lookup returns B's first checkpoint value (likely 0) → `_canVote` false, Alice locked out. With roles reversed (old timestamp-clocked, new block-number-clocked) the call reverts `Votes: future lookup` and P becomes permanently unvotable **and unexecutable**.
5. Meanwhile `isSupportThresholdReachedEarly` computes `B.getPastTotalSupply(B-1) - 3 - 0`; if that supply is 0, `0 - 3` underflows and `execute(P)` reverts forever.

**Recommendation**: Pin the token per proposal exactly as the snapshot is pinned.
```solidity
 struct ProposalParameters {
     VotingMode votingMode;
     uint32 supportThreshold;
     uint64 startDate;
     uint64 endDate;
     uint64 snapshotTimepoint;
+    IVotesUpgradeable votingToken;   // pinned with the snapshot; a later `updateVotingToken`
+                                     // must not reinterpret an existing proposal's census
     uint256 minVotingPower;
 }
```
```solidity
 // Proposal.createProposal
 proposal_.parameters.snapshotTimepoint = snapshotTimepoint.toUint64();
+proposal_.parameters.votingToken = votingToken;
```
```solidity
 // Votes._vote / Votes._canVote
-uint256 votingPower = votingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint);
+uint256 votingPower =
+    proposal_.parameters.votingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint);
```
and likewise in `isSupportThresholdReachedEarly`. If the storage change is undesirable, the minimum mitigation is to make `updateVotingToken` revert while any proposal is open or succeeded-but-unexecuted, and document that a token migration requires draining the proposal queue first.

---

## [GOV-5] Quorum denominator counts undelegated tokens — permissionless `delegate(address(0))` quorum griefing
**Severity**: Medium
**Category**: governance
**Location**: `Settings.totalVotingPower()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:63-71`; consumed at `src/base/Proposal.sol:155`, `:296`, `:298`

**Description**: The NatSpec claims `totalVotingPower` "equals the number of tokens that have been **delegated** (and are therefore authorized to vote)". This is **incorrect**. In OZ 4.x `VotesUpgradeable._transferVotingUnits` (`lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/VotesUpgradeable.sol:170-178`), `_totalCheckpoints` is touched only on mint (`from == 0`) and burn (`to == 0`); `_moveDelegateVotes` is an independent update. So `getPastTotalSupply` is **minted minus burned, regardless of delegation**, while `getPastVotes` is zero for any holder delegating to `address(0)`. `delegate(address(0))` is permitted — `VotesUpgradeable.delegate` has no zero check — and `GovernanceERC721._afterTokenTransfer` only auto-self-delegates on mint/transfer, so a holder who opts out stays opted out while holding.

Consequences: (a) **Quorum griefing** — `minVotingPower = _applyRatioCeiled(totalVotingPower_, minParticipation())` (`Proposal.sol:296`) uses the inflated denominator while max reachable turnout is only the delegated supply; with undelegated fraction `U`, quorum is unreachable whenever `1 - U < minParticipation`. A large holder can deadlock governance permanently, cheaply and reversibly, without transferring or burning anything. (b) **Early-execution mismatch with the README spec** — `noVotesWorstCase = totalVotingPower(snapshot) - yes - abstain` (`Proposal.sol:154-155`) counts undelegated tokens as potential No votes that can never be cast, making early execution strictly harder than the derivation says. Conservative and therefore safe, but a real divergence. No underflow risk arises from this: sum of `getPastVotes` is always ≤ `getPastTotalSupply` (the one exception being GOV-4). (Independently confirmed by the ERC-721 pass as NFT-4, with matching passing PoC.)

**Proof of Concept**:
1. A civic DAO sets `MIN_PARTICIPATION = 500000` (50%) — natural for a small public-sector membership where every NFT is a registered citizen.
2. 1000 NFTs minted; all self-delegated by `_afterTokenTransfer`, so `getPastTotalSupply = 1000` and reachable turnout is 1000.
3. A coalition controlling 510 NFTs calls `delegate(address(0))` from each address. No transfer, no burn, no permission needed.
4. `getPastTotalSupply` is **still 1000** (only mint/burn move `_totalCheckpoints`), so every new proposal gets `minVotingPower = ceil(1000 * 50%) = 500`, but max castable votes is now 490.
5. `isMinParticipationReached` can never return true. Every proposal fails. Governance is dead until the coalition voluntarily re-delegates — and per GOV-6 the settings cannot be fixed, because fixing them requires a passing proposal.

**Recommendation**: At minimum fix the misleading NatSpec, which is what makes this invisible to an operator choosing `minParticipation`:
```solidity
-/// @dev For an ERC-721 `Votes` token this equals the number of tokens that have been delegated (and are
-///     therefore authorized to vote) at `_timePoint`, since each token counts as exactly one unit of
-///     voting power.
+/// @dev For an ERC-721 `Votes` token this equals the number of tokens minted minus burned at `_timePoint`,
+///     since each token counts as exactly one unit of voting power. NOTE: OpenZeppelin's `Votes` updates
+///     the total-supply checkpoints on mint/burn only, so this INCLUDES tokens whose holder has delegated
+///     to `address(0)` and which therefore cannot be voted. Reachable turnout is always <= this value, so
+///     `minParticipation` must leave headroom for holders who opt out of delegation, or quorum can become
+///     unreachable.
 function totalVotingPower(uint256 _timePoint) public view returns (uint256) {
```
Stronger fix — since opting out of delegation has no legitimate use in a closed civic membership token, block it in `GovernanceERC721`:
```solidity
+/// @notice Thrown when a holder tries to delegate to the zero address, which would remove their voting
+///     power from the numerator while leaving the quorum denominator unchanged.
+error ZeroDelegateNotAllowed();
+
+/// @inheritdoc VotesUpgradeable
+/// @dev Delegating to `address(0)` is rejected: `getPastTotalSupply` (the quorum denominator) counts
+///     minted-minus-burned tokens regardless of delegation, so allowing it lets a holder shrink reachable
+///     turnout without shrinking the denominator and thereby stall quorum for everyone.
+function _delegate(address account, address delegatee) internal virtual override {
+    if (delegatee == address(0)) { revert ZeroDelegateNotAllowed(); }
+    super._delegate(account, delegatee);
+}
```
(Keep the `_afterTokenTransfer` hook's `delegates(to) == address(0)` check — with this override that condition only ever holds for a fresh receiver, which is exactly its intent.)

---

## [GOV-6] Governance can permanently brick itself via unbounded settings, with no recovery path
**Severity**: Medium
**Category**: governance
**Location**: `Settings._updateVotingSettings()` — `/home/nnico/public-sector/dao/src/base/Settings.sol:116-153`; `Proposal.canCreateProposal()` — `src/base/Proposal.sol:175-193`; `script/InstallNFTVoting.s.sol:195`

**Description**: The install grants `UPDATE_VOTING_SETTINGS_PERMISSION_ID` **only** to the DAO (`actions[0]`), and the DAO acts only through executed proposals. No admin, guardian or emergency holder exists. So any setting that makes proposals impossible to create or pass is irreversible — repairing it requires the mechanism it disabled. `_updateVotingSettings` validates ratios and duration but leaves bricking values reachable:
- **`minProposerVotingPower` has no upper bound at all.** Above the largest single holder's power, `canCreateProposal` returns false for everyone (`getPastVotes(_account, snapshotTimepoint) >= minProposerVotingPower_`), so `createProposal` reverts `ProposalCreationForbidden` permanently.
- **`minParticipation` may be `RATIO_BASE` (100%).** With GOV-5, or with any NFT held by a contract that cannot call `vote`, turnout can never reach 100% and nothing can ever pass again.
- **Burning the entire supply.** The DAO holds `BURN_PERMISSION_ID`, and `createProposal:276-278` reverts `NoVotingPower` when total is 0. A proposal burning the last NFT ends governance irrecoverably. (The zero-supply revert itself is correct and is what closes the "pass proposals before tokens are minted" class — the issue is that it is a one-way door.)

These are footguns requiring a passed proposal, but each is one transaction from irreversible loss of the DAO and any treasury it holds. (Independently touched by the DoS pass as DOS-6.)

**Proof of Concept**:
1. A proposal (mistake, or hostile with temporary control) calls `updateVotingSettings({..., minProposerVotingPower: 1e30, ...})` and executes.
2. Every subsequent `createProposal` reverts: `canCreateProposal(x)` → `getPastVotes(x, snapshot) >= 1e30` → false → `ProposalCreationForbidden`.
3. Fixing requires `updateVotingSettings` → `UPDATE_VOTING_SETTINGS_PERMISSION_ID` → only the DAO → only via `dao.execute` driven by the plugin → requires a proposal. Unrecoverable. (With GOV-1 unfixed, the deployer's stray `EXECUTE_PERMISSION` is the *only* thing that could unbrick this — which is not a mitigation, it's a second critical problem.)

**Recommendation**:
```solidity
 function _updateVotingSettings(VotingSettings calldata _votingSettings) internal virtual {
     ...
-    if (_votingSettings.minParticipation == 0 || _votingSettings.minParticipation > RATIO_BASE) {
-        revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minParticipation});
-    }
+    // Require minParticipation in [1, 10^6 - 1]. 100% is excluded: any token that is undelegated,
+    // burned or held by a contract that cannot vote would make quorum permanently unreachable, and the
+    // settings could then never be repaired (only the DAO holds UPDATE_VOTING_SETTINGS_PERMISSION_ID,
+    // and the DAO only acts through a passing proposal).
+    if (_votingSettings.minParticipation == 0 || _votingSettings.minParticipation > RATIO_BASE - 1) {
+        revert RatioOutOfBounds({limit: RATIO_BASE - 1, actual: _votingSettings.minParticipation});
+    }
     ...
+    // Cap the proposer threshold against the live census, so no settings update can lock every account
+    // out of `createProposal` and make governance unrecoverable.
+    if (address(votingToken) != address(0) && _votingSettings.minProposerVotingPower != 0) {
+        uint256 timePoint;
+        unchecked { timePoint = tokenIndexedByTimestamp ? block.timestamp - 1 : block.number - 1; }
+        uint256 supply = votingToken.getPastTotalSupply(timePoint);
+        if (_votingSettings.minProposerVotingPower > supply) {
+            revert MinProposerVotingPowerOutOfBounds({
+                limit: supply, actual: _votingSettings.minProposerVotingPower});
+        }
+    }
```
Add `error MinProposerVotingPowerOutOfBounds(uint256 limit, uint256 actual);` to `INFTVoting`; guard the `votingToken == address(0)` case because `_updateVotingSettings` runs before `_updateVotingToken` in `initialize`. Separately consider an invariant that supply cannot reach zero, or a multi-sig guardian on `UPDATE_VOTING_SETTINGS_PERMISSION_ID` as a documented break-glass path.

---

## [GOV-7] No execution delay + `ANY_ADDR` executor: the execution block is attacker-chosen
**Severity**: Medium
**Category**: governance
**Location**: `Proposal.execute()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:41-46`; `script/InstallNFTVoting.s.sol:200`

**Description**: `EXECUTE_PROPOSAL_PERMISSION_ID` is granted to `ANY_ADDR`, there is no timelock between "succeeded" and "executable", and (per GOV-3) no deadline after it. The plugin hands an arbitrary third party control over *which block, and in which surrounding state*, an approved `Action[]` runs. The payload is frozen at creation (`proposal_.actions` written only in `createProposal`; `allowFailureMap`/`targetConfig` likewise), so the *what* is safe. The *when* is not. For any action whose outcome depends on external state — a DEX swap, an oracle-priced purchase, a liquidation, a parameter change racing another protocol — the executor can wrap `plugin.execute(id)` in an MEV bundle and choose the worst surrounding state for the DAO. The DAO has no recourse: it cannot execute first (its route for the plugin's actions *is* the plugin), cancel, or delay. (Overlaps with the DoS pass's DOS-2, which additionally shows the permissionless executor can skip `allowFailureMap`-marked actions.)

**Proof of Concept**:
1. A proposal approving `swapExactTokensForTokens(500_000 USDC → GOV, minOut, ...)` from the treasury reaches its thresholds at `endDate`.
2. A searcher observes `canExecute(id) == true`; `ANY_ADDR` means no tokens, membership or proposal needed.
3. Single bundle: (a) buy GOV to push the pool price up, (b) `plugin.execute(id)` so the DAO buys at the inflated price, (c) sell back. The DAO eats the sandwich, bounded only by whatever `minOut` the proposal encoded.
4. With no expiry (GOV-3) and no delay, the searcher can also simply wait for the most profitable moment over an unbounded window.

This is *not* the early-execution-timing concern from the checklist: `isSupportThresholdReachedEarly` is genuinely conclusive (vote replacement is disabled in `EarlyExecution` mode so `yes` never decreases, and `minParticipation`/`minApproval` are monotonically increasing), so an early executor cannot flip a failing proposal into a passing one. The exploitable degree of freedom is surrounding chain state, not the outcome.

**Recommendation**:
```solidity
+/// @notice Minimum delay between a proposal becoming executable and execution being permitted.
+///     Prevents an arbitrary executor (EXECUTE_PROPOSAL_PERMISSION is typically granted to ANY_ADDR)
+///     from atomically bundling state manipulation around `execute`.
+uint64 internal constant EXECUTION_DELAY = 1 days;

 function _canExecute(uint256 _proposalId) internal view virtual returns (bool) {
     ...
     if (proposal_.parameters.votingMode != VotingMode.EarlyExecution && isProposalOpen) { return false; }
+    if (!isProposalOpen && block.timestamp < proposal_.parameters.endDate + EXECUTION_DELAY) {
+        return false;
+    }
     return _hasSucceeded(_proposalId, isProposalOpen);
 }
```
If the plugin must stay timelock-free: restrict `EXECUTE_PROPOSAL_PERMISSION_ID` to known executors (or to `ANY_ADDR` behind a `grantWithCondition` condition contract) instead of open `ANY_ADDR`, and document in `README.md` that proposals containing price-sensitive actions must carry their own slippage/deadline guards because the DAO does not control the execution block.

---

## [GOV-8] `MIN_APPROVALS` install default silently disables the min-approval criterion; `.env.example` documents a value that reverts
**Severity**: Low
**Category**: governance
**Location**: `InstallNFTVotingScript._readVotingSettings()` — `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:249`; `/home/nnico/public-sector/dao/.env.example:42`

**Description**: `minApprovals` is a ratio in `[1, RATIO_BASE]`, as `INFTVoting.VotingSettings` documents and as `createProposal` uses it: `proposal_.minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApproval());`. Two defects:
1. **The script default is `1`**, i.e. `1/1_000_000` = 0.0001%. `_applyRatioCeiled` rounds up, so `minApprovalPower = ceil(N/1e6) = 1` for any supply below one million NFTs. The gate is inert for every realistic deployment — it degenerates to "at least one yes vote", which `isSupportThresholdReached` already implies. Unlike its neighbours (`SUPPORT_THRESHOLD="500000" # 50%`, `MIN_PARTICIPATION="100000" # 10%`), `MIN_APPROVALS` carries no `%` annotation in `.env.example`, so an operator reading `MIN_APPROVALS="1"` naturally parses it as "one approval required" and never learns the second criterion the README advertises is off. The only real gates left are `supportThreshold > 50%` and 10% participation.
2. **`.env.example:42` documents `MIN_APPROVALS="0"`**, which `_updateVotingSettings` explicitly rejects. Uncommenting it gives a reverting install. Fails loudly, so impact is a wasted deployment ceremony rather than a security hole — but it is in the file the README points operators at for "the full list and their defaults". (Independently confirmed by the general pass as GEN-6.)

**Proof of Concept**:
1. Deploy with defaults and 100 NFTs distributed. `minApprovalPower = _applyRatioCeiled(100, 1) = ceil(100/1e6) = 1`; `minVotingPower = _applyRatioCeiled(100, 100_000) = 10`.
2. A coalition holding 10 NFTs votes 6 Yes / 4 No:
   - `isMinParticipationReached`: `6+4+0 = 10 >= 10` ✓
   - `isSupportThresholdReached`: `(1e6 - 5e5)*6 > 5e5*4` → `3e6 > 2e6` ✓
   - `isMinApprovalReached`: `6 >= 1` ✓ (contributes nothing)
   A 10% turnout with 6 of 100 NFTs carries an arbitrary DAO action — exactly what `minApprovals` was meant to prevent.
3. Uncommenting `MIN_APPROVALS="0"` instead makes `just deploy` revert `RatioOutOfBounds(1000000, 0)` inside `initialize`.

**Recommendation**:
```diff
 # Voting settings
 # SUPPORT_THRESHOLD="500000"     # 50%
 # MIN_PARTICIPATION="100000"     # 10%
 # MIN_DURATION="3600"            # 1 hour
 # MIN_PROPOSER_VOTING_POWER="0"  # absolute NFT count, not a ratio; 0 = any address may propose
-# MIN_APPROVALS="0"
+# MIN_APPROVALS="150000"         # 15% — RATIO of total voting power that must vote Yes.
+                                 # NOT an absolute count: "1" means 0.0001%, i.e. effectively disabled.
+                                 # Must be in [1, 1000000]; 0 reverts with RatioOutOfBounds.
```
```solidity
-params.votingSettings.minApprovals = vm.envOr("MIN_APPROVALS", uint256(1));
+// Ratio of total voting power (RATIO_BASE = 1e6) that must vote Yes, on top of `supportThreshold`.
+// Keep this meaningful by default: `1` would mean 0.0001%, which `_applyRatioCeiled` rounds up to a
+// single yes vote and which `isSupportThresholdReached` already implies.
+params.votingSettings.minApprovals = vm.envOr("MIN_APPROVALS", uint256(150_000)); // 15%
```
Also add a README note that `minApprovals`/`minParticipation` are ratios while `minProposerVotingPower` is an absolute NFT count — the mixed units are the root of the confusion.

---

## [GOV-9] `ANY_ADDR` grants for create/execute — confirmed not independently exploitable, but note the consequences
**Severity**: Info
**Category**: governance
**Location**: `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:197`, `:200`

**Description**: Both permissions are granted to `ANY_ADDR = address(type(uint160).max)`. Verified this is a supported Aragon pattern here and not a mis-grant: `PermissionManager._grant` rejects `_where == ANY_ADDR` and rejects `_who == ANY_ADDR` only for `ROOT_PERMISSION_ID` or ids in `isPermissionRestrictedForAnyAddr` (`lib/osx/.../PermissionManager.sol:346-358`) — these are the plugin's own ids with `_where = plugin`, so the grants succeed and `isGranted` short-circuits to `true`. `Votes._vote`'s early-execution branch checks the same permission via `dao().hasPermission(address(this), _voter, EXECUTE_PROPOSAL_PERMISSION_ID, _msgData())`, equivalent to the `auth` modifier on `execute`. Consistent.

Real consequences worth stating in the README rather than treating as findings:
1. **Open proposal creation.** With `minProposerVotingPower = 0`, `canCreateProposal` returns true unconditionally, so any address — including non-members — can create proposals. No deposit, rate limit or cancel. Spam proposals cannot *pass* (a zero tally fails `isSupportThresholdReached`, since `(1e6 - s)*0 > s*0` is `0 > 0`), so this is UI/indexer griefing, not a governance risk in itself. It becomes material only combined with GOV-2, where the creator also chooses the census block. (Independently confirmed by the access-control pass as AC-7, the general pass as GEN-7, and the DoS pass as DOS-7.)
2. **Census selection by non-members.** Because the snapshot is taken at creation and anyone can create, an attacker can front-run a pending `mint` so the new member has zero power on that proposal. Inherent to snapshot-at-creation and shared with every Compound-style governor; the mitigation is social, not structural.
3. **Open execution.** Anyone can execute a succeeded proposal — see GOV-7 for the exploitable part (choice of execution block) and GOV-3 for the unbounded window.

**Proof of Concept**: n/a — documented design tradeoff, verified non-exploitable beyond its intent.

**Recommendation**: Document the tradeoff in `README.md` alongside the install settings, and consider:
```solidity
-params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(0));
+// With CREATE_PROPOSAL_PERMISSION granted to ANY_ADDR, this is the only thing confining proposal
+// creation - and therefore the choice of snapshot block - to actual token holders.
+params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(1));
```

---

## [GOV-10] `TargetConfig` with `Operation.DelegateCall` is a configurable full-compromise footgun; CREATE2 target substitution is not a practical vector
**Severity**: Info
**Category**: governance
**Location**: `Proposal._execute()` — `/home/nnico/public-sector/dao/src/base/Proposal.sol:50-64`; `InstallNFTVotingScript._readMiscSettings()` — `script/InstallNFTVoting.s.sol:236-239`

**Description**: Two checklist items resolve here.

**CREATE2 / metamorphic target substitution — not a finding.** `proposal_.targetConfig = getTargetConfig()` is captured at creation (`Proposal.sol:300`) and `_execute` reads `proposal_.targetConfig`, never live state, so a later `setTargetConfig` cannot redirect an existing proposal. Substituting *code* at a fixed address would need `SELFDESTRUCT` + redeploy, which EIP-6780 (Cancun) reduced to same-transaction creation only — metamorphic contracts are not constructible on any post-Cancun chain. Changing the target at all requires `SET_TARGET_CONFIG_PERMISSION_ID`, granted only to the DAO (`InstallNFTVoting.s.sol:198`). No action needed.

**The `DelegateCall` operation is worth flagging.** `TARGET_OPERATION` is a plain env var (`vm.envOr("TARGET_OPERATION", uint256(0))`) with no validation, and `Plugin._execute` (`lib/osx-commons/.../Plugin.sol:147-167`) executes it as `_target.delegatecall(abi.encodeCall(IExecutor.execute, (_callId, _actions, _allowFailureMap)))`. A `delegatecall` runs the target's code **in the plugin's own storage context** — slots holding `votingSettings`, `votingToken`, `tokenIndexedByTimestamp`, the whole `proposals` mapping and the `PluginCloneable` DAO pointer. A target that is malicious, upgradeable, or merely not delegatecall-safe can overwrite the DAO address, rewrite tallies, or mark arbitrary proposals executed. `TARGET_OPERATION="1"` is presented in `.env.example:47` as a symmetric alternative with no warning. (Independently confirmed as a full-takeover primitive by the access-control pass as AC-3.)

**Proof of Concept**: n/a — requires an operator to set `TARGET_OPERATION=1` with an untrusted/upgradeable `TARGET_ADDRESS`, or the DAO to pass a proposal doing so.

**Recommendation**:
```diff
 # TARGET_ADDRESS=""
-# TARGET_OPERATION="0"           # 0 = Call, 1 = DelegateCall
+# TARGET_OPERATION="0"           # 0 = Call (recommended), 1 = DelegateCall.
+                                 # DelegateCall runs TARGET_ADDRESS's code in the PLUGIN's storage
+                                 # context: a malicious or upgradeable target can overwrite the DAO
+                                 # pointer, the voting settings and every stored proposal. Only use it
+                                 # with an immutable, audited executor you control.
```
Consider having `_deployPlugin` refuse `Operation.DelegateCall` for any target other than a known-good executor, so the dangerous combination cannot be reached by a typo in `.env`.

---

# Checklist items reviewed with no finding

**Flash-loan voting / flash-loan proposal creation** — Not applicable. Every voting-power read goes through a fixed past checkpoint: `Votes._vote:36` and `Votes._canVote:111` use `getPastVotes(_, proposal_.parameters.snapshotTimepoint)`; `Settings.totalVotingPower:70` uses `getPastTotalSupply(_timePoint)`; `Proposal.canCreateProposal:192` uses `getPastVotes(_account, block.number/timestamp - 1)`. No current-balance read anywhere in the voting or proposal-creation path (`isMember` uses `getVotes`/`balanceOf` but is an `IMembership` view with no authorization role). Standard Compound-style protection.

**Vote with the same tokens twice via transfer — confirmed prevented, not a vulnerability.** `snapshotTimepoint` is written once at `createProposal:293` and never mutated; both `_canVote` and `_vote` read `getPastVotes(_account, snapshotTimepoint)` against it, and OZ checkpoints for a past timepoint are immutable. Concretely: Alice holds token #1, self-delegated, power 1 at snapshot `S`. She votes, then transfers #1 to fresh address Bob at `t > S`. `GovernanceERC721._afterTokenTransfer` sees `delegates(Bob) == address(0)` and self-delegates Bob — but that writes a checkpoint at `t`, not at `S`, so `getPastVotes(Bob, S) == 0` and `_canVote` rejects him. Alice retains her vote (she can vote with tokens she no longer owns, which is correct snapshot semantics). Total votes cast stays ≤ `getPastTotalSupply(S)`. **The self-delegation hook does not open a double-vote path.** Same holds for the `VoteReplacement` decrement at `_vote:41-45`: the subtracted value is read from the identical fixed checkpoint as the added value, so it always matches exactly and cannot underflow — the sole exception being the token swap in GOV-4.

**Sybil via re-delegation after proposal creation** — Prevented by the same mechanism. Delegating to a second controlled address after `snapshotTimepoint` moves only current/future checkpoints; the new address still reads 0 at the snapshot. No lockup needed.

**Zero / tiny total supply** — `createProposal:276-278` reverts `NoVotingPower` when `totalVotingPower(snapshot) == 0`, closing the "pass proposals before tokens are minted" class. Tiny supply is also closed: `minParticipation >= 1` and `minApprovals >= 1` are enforced by `_updateVotingSettings`, and `_applyRatioCeiled` rounds up, so `minVotingPower >= 1` and `minApprovalPower >= 1` for any supply `>= 1` — neither can be 0. Independently, a zero tally always fails `isSupportThresholdReached` (`0 > 0` is false), so nothing passes without a real yes vote.

**Snapshot timing / backrunning at the boundary** — Correct. `block.number - 1` is fully mined, and `block.timestamp - 1` satisfies OZ's `require(timepoint < clock())` for a timestamp-clocked token while excluding anything in the creating block. A backrunner cannot alter the census, since their tx lands at or after the creating block. A *front*-runner can (mint, burn or re-delegate in an earlier block), but minting/burning need DAO permissions and re-delegation is the holder's own prerogative — inherent to snapshot governance, not a defect. `canCreateProposal` and `createProposal` recompute the same timepoint in the same block, so they cannot disagree.

**Clock detection** — `Settings._detectTokenClock` is sound for the tokens in scope. `GovernanceERC721` does not override `clock()`, so it inherits `VotesUpgradeable.clock() => block.number` and is correctly detected as block-indexed. A false positive requires `block.number == block.timestamp`, unreachable on a live chain. The one gap — the flag is global while `snapshotTimepoint` is per proposal — is covered by GOV-4.

**Quorum manipulable by minting/burning after creation** — Not exploitable. `minVotingPower`/`minApprovalPower` are frozen at creation from `getPastTotalSupply(snapshot)`. Minting afterwards gives new tokens zero snapshot power (cannot help reach quorum); burning afterwards does not reduce the frozen denominator and does not remove the former holder's snapshot power (cannot block quorum). Both directions correctly neutralised. The related *denominator composition* issue is GOV-5.

**Abstain padding** — `isMinParticipationReached` counts `yes + no + abstain` toward participation while `isSupportThresholdReached` uses only `yes` vs `no`, so abstain can help reach quorum without affecting support — but `isMinApprovalReached` independently requires `yes >= minApprovalPower`, so abstain padding cannot carry a proposal alone. Matches the README spec exactly. It is only *weak* because of the `minApprovals` default — see GOV-8.

**Dynamic quorum computed at execution time** — Not applicable: `minVotingPower` and `minApprovalPower` are stored at creation and only read afterwards.

**Proposal deadlines in blocks vs L2 block-time variance** — Not applicable: `startDate`/`endDate` and `_isProposalOpen` are all `block.timestamp`-based, independent of the token's clock mode. Only the snapshot uses block numbers when the token is block-indexed, which is the correct pairing.

**`allowFailureMap` / action tampering / partial execution** — `proposal_.actions` is populated only in the `createProposal` loop and `allowFailureMap` only alongside it; nothing in the plugin mutates either afterwards. Execution order is stored array order. `allowFailureMap == 0` means fully atomic, as documented. A non-zero map permitting partial execution is a per-proposal choice visible in the `ProposalCreated` event. No reordering or post-creation tampering possible. (The permissionless-executor consequence of `allowFailureMap` is DOS-2, filed by the DoS pass.)

**Re-proposal / proposal-ID griefing** — Not exploitable. `_createProposalId(salt) = keccak256(chainid, block.number, address(this), salt)` with `salt = keccak256(_msgSender(), _actions, _metadata)`. Including `_msgSender()` (commit `5298852`) stops a third party from front-running to occupy an id, and including `block.number` lets an honest proposer re-submit identical actions+metadata in any later block. `ProposalAlreadyExists` only fires on a genuine same-block duplicate. Correct as-is.

**Cross-chain execution inconsistency** — Not applicable: single-chain plugin, and `chainid` is already mixed into the proposal id.

**Timelock bypass / short delay / circular timelock admin** — No timelock exists in this design. The absence of an execution delay is GOV-7; there is no bypass to find.

**Reentrancy on execution** — `_execute` sets `proposal_.executed = true` before dispatching, and `_canExecute` checks `executed` first, so the early-execution path in `Votes._vote:65-70` cannot re-enter into a double execution. Tally writes complete before the `_execute` call. Correct.

**Multi-sig / permission-holder diversity** — Every administrative permission (`UPDATE_VOTING_SETTINGS`, `SET_TARGET_CONFIG`, `SET_METADATA`, and the token's `MINT`/`BURN`/`TRANSFER`/`UPDATE_BASE_URI`) is granted to the DAO itself, i.e. gated behind a passing proposal. That is the right structure. Its failure modes are the irreversibility in GOV-6 and the stray deployer key in GOV-1.

**Reward distribution** — Not applicable; no reward token in this repo.

**Already-fixed items not re-reported** (verified present): `hasSucceeded`-before-`endDate` logic (`a25bbdc`), `_msgSender()` in `createProposalId` (`5298852`), 365-day `minDuration` bound (`5c21a0d`), token initializer disabled after constructor (`761159f`), clock detection (`fa8a27d`).

---

**Single most important takeaway**: GOV-1 is a live Critical in the deployment script — a default `just deploy` leaves the deployer EOA with permanent `EXECUTE_PERMISSION` on the DAO (granted by `DAOFactory` because the script passes an empty `PluginSettings[]`, never revoked), which makes the entire NFT governance mechanism bypassable by that key. The README ceremony explicitly treats that key as a discardable burner. GOV-2 (unbounded future `_startDate` freezing a stale census, with no cancel function) is the most significant issue in the contracts themselves. GOV-4 (the token-swap corruption) is the most cross-confirmed finding across the whole audit, independently found by four separate agents.
