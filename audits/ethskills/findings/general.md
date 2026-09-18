# General Solidity/EVM findings — NFTVoting

9 findings: 1 High, 1 Medium, 4 Low, 3 Info. The two that matter most:

- **GEN-1 (High)** — `script/InstallNFTVoting.s.sol` never revokes the `EXECUTE_PERMISSION_ID` that `DAOFactory` grants to the deployer EOA for the no-plugin create path. Post-deployment the burner key retains unilateral control of the DAO treasury forever, and the README ceremony treats that key as disposable. (Independently confirmed by the access-control pass as AC-1 — same root cause.)
- **GEN-2 (Medium)** — `Settings.updateVotingToken` swaps the token without pinning it per proposal. Confirmed by passing PoC: tally corruption in VoteReplacement, permanent underflow-revert of `canExecute`/`hasSucceeded`/`execute` in EarlyExecution, and total voting lockout. (Independently confirmed by the precision-math pass as MATH-2 and the ERC-721 pass as NFT-1 — same root cause, three angles.)

---

## [GEN-1] Deploy script leaves the deployer EOA with permanent, unilateral `EXECUTE_PERMISSION` over the new DAO
**Severity**: High
**Category**: general
**Location**: `script/InstallNFTVoting.s.sol:110-131` (`createDaoAndInstall` / `installOnExistingDao`), `_buildPermissionActions` at `script/InstallNFTVoting.s.sol:188-209`
**Description**:
`createDaoAndInstall` calls `_daoFactory.createDao(_daoSettings, new DAOFactory.PluginSettings[](0))` with an **empty** plugin-settings array. Aragon's `DAOFactory` takes the no-plugin branch (`lib/osx/packages/contracts/src/framework/dao/DAOFactory.sol:182-185`):

```solidity
} else {
    // if no plugin setting is provided, grant EXECUTE_PERMISSION_ID to msg.sender
    createdDao.grant(daoAddress, msg.sender, EXECUTE_PERMISSION_ID);
}
```

Under `forge script --broadcast`, `msg.sender` at the `DAOFactory` is the deployer EOA (`DEPLOYER_KEY`). The script relies on that grant to run `_dao.execute(bytes32(0), actions, 0)` at `InstallNFTVoting.s.sol:130` — but `_buildPermissionActions` only ever *grants*; it builds 6 (or 10) `grant` actions and **never revokes the deployer's `EXECUTE_PERMISSION_ID`**. Nothing else in the script, the justfile, or the README post-deployment checklist (`README.md:255-266`) revokes it either.

Result: after a "successful" governance install, the deployer key can call `dao.execute(...)` directly with arbitrary actions — move the treasury, re-grant `ROOT`, uninstall the plugin — completely bypassing the NFTVoting plugin. The README's own deployment ceremony instructs the operator to generate a throwaway burner key (`README.md:227`) and then only "transfer the remaining funds of the deployment wallet" (`README.md:265`), so the backdoor key is treated as disposable while it in fact retains full control.

Compounding it: when `TOKEN_ADDRESS` is unset, `_resolveToken` (`InstallNFTVoting.s.sol:141-147`) mints **all** `NFT_COUNT` NFTs to that same deployer address, so the deployer also holds 100% of voting power at the end of the run. There is no second, independent path to DAO control.

**Proof of Concept**:
1. Operator follows `README.md` ceremony: `just switch <net>`, `just deploy` with `EXISTING_DAO_ADDRESS` unset.
2. `DAOFactory.createDao(settings, [])` → DAO created, `EXECUTE_PERMISSION_ID` granted to deployer EOA (DAOFactory.sol:184).
3. Script executes the 10 grant actions and prints "NFTVoting plugin installed".
4. Operator runs `just refund`, discards the burner key, announces the DAO as governed by NFT holders.
5. Anyone who ever obtains that private key (or the operator themselves) calls:
   ```
   cast send $DAO "execute(bytes32,(address,uint256,bytes)[],uint256)" \
     0x0 "[($TREASURY_TOKEN,0,$TRANSFER_CALLDATA)]" 0 --private-key $DEPLOYER_KEY
   ```
   and drains the DAO with no proposal, no vote, no delay.

**Recommendation**:
Revoke the bootstrap permission as the last action of the same `dao.execute` batch, and add an explicit assertion so the script fails loudly if it is still set:

```solidity
function _buildPermissionActions(DAO _dao, NFTVoting _plugin, IVotesUpgradeable _token, bool _mintedNewToken)
    internal view returns (Action[] memory actions)
{
    uint256 n = (_mintedNewToken ? 10 : 6) + 1;
    actions = new Action[](n);
    // ... existing grants 0..9 ...

    // Drop the bootstrap authority used to run this very batch.
    actions[n - 1] = Action({
        to: address(_dao),
        value: 0,
        data: abi.encodeCall(PermissionManager.revoke, (address(_dao), deployer, _dao.EXECUTE_PERMISSION_ID()))
    });
}
```

and in `installOnExistingDao`, after `_dao.execute(...)`:

```solidity
require(
    !_dao.isGranted(address(_dao), deployer, _dao.EXECUTE_PERMISSION_ID(), ""),
    "deployer still has EXECUTE on the DAO"
);
```

Also add a post-deployment checklist line: verify `dao.isGranted(dao, <deployer>, EXECUTE_PERMISSION_ID, "") == false`, and document that `NFT_COUNT` NFTs all land on the deployer and must be redistributed (or use `TOKEN_ADDRESS` with a pre-distributed token).

---

## [GEN-2] `updateVotingToken` silently corrupts or permanently bricks every in-flight proposal
**Severity**: Medium
**Category**: general
**Location**: `Settings.updateVotingToken()` / `Settings._updateVotingToken()` — `src/base/Settings.sol:158-180`; consumers at `src/base/Votes.sol:36,111` and `src/base/Proposal.sol:154-155`
**Description**:
`votingToken` is mutable via `updateVotingToken` (a fork-specific addition; it does not exist in upstream Aragon `TokenVoting`). Every proposal, however, snapshots only a `snapshotTimepoint` (`INFTVoting.ProposalParameters.snapshotTimepoint`) — never the token it belongs to. Three separate reads resolve the token **at call time**, not at proposal-creation time:

- `Votes._vote()` — `src/base/Votes.sol:36`: `votingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint)`
- `Votes._canVote()` — `src/base/Votes.sol:111`: same
- `Proposal.isSupportThresholdReachedEarly()` — `src/base/Proposal.sol:154-155`: `totalVotingPower(proposal_.parameters.snapshotTimepoint) - tally.yes - tally.abstain`

Once the token is swapped, the old timepoint has no meaning on the new token, producing three distinct failures (all confirmed with a PoC):

1. **Tally corruption (VoteReplacement).** `_vote` subtracts the voter's *new-token* power from a tally that was built from *old-token* power. A voter who cast 3 yes and now has 1 unit on the replacement token flips to `No`: `yes` drops by only 1, leaving 2 phantom yes votes that no longer correspond to any voter. PoC `test_tokenSwapCorruptsTally` → `yes = 2, no = 1` from a single voter.
2. **Permanent DoS of `canExecute`/`execute` (EarlyExecution).** If the replacement token was deployed after the snapshot, `totalVotingPower(snapshotTimepoint)` returns 0 while `tally.yes` is non-zero, so `src/base/Proposal.sol:154-155` underflows and **reverts**. `canExecute`, `hasSucceeded`, `execute` and even the `_tryEarlyExecution` branch of `vote()` all revert forever for that proposal — it can never be executed and never expires. PoC `test_tokenSwapUnderflowsEarlyExecutionMath`.
3. **Total voting lockout.** With a later-deployed token, `getPastVotes(voter, oldSnapshot) == 0` for everyone, so `_canVote` returns false and every `vote()` reverts `VoteCastForbidden`. PoC `test_tokenSwapBlocksAllVoting`.

A clock-mode change makes it worse: `_detectTokenClock` flips `tokenIndexedByTimestamp`, but already-created proposals still hold a block-number `snapshotTimepoint` that is now interpreted as a timestamp (or vice-versa) by the new token's checkpoint lookup.

Note this also means a routine, well-intentioned token migration — the only reason `updateVotingToken` exists — destroys the integrity of anything mid-flight, and `UPDATE_VOTING_SETTINGS_PERMISSION_ID` gates both the innocuous settings update and this token swap with the same permission ID.

**Proof of Concept**: abbreviated flow for case 2:
1. DAO with EarlyExecution mode, 3 holders × 3 NFTs.
2. Alice creates proposal `P`; Alice and Bob vote Yes (`tally.yes = 6`).
3. DAO passes a proposal calling `updateVotingToken(newToken)` (a freshly deployed `GovernanceERC721`).
4. `plugin.canExecute(P)` now reverts with an arithmetic underflow (`0 - 6`) and does so for every future block. `P` is unexecutable and undeletable.

**Recommendation**: Pin the token per proposal, so a swap only affects proposals created afterwards.

```solidity
// INFTVoting.ProposalParameters
struct ProposalParameters {
    VotingMode votingMode;
    uint32 supportThreshold;
    uint64 startDate;
    uint64 endDate;
    uint64 snapshotTimepoint;
    uint256 minVotingPower;
    IVotesUpgradeable votingToken; // NEW: the token this proposal was snapshotted against
}
```
Set it in `createProposal` (`proposal_.parameters.votingToken = votingToken;`) and read `proposal_.parameters.votingToken` in `_vote`, `_canVote` and `isSupportThresholdReachedEarly` instead of the storage variable.

If pinning is too invasive, at minimum make the swap safe:
```solidity
function _updateVotingToken(IVotesUpgradeable _token) internal virtual {
    // ... existing ERC165 checks ...
    votingToken = _token;
    _detectTokenClock();
    // Invalidate proposals created against the previous token.
    tokenEpoch += 1; // stored on each proposal; reject vote()/execute() on stale epochs
    emit VotingTokenUpdated(address(_token));
}
```
Independently, guard the subtraction in `isSupportThresholdReachedEarly` so a bad state degrades to `false` rather than an unconditional revert:
```solidity
uint256 total = totalVotingPower(proposal_.parameters.snapshotTimepoint);
uint256 counted = proposal_.tally.yes + proposal_.tally.abstain;
if (counted > total) return false;
uint256 noVotesWorstCase = total - counted;
```

---

## [GEN-3] `_detectTokenClock` misclassifies any clock that is neither exactly `block.number` nor exactly `block.timestamp`
**Severity**: Low
**Category**: general
**Location**: `Settings._detectTokenClock()` — `src/base/Settings.sol:184-191`
**Description**:
```solidity
try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timePoint) {
    tokenIndexedByTimestamp = (timePoint == block.timestamp);
} catch {
    tokenIndexedByTimestamp = false;
}
```
The detection is a single equality test against `block.timestamp`, so *anything* that is not a raw-timestamp clock is classified as block-number-indexed. ERC-6372 explicitly allows arbitrary monotonic clocks (`CLOCK_MODE` is a free-form string); epoch/period-based clocks (`block.timestamp / 1 days`), L2 clocks reporting L1 block numbers, or clocks with an offset all fall through to `tokenIndexedByTimestamp = false`.

`TOKEN_ADDRESS` in `.env.example:30` lets the operator install the plugin against *any* `IVotes` ERC-721, and `updateVotingToken` lets the DAO swap to one later, so this is reachable without a code change. With a misclassification, `createProposal` records `snapshotTimepoint = block.number - 1` (~10^7) and every subsequent `getPastVotes`/`getPastTotalSupply` on an epoch-clock token (`clock()` ≈ 2×10^4) sees a **future** timepoint and reverts with OZ's `"Votes: future lookup"` — `createProposal` reverts outright at `Proposal.sol:274`, so the plugin is unusable and the failure mode is only discovered post-install.

The correct, non-heuristic check is `CLOCK_MODE()`, which exists precisely for this (`IERC6372`). It is also worth noting the detection is sampled once and cached; if the token is an upgradeable proxy whose clock mode changes, `tokenIndexedByTimestamp` goes stale silently (recoverable only by re-calling `updateVotingToken` with the same address).

**Proof of Concept**:
1. Deploy an ERC-721 `Votes` token overriding `clock()` to `uint48(block.timestamp / 1 days)` and `CLOCK_MODE()` to `"mode=timestamp&from=epoch-days"` (a legal ERC-6372 clock).
2. Install with `TOKEN_ADDRESS=<that token>`. `_detectTokenClock` sees `clock() = 20_400 != block.timestamp` → `tokenIndexedByTimestamp = false`.
3. Any `createProposal` call computes `snapshotTimepoint = block.number - 1` and calls `getPastTotalSupply(block.number - 1)`, which reverts `"Votes: future lookup"`.
4. The plugin can never create a proposal; the only fix is `updateVotingToken`, which requires an already-installed working governance path — a chicken-and-egg lock unless someone still holds `ROOT`/`EXECUTE` on the DAO.

**Recommendation**: Parse `CLOCK_MODE()` and reject anything not understood, instead of guessing:

```solidity
function _detectTokenClock() private {
    try IERC6372Upgradeable(address(votingToken)).CLOCK_MODE() returns (string memory mode) {
        bytes32 h = keccak256(bytes(mode));
        if (h == keccak256("mode=timestamp")) {
            tokenIndexedByTimestamp = true;
        } else if (h == keccak256("mode=blocknumber&from=default")) {
            tokenIndexedByTimestamp = false;
        } else {
            revert UnsupportedClockMode(mode); // fail closed on custom clocks
        }
    } catch {
        // No ERC-6372: the ERC-6372 default is block numbers.
        tokenIndexedByTimestamp = false;
    }
}
```
Add a sanity probe after setting it (`totalVotingPower(currentTimepoint - 1)` must not revert) so a bad token is rejected at `initialize` time rather than at first `createProposal`.

---

## [GEN-4] `startDate` has no upper bound, so a proposal's census can be arbitrarily stale when voting opens
**Severity**: Low
**Category**: general
**Location**: `Proposal._validateProposalDates()` — `src/base/Proposal.sol:366-404`; snapshot taken at `src/base/Proposal.sol:263-293`
**Description**:
`_validateProposalDates` bounds the *duration* (`endDate` must be within `[startDate + minDuration, startDate + 365 days]`) but places **no ceiling on `startDate` itself** — the only check is `startDate >= block.timestamp` (`Proposal.sol:379-381`). Meanwhile `snapshotTimepoint` is fixed at creation time (`Proposal.sol:263-272`), as are `minVotingPower` and `minApprovalPower` (`Proposal.sol:296-298`).

So `createProposal(metadata, actions, 0, uint64(block.timestamp + 3650 days), 0)` is accepted, and ten years later the proposal opens and is decided by a **ten-year-old** delegation snapshot: holders who have since sold every NFT still vote with their old power, current holders have none, and the thresholds are measured against the old total supply. The recently added 365-day cap is relative to `startDate`, not to `block.timestamp`, so total proposal lifetime (creation → last executable moment) is unbounded even though duration is capped. Executability itself never expires either (`_canExecute` has no upper time bound), so such a proposal sits as a permanently armed, pre-funded action.

Given `CREATE_PROPOSAL_PERMISSION_ID` is granted to `ANY_ADDR` in the shipped install script (`InstallNFTVoting.s.sol:197`), any address can plant these. Impact is limited because thresholds are also frozen at the old supply (so an attacker needs the same voting power they would need today) and because the proposal is publicly visible for its whole life — hence Low rather than higher. (Independently confirmed by the precision-math pass as MATH-1.)

**Proof of Concept**:
1. Alice holds 60% of the NFTs today. She calls `createProposal(meta, [transfer treasury to Alice], 0, uint64(block.timestamp + 730 days), 0)`. `_validateProposalDates` accepts: `startDate >= now`, `endDate = startDate + minDuration <= startDate + 365 days`.
2. Alice sells all her NFTs the next day. The DAO's active membership turns over completely.
3. Two years later the proposal opens. `getPastVotes(alice, snapshotTimepoint)` still returns her old 60%; she votes Yes, participation/approval are measured against the two-year-old supply, and she executes. No current member could have voted at all.

**Recommendation**: Bound the start date against "now", not only the duration against the start:

```solidity
uint64 internal constant MAX_START_DELAY = 30 days;

if (_start == 0) {
    startDate = currentTimestamp;
} else {
    startDate = _start;
    if (startDate < currentTimestamp) {
        revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
    }
    uint64 latestStartDate = currentTimestamp + MAX_START_DELAY;
    if (startDate > latestStartDate) {
        revert DateOutOfBounds({limit: latestStartDate, actual: startDate});
    }
}
```
Consider also adding an execution expiry (e.g. `endDate + gracePeriod`) so an old successful proposal cannot be executed indefinitely.

---

## [GEN-5] Auto self-delegation silently reverses a holder's explicit `delegate(address(0))` opt-out
**Severity**: Low
**Category**: general
**Location**: `GovernanceERC721._afterTokenTransfer()` — `src/erc721/GovernanceERC721.sol:159-170`
**Description**:
```solidity
if (to != address(0) && delegates(to) == address(0)) {
    _delegate(to, to);
}
```
The hook cannot distinguish "never delegated" from "deliberately delegated to `address(0)` to withdraw from governance" — OZ `Votes` represents both as `delegates(account) == address(0)`. Any subsequent token receipt (mint, holder transfer, or a DAO `adminTransfer`) re-activates the account's **entire balance**, not just the incoming token.

This is a `if (receiver == caller)`-style unexpected-behavior footgun and contradicts the contract's own NatSpec at `GovernanceERC721.sol:34-35`, which states "Holders can override this at any time by calling `delegate`" — they can override it to a *third party*, but an opt-out override does not stick. Since `TRANSFER_PERMISSION_ID` lets the DAO force-transfer (`adminTransfer`, `GovernanceERC721.sol:141-144`), a holder who has opted out can have their voting power forcibly re-enabled by anyone holding that permission, by pushing them a single dust NFT — their full balance counts again and, thanks to per-proposal snapshots, they cannot retroactively opt out of proposals created in that window. (Independently confirmed by the ERC-721 pass as NFT-2.)

**Proof of Concept**: `test_selfDelegationOverridesOptOut` (passes):
1. Carol holds 3 NFTs, self-delegated, `getVotes(carol) == 3`.
2. Carol calls `nft.delegate(address(0))` → `getVotes(carol) == 0`. She has withdrawn from governance.
3. Alice (or the DAO via `adminTransfer`) transfers **one** NFT to Carol.
4. `_afterTokenTransfer` fires: `delegates(carol) == address(0)` → `_delegate(carol, carol)`.
5. `delegates(carol) == carol` and `getVotes(carol) == 4`. Her whole balance is voting again without her consent.

**Recommendation**: Track first-touch explicitly so an opt-out is durable:

```solidity
mapping(address account => bool) private hasEverDelegated;

function delegate(address delegatee) public virtual override {
    hasEverDelegated[_msgSender()] = true;
    super.delegate(delegatee);
}

function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
    internal virtual override(ERC721VotesUpgradeable)
{
    super._afterTokenTransfer(from, to, firstTokenId, batchSize);
    if (to != address(0) && delegates(to) == address(0) && !hasEverDelegated[to]) {
        hasEverDelegated[to] = true;
        _delegate(to, to);
    }
}
```
(`delegateBySig` needs the same flag set.) At minimum, correct the NatSpec at `GovernanceERC721.sol:34-35` to state that delegating to `address(0)` is not a durable opt-out.

---

## [GEN-6] `.env.example` ships a `MIN_APPROVALS` value that reverts the install, and the ratio unit is undocumented
**Severity**: Low
**Category**: general
**Location**: `.env.example:42` vs `Settings._updateVotingSettings()` — `src/base/Settings.sol:139-141`; default at `script/InstallNFTVoting.s.sol:249`
**Description**:
Two distinct defects in the same parameter.

1. **The documented value is invalid.** `.env.example:42` reads `# MIN_APPROVALS="0"`, but `_updateVotingSettings` rejects zero:
   ```solidity
   if (_votingSettings.minApprovals == 0 || _votingSettings.minApprovals > RATIO_BASE) {
       revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minApprovals});
   }
   ```
   An operator who uncomments that line (the natural reading of a commented-out example is "this is the default") gets a revert inside `NFTVoting.initialize`, i.e. inside the broadcast, after the DAO and token have already been deployed and paid for. The script's own default (`InstallNFTVoting.s.sol:249`) is `1`, so the example file and the code disagree.

2. **Undocumented unit.** `minApprovals` is a **ppm ratio** consumed by `_applyRatioCeiled(totalVotingPower_, minApproval())` at `Proposal.sol:298`, exactly like `SUPPORT_THRESHOLD` and `MIN_PARTICIPATION`. But `.env.example` annotates those two with their percentage (`# 50%`, `# 10%`) and leaves `MIN_APPROVALS` bare, while `INFTVoting.sol:50-51` names the field `minApprovals` (plural, sounds like a count) and the derived storage field is `minApprovalPower` (an absolute vote count). `InstallNFTVoting.s.sol:249` then defaults it to `1`, which reads like "1 approval" and only happens to behave that way because `_applyRatioCeiled` rounds `1/10^6` up to 1 vote. An operator who sets `MIN_APPROVALS=50` intending "50 NFTs" or "50%" silently gets 0.005% — effectively 1 vote — and the DAO ships with no approval floor at all.

**Proof of Concept**:
1. Operator copies `.env.example` to `.env` and uncomments the `MIN_APPROVALS="0"` line as instructed by the surrounding comment block.
2. `just deploy` → `DAOFactory.createDao` succeeds (DAO deployed, gas spent), `new GovernanceERC721(...)` succeeds (token deployed, NFTs minted), then `nftVotingBase.deployMinimalProxy(abi.encodeCall(NFTVoting.initialize, ...))` reverts `RatioOutOfBounds(1000000, 0)`.
3. The broadcast aborts mid-way: an orphaned DAO and token exist on chain with the deployer as sole authority and no plugin. Re-running creates a second DAO.
4. Separately: operator sets `MIN_APPROVALS="50"` meaning 50%. Deploy succeeds. `minApprovalPower = _applyRatioCeiled(totalVotingPower, 50) = 1`. A single yes vote satisfies the approval criterion for the DAO's entire lifetime.

**Recommendation**:
```diff
-# MIN_APPROVALS="0"
+# MIN_APPROVALS="150000"        # 15% — ppm ratio in [1, 1000000], 0 is rejected
```
and annotate the surrounding block, e.g. `# SUPPORT_THRESHOLD / MIN_PARTICIPATION / MIN_APPROVALS are parts-per-million ratios (1000000 = 100%)`. Rename `minApprovals` → `minApprovalRatio` in `INFTVoting.VotingSettings` and `minApproval()` → `minApprovalRatio()` in `Settings` to match `minApprovalPower`. Add a precheck in `_readVotingSettings` so a bad ratio fails before any contract is deployed:
```solidity
require(params.votingSettings.minApprovals >= 1 && params.votingSettings.minApprovals <= 1_000_000, "MIN_APPROVALS must be a ppm ratio in [1, 1000000]");
```

---

## [GEN-7] `CREATE_PROPOSAL_PERMISSION` is granted to `ANY_ADDR` while `MIN_PROPOSER_VOTING_POWER` defaults to 0, contradicting the stated gate
**Severity**: Info
**Category**: general
**Location**: `script/InstallNFTVoting.s.sol:197`, `.env.example:41`, `Proposal.canCreateProposal()` — `src/base/Proposal.sol:175-193`, comment at `test/lib/NFTDAOBuilder.sol:172`
**Description**:
The install script grants proposal creation to every address:
```solidity
actions[2] = _grantAction(_dao, address(_plugin), ANY_ADDR, _plugin.CREATE_PROPOSAL_PERMISSION_ID());
```
The justification stated in the test builder (`NFTDAOBuilder.sol:172`) is *"Allow anyone to create proposals; `NFTVoting.createProposal` gates on voting power itself."* That gate does not exist under the shipped defaults — `canCreateProposal` short-circuits:
```solidity
uint256 minProposerVotingPower_ = minProposerVotingPower();
if (minProposerVotingPower_ == 0) {
    return true;
}
```
and `.env.example:41` documents `MIN_PROPOSER_VOTING_POWER="0"` as the default (matching `InstallNFTVoting.s.sol:248`). So a caller with zero NFTs, zero delegated power, and no relationship to the DAO passes both the permission check and the voting-power check. The only remaining barrier is `totalVotingPower_ == 0` (`Proposal.sol:276`), a property of the DAO, not of the caller.

Impact is bounded — the spammer pays gas, proposal IDs include `_msgSender()` (`Proposal.sol:282`) so they cannot squat on another proposer's ID, and no proposal passes without real votes. But there is no cancel/veto function anywhere in the plugin, so junk proposals accumulate permanently in the DAO's proposal list and in every indexer/UI reading `ProposalCreated`. (Independently confirmed by the access-control pass as AC-7 and the DoS pass.)

**Proof of Concept**:
1. Install with the shipped defaults (`MIN_PROPOSER_VOTING_POWER` unset → 0).
2. Attacker with zero NFTs calls `plugin.createProposal("spam", [], 0, 0, 0)` in a loop. `auth(CREATE_PROPOSAL_PERMISSION_ID)` passes via the `ANY_ADDR` grant; `canCreateProposal(attacker)` returns `true` at the `minProposerVotingPower_ == 0` short-circuit; `totalVotingPower_` is non-zero because real members exist.
3. Each call varies `_metadata` so `_createProposalId` differs and `ProposalAlreadyExists` never triggers. The DAO's proposal list is permanently polluted; there is no way to remove the entries.

**Recommendation**: Either set a non-zero default so the documented gate is real, or drop the claim. Preferred:
```diff
-# MIN_PROPOSER_VOTING_POWER="0"
+# MIN_PROPOSER_VOTING_POWER="1"   # require >= 1 delegated NFT to open a proposal
```
```diff
-        params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(0));
+        params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(1));
```
and update the `NFTDAOBuilder.sol:172` comment to say the gate is only effective when `minProposerVotingPower > 0`.

---

## [GEN-8] Unit tests deploy the plugin behind an ERC-1967/UUPS proxy, while production uses an EIP-1167 minimal proxy
**Severity**: Info
**Category**: general
**Location**: `test/lib/NFTDAOBuilder.sol:161-168` vs `script/InstallNFTVoting.s.sol:170-184`
**Description**:
`NFTVoting` extends `PluginCloneable` and is deployed in production with `nftVotingBase.deployMinimalProxy(...)` (`InstallNFTVoting.s.sol:172`). The unit-test builder instead uses `ProxyLib.deployUUPSProxy(address(NFT_VOTING_PLUGIN_BASE), ...)`, which deploys an `ERC1967Proxy`. `NFTVoting` implements neither `proxiableUUID` nor `upgradeTo`, so the resulting proxy is inert and the logic under test behaves identically — but the entire unit suite (`Proposal.t.sol`, `Settings.t.sol`, `Votes.t.sol`) therefore never exercises the proxy type that will actually be deployed. Only `test/fork/InstallNFTVoting.t.sol` covers the real clone path, and only when an RPC is reachable (`just test-fork`), so `just test` alone gives no coverage of the shipped deployment shape (including PROXY-1, the atomicity gap in that exact deployment path).

No security impact today — noting it because a future change (adding an immutable, a constructor-set value, or `ERC1967` storage-slot interaction) would diverge between the two paths and pass CI silently.

**Proof of Concept**: N/A — consistency issue, not exploitable. Observable at `NFTDAOBuilder.sol:162` (`deployUUPSProxy`) against `InstallNFTVoting.s.sol:172` (`deployMinimalProxy`).

**Recommendation**: Align the builder with production:
```diff
-        plugin = NFTVoting(
-            ProxyLib.deployUUPSProxy(
-                address(NFT_VOTING_PLUGIN_BASE),
+        plugin = NFTVoting(
+            ProxyLib.deployMinimalProxy(
+                address(NFT_VOTING_PLUGIN_BASE),
                 abi.encodeCall(
                     NFTVoting.initialize, (dao, votingSettings, token_, targetConfig, pluginMetadata)
                 )
             )
         );
```

---

## [GEN-9] `abstract contract Proposal` shadows the inherited `INFTVoting.Proposal` struct name
**Severity**: Info
**Category**: general
**Location**: `src/base/Proposal.sol:18` (contract) vs `src/base/INFTVoting.sol:74` (struct), used at `Proposal.sol:29,51,82,112,145,152,162,218`
**Description**:
`abstract contract Proposal is Settings` inherits `INFTVoting`, which declares `struct Proposal`. Inside the contract body, the identifier `Proposal` resolves to the inherited struct rather than to the contract itself — `mapping(uint256 => Proposal) internal proposals;` (`Proposal.sol:29`) and `Proposal storage proposal_ = ...` (eight sites) all mean `INFTVoting.Proposal`. It compiles and behaves correctly, but the contract's own name is unreachable from within its body and a reader has to resolve the ambiguity manually at every use site. `Votes.sol` imports `{Proposal} from "./Proposal.sol"` (the contract) and then writes `Proposal storage proposal_` at `Votes.sol:33` — the same token meaning the struct, two lines below an import that binds it to the contract.

No security impact — flagged purely as a maintenance hazard, since a future refactor that moves the struct or adds a same-named declaration would change resolution silently.

**Proof of Concept**: N/A — naming/readability issue.

**Recommendation**: Rename the abstract contract to `ProposalBase` (matching the `Settings` / `Votes` sibling naming), or rename the struct to `ProposalData`:
```diff
-abstract contract Proposal is Settings {
+abstract contract ProposalBase is Settings {
```
```diff
-import {Proposal} from "./Proposal.sol";
-abstract contract Votes is Proposal, IMembership {
+import {ProposalBase} from "./Proposal.sol";
+abstract contract Votes is ProposalBase, IMembership {
```

---

# Checklist items reviewed and found not applicable

| Item | Why N/A |
| --- | --- |
| Call to non-existent address returns `true` | No `.call`/`.staticcall` anywhere in `src/` or `script/`. All external calls are typed high-level calls, which carry an implicit `extcodesize` check. |
| Returndata bombing | No low-level calls; no unbounded returndata copy under the plugin's control. |
| Fixed gas in `.call{gas: X}` | No explicit gas stipends. |
| `msg.value` in multicall/batch | The plugin has no payable function and never reads `msg.value`. Batch execution is delegated to the DAO's `execute`. |
| `msg.value` via delegatecall | Same — no `msg.value` read. `TARGET_OPERATION=1` (DelegateCall) forwards to `PluginCloneable._execute`, which already blocks `target == IDAO && DelegateCall`. |
| try/catch forced OOG | One `try/catch`: `_detectTokenClock` (`Settings.sol:185`). Failing into `catch` yields `tokenIndexedByTimestamp = false`, the safe ERC-6372 default — see GEN-3 for the misclassification angle, which is not gas-driven. |
| `abi.encodePacked` collisions | Only `abi.encode` is used for the proposal ID (`Proposal.sol:282`). No `encodePacked` in scope. |
| `delegatecall` to non-library | The only delegatecall path is `PluginCloneable._execute` with the operator-chosen `TargetConfig`, guarded as above. Nothing in `src/` issues its own delegatecall. |
| `transfer()`/`send()` 2300 gas | No ETH movement in scope. |
| Unchecked `.call` return | No low-level calls. |
| Force-feed via `selfdestruct` / CREATE2 / coinbase | No `address(this).balance` read anywhere; no balance-based invariants. |
| Direct token transfers bypass accounting | Voting power comes from `getPastVotes`/`getPastTotalSupply` checkpoints, never from `balanceOf(address(this))`. The plugin holds no tokens. |
| Pause mechanism items (all 4) | No pause/unpause in the plugin or the token. |
| Read-only reentrancy | `GovernanceERC721` uses `_mint`, not `_safeMint`, so minting has no receiver callback. `safeTransferFrom` callbacks fire after OZ's state updates and after `_afterTokenTransfer`, so an observer sees consistent balances and checkpoints. |
| Cross-contract reentrancy | Plugin ↔ token state sharing is checkpoint reads only; the plugin never writes to the token. |
| ERC721 `safeMint`/`safeTransferFrom` callbacks | `_mintTo` uses `_mint`. `safeTransferFrom` is inherited unmodified and the plugin does not call it. |
| ERC777 hooks | No ERC777. |
| `nonReentrant` ordering | No reentrancy guards exist; verified the manual CEI ordering instead. In `Votes._vote`, `votingToken.getPastVotes` is the only external call and precedes all tally reads/writes. In `Proposal._execute`, `executed = true` precedes the external execute. |
| Merkle tree pitfalls | No merkle proofs. |
| Reveal-gap steering | The two-phase flow (create → execute) resolves outcomes from state committed at creation: `snapshotTimepoint`, `minVotingPower`, `minApprovalPower`, `votingMode`, `supportThreshold` and `targetConfig` are all frozen in `createProposal`. The one exception — `votingToken`, read from mutable storage at execution time — is GEN-2. |
| Withdraw undoes all deposit state | No deposit/withdraw pattern. |
| Semantic overloading | Covered by GEN-6 (`minApprovals` ratio-vs-count) and GEN-9. |
| Inconsistent duplicated implementations | Covered by GEN-8. |
| Documentation-code mismatch | Covered by GEN-5, GEN-6, GEN-7. |
| Deployment scripts not checked | Covered by GEN-1, GEN-6, GEN-7. Also verified the script's `ANY_ADDR` grants are legal: `PermissionManager._grant` only blocks `ROOT_PERMISSION_ID` and `DAO.isPermissionRestrictedForAnyAddr` IDs; `CREATE_PROPOSAL_PERMISSION` and `EXECUTE_PROPOSAL_PERMISSION` are on the plugin and not in that set, so both grants succeed. |
| Unbounded loops with external calls | Two loops: `createProposal`'s action copy and `GovernanceERC721.initialize`'s mint loop. Neither makes an external call; both are bounded by the caller's own gas and are self-griefing only. |
| Duplicate addresses in calldata arrays | `GovernanceERC721.TokenSettings.receivers` intentionally allows duplicates (documented) — each entry mints a distinct sequential `tokenId`, so there is no double-count. |
| First iteration edge case | `nextTokenId` starts at 0 and `_mintTo` pre-increments, so the first id is 1 as documented. `_proposalExists` keys on `snapshotTimepoint != 0`, non-zero on any real chain (see MATH-4 for the genesis-block edge case). |
| `block.timestamp` only reliable for long intervals | `minDuration` is floored at 60 minutes, far above validator timestamp drift. |
| Block time varies across chains / non-constant L2 block production | The plugin never uses block counts as a time proxy; durations are in seconds and the snapshot unit follows the token's own clock. See GEN-3 for the detection weakness. |
| Off-by-one in comparisons | Walked each: `_isProposalOpen` uses `start <= now < end`, so `now == endDate` closes the proposal and makes it executable in Standard mode — correct. `isSupportThresholdReached` uses strict `>` (matching the `supportThreshold <= RATIO_BASE - 1` bound); `isMinParticipationReached`/`isMinApprovalReached` use `>=` (matching the `<= RATIO_BASE` bounds) — consistent with the documented intent. |
| Incorrect logical operators | Checked `_canExecute`, `_hasSucceeded`, `_canVote` and `isMember` against the mode semantics; all match. |
| All agents could be the same person | Self-proposing + self-voting is inherent to token-weighted governance and is bounded by the thresholds against a frozen snapshot. The concrete single-party concentration introduced by the deployment is reported in GEN-1 and GEN-7. |
| Receiver address pointing to another system contract | `TARGET_ADDRESS` is operator-chosen but validated by `PluginCloneable._setTargetConfig` (see AC-3 for the incomplete-validation angle). |
| Solidity version-specific bugs | `solc 0.8.28`, no known relevant compiler bugs; `via_ir = false`. |
| PUSH0 on alt-chains | `foundry.toml` sets `evm_version = "cancun"` with pre-set alternatives for Chiliz (`shanghai`) and Peaq (`london`), so the team switches it per target. |
| Unchecked blocks need validation | Four `unchecked` blocks, all verified: two `block.timestamp - 1` / `block.number - 1` computations (only underflow at genesis, see MATH-4), two loop counters bounded by array length / needing 2^256 iterations. |
| Assigning negative value to uint | No signed arithmetic in scope. |
| Time expressions are `uint24` | `60 minutes`, `365 days` are all compared against or added to `uint64` operands, so they widen correctly; they are untyped constant literals, not `uint24` variables. |
| Deleting a struct with nested mappings | No `delete` of `INFTVoting.Proposal` (which holds `mapping(address => VoteOption) voters`) anywhere — proposals are never removed. |
| `if (receiver == caller)` unexpected behavior | Covered by GEN-5 (`delegates(to) == address(0)` conflating two distinct states). |
| System address as user input | `updateVotingToken` validates ERC-165 support for both `IERC721Upgradeable` and `IVotesUpgradeable` before accepting a token. |
| Reorgs change CREATE addresses | The script uses `new NFTVoting()` / `new GovernanceERC721()` (nonce-based CREATE) and writes the resulting addresses to `artifacts/`, so a reorg during the ceremony yields different addresses. The README checklist already requires reconciling `artifacts/`, `logs/` and `broadcast/` output post-deploy, which catches this. |
| Memory struct update not written to storage | `_deployPlugin` copies `_params.targetConfig` into a `memory` local and mutates it — memory-to-memory assignment aliases, so `_params.targetConfig` is also mutated — harmless here, as nothing reads it after `_deployPlugin` returns. All plugin-side struct writes go through `storage` pointers. |
| Writes to storage pointers don't save | All `Proposal storage proposal_` bindings write through correctly; no `memory` copies are mutated and discarded. |

---

Verified the recent fixes named in the brief are complete and did not re-report them: `hasSucceeded` before `endDate` (`Proposal.sol:111-142`), `_disableInitializers()` after the constructor's `initialize` (`GovernanceERC721.sol:80-83` — correct under OZ 4.9.6 `Initializable`), the 365-day `endDate` bound (`Proposal.sol:397-402` — though see GEN-4 for the residual `startDate` gap), `_msgSender()` in `_createProposalId` (`Proposal.sol:282`), and clock detection (`Settings.sol:184-191` — the fix works for the two standard modes; GEN-3 is a *separate*, narrower gap for non-standard ERC-6372 clocks, not a claim that the fix is broken).
