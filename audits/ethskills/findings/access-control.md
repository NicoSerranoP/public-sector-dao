Access-control audit pass complete. 7 findings (1 High, 3 Medium, 3 Low). Checklist item on the `NFTVoting` base-implementation initializer question turned out to be NOT vulnerable — ground truth confirmed in lib/, details at the bottom.

---

## [AC-1] Deployer keeps `EXECUTE_PERMISSION_ID` on the DAO forever — permanent governance bypass
**Severity**: High
**Category**: access-control
**Location**: `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:110-131` (`createDaoAndInstall` / `installOnExistingDao`), interacting with `/home/nnico/public-sector/dao/lib/osx/packages/contracts/src/framework/dao/DAOFactory.sol:182-185`

**Description**:
`createDaoAndInstall` calls `_daoFactory.createDao(_daoSettings, new DAOFactory.PluginSettings[](0))`. Because the plugin-settings array is empty, `DAOFactory.createDao` takes the `else` branch:

```solidity
} else {
    // if no plugin setting is provided, grant EXECUTE_PERMISSION_ID to msg.sender
    createdDao.grant(daoAddress, msg.sender, EXECUTE_PERMISSION_ID);
}
```

Under `vm.startBroadcast(DEPLOYER_KEY)` the `msg.sender` of that call is the deployer EOA, so the deployer EOA is granted `EXECUTE_PERMISSION_ID` on the new DAO. The script then uses that permission once (`_dao.execute(bytes32(0), actions, 0)` at line 130) to wire up plugin/token permissions — and **never revokes it**. `_buildPermissionActions` (lines 188-209) contains only `grant` actions; there is no `revoke` anywhere in `script/`, and the README (line 205) does not mention revoking either.

This is not a limited permission. `DAOFactory._setDAOPermissions` grants the DAO `ROOT_PERMISSION_ID` on itself (`DAOFactory.sol:227-231`), and `PermissionManager.grant` is `auth(ROOT_PERMISSION_ID)` checked as `isGranted(address(this) /* = the DAO */, msg.sender, ROOT_PERMISSION_ID, ...)`. So anyone who can make the DAO call itself can grant/revoke *any* permission on *any* `_where`, including the plugin and the token. `EXECUTE_PERMISSION_ID` is exactly that capability.

The `installOnExistingDao` path has the same shape: it requires and consumes the caller's `EXECUTE_PERMISSION_ID` and leaves it in place.

Net effect: the "decentralized" NFT-voting DAO produced by the standard install script has a permanent superuser EOA that can bypass every proposal, quorum, support threshold and voting period in `Proposal.sol` / `Votes.sol`. All the permission design in the plugin is decorative against this key.

**Proof of Concept**:
1. Operator runs `forge script InstallNFTVoting` with `DEPLOYER_KEY=k`, no `EXISTING_DAO_ADDRESS`.
2. `DAOFactory.createDao(settings, [])` → `dao.grant(dao, addr(k), EXECUTE_PERMISSION)`.
3. Install completes. `dao.isGranted(dao, addr(k), EXECUTE_PERMISSION, "")` is still `true`.
4. Later, with no proposal, no vote and no waiting period, the deployer (or anyone who compromises that key — it is a hot key living in the deploy environment) sends:
   ```solidity
   Action[] memory a = new Action[](2);
   a[0] = Action({to: address(dao), value: 0,
       data: abi.encodeCall(PermissionManager.grant, (address(token), attacker, token.MINT_PERMISSION_ID()))});
   a[1] = Action({to: address(dao), value: 0,
       data: abi.encodeCall(PermissionManager.grant, (address(plugin), attacker, plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID()))});
   dao.execute(bytes32(0), a, 0);
   ```
   The attacker now mints unlimited voting NFTs and rewrites the voting settings. Equivalently they drain the treasury directly with a single `dao.execute` carrying a value/ERC-20 transfer action.
5. Defaults compound this: `_resolveToken` mints all `NFT_COUNT` NFTs (default `1`) to the deployer, `MIN_PROPOSER_VOTING_POWER` defaults to `0`, and `MIN_APPROVALS` defaults to `1` (which `_applyRatioCeiled(total, 1)` turns into "1 yes vote"). Even through the front door the deployer is the entire electorate.

**Recommendation**:
Revoke the bootstrap permission in the same `dao.execute` batch that installs the plugin, so handover is atomic:

```solidity
function _buildPermissionActions(
    DAO _dao, NFTVoting _plugin, IVotesUpgradeable _token, bool _mintedNewToken, address _installer
) internal view returns (Action[] memory actions) {
    actions = new Action[](_mintedNewToken ? 11 : 7);
    // ... existing grants 0..5 (and 6..9 for the token) unchanged ...

    // Final action: drop the installer's bootstrap superuser permission on the DAO.
    uint256 last = actions.length - 1;
    actions[last] = Action({
        to: address(_dao),
        value: 0,
        data: abi.encodeCall(
            PermissionManager.revoke, (address(_dao), _installer, _dao.EXECUTE_PERMISSION_ID())
        )
    });
}
```

Call with `_installer = deployer`, keep the revoke as the *last* action so preceding grants are still authorized. Gate behind an explicit `KEEP_ADMIN_KEY=true` flag if a break-glass key is genuinely wanted; otherwise assert `require(!dao.isGranted(address(dao), deployer, EXECUTE_PERMISSION_ID, ""))` post-install and add the same assertion to `test/fork/InstallNFTVoting.t.sol`.

---

## [AC-2] `updateVotingToken` retroactively re-bases in-flight proposals — bricks or flips them
**Severity**: Medium
**Category**: access-control
**Location**: `Settings.updateVotingToken()` / `Settings._updateVotingToken()` (`/home/nnico/public-sector/dao/src/base/Settings.sol:158-180`), consumed by `Proposal.isSupportThresholdReachedEarly()` (`/home/nnico/public-sector/dao/src/base/Proposal.sol:151-159`) and `Votes._canVote()` (`/home/nnico/public-sector/dao/src/base/Votes.sol:111`)

**Description**:
`Proposal.createProposal` carefully snapshots every setting that can move (`votingMode`, `supportThreshold`, `minVotingPower`, `minApprovalPower`, `targetConfig`, `snapshotTimepoint`) into `proposal_.parameters`, so `updateVotingSettings` cannot retroactively change a live vote. The **voting token is the one thing that is not snapshotted** — it lives in the single mutable `Settings.votingToken` slot, yet is read at evaluation time against the *old* proposal's `snapshotTimepoint`:

- `Proposal.isSupportThresholdReachedEarly` → `totalVotingPower(proposal_.parameters.snapshotTimepoint)` → `votingToken.getPastTotalSupply(oldTimepoint)`
- `Votes._canVote` / `Votes._vote` → `votingToken.getPastVotes(account, oldTimepoint)`

`updateVotingToken` is gated by `UPDATE_VOTING_SETTINGS_PERMISSION_ID` (held by the DAO), so it takes a passing proposal — but that means proposal *A* (token swap) executing while proposal *B* is open silently rewrites *B*'s arithmetic. `_updateVotingToken` also flips `tokenIndexedByTimestamp` via `_detectTokenClock()`, so a stored block-number `snapshotTimepoint` can end up interpreted by a timestamp-clocked token (and vice versa) — not merely wrong but out of range.

Two consequences:
1. **Permanent DoS of open proposals.** A freshly deployed replacement token has no checkpoint at the old `snapshotTimepoint`, so `getPastTotalSupply(oldTimepoint)` returns `0`. Lines 154-155 then compute `0 - tally.yes - tally.abstain`, which underflows and reverts under Solidity ≥0.8. `hasSucceeded`, `canExecute` and `execute` all revert for that proposal forever.
2. **Outcome flip.** Because `minVotingPower`/`minApprovalPower` *are* snapshotted but `totalVotingPower` is not, shrinking the token's historical supply shrinks `noVotesWorstCase` without touching the participation/approval bars, turning a not-yet-passing `EarlyExecution` proposal into an immediately executable one.

**Proof of Concept**:
1. Plugin in `EarlyExecution` mode, token `T1` has 100 NFTs. Proposal *B* created at block `n` (`snapshotTimepoint = n-1`, `minVotingPower = 10`, `minApprovalPower = 1`), gets `yes = 12, no = 0, abstain = 0`. `noVotesWorstCase = 100-12-0 = 88`; `500000*12 > 500000*88` is false → not executable.
2. Proposal *A* (`dao.execute` → `plugin.updateVotingToken(T2)`) passes and executes; `T2` deployed after block `n`.
3. `isSupportThresholdReachedEarly(B)` evaluates `T2.getPastTotalSupply(n-1) == 0`, then `0 - 12 - 0` → underflow → **revert**. `canExecute(B)`, `hasSucceeded(B)`, `execute(B)` revert permanently; `B` is stuck.
   - Variant: if `T2` is an older token whose supply at `n-1` was `12`, then `noVotesWorstCase = 0`, `500000*12 > 0` true, `isMinParticipationReached` (12>=10) true, `isMinApprovalReached` (12>=1) true → `B` becomes executable by *anyone* (`EXECUTE_PROPOSAL_PERMISSION_ID` is `ANY_ADDR`), though it had not passed under `T1`.
4. Meanwhile `T1` holders can no longer vote on `B`: `_canVote` reads `T2.getPastVotes(account, n-1) == 0`.

**Recommendation**:
Snapshot the token per proposal, as every other parameter already is, and refuse to swap while proposals are live:

```solidity
// INFTVoting.ProposalParameters
struct ProposalParameters {
    VotingMode votingMode;
    uint32 supportThreshold;
    uint64 startDate;
    uint64 endDate;
    uint64 snapshotTimepoint;
    uint256 minVotingPower;
    IVotesUpgradeable votingToken; // added: pin the census source
}

// Proposal.createProposal
proposal_.parameters.votingToken = votingToken;

// Proposal.isSupportThresholdReachedEarly
uint256 total = proposal_.parameters.votingToken.getPastTotalSupply(
    proposal_.parameters.snapshotTimepoint
);
uint256 counted = proposal_.tally.yes + proposal_.tally.abstain;
uint256 noVotesWorstCase = total > counted ? total - counted : 0; // saturating

// Votes._canVote / _vote
proposal_.parameters.votingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint)
```

If pinning is too invasive, at minimum make `updateVotingToken` revert while any non-executed proposal is open, and saturate the subtraction so a bad token can never brick `hasSucceeded`/`canExecute`.

---

## [AC-3] `setTargetConfig` accepts a `DelegateCall` target that is not the DAO — full plugin takeover primitive
**Severity**: Medium
**Category**: access-control
**Location**: `PluginCloneable._setTargetConfig()` (`/home/nnico/public-sector/dao/lib/osx-commons/contracts/src/plugin/PluginCloneable.sol:105-118`) reached via `NFTVoting.initialize()` (`/home/nnico/public-sector/dao/src/NFTVoting.sol:51`) and `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:235-241` (`_readMiscSettings`)

**Description**:
`_setTargetConfig` contains only one guard:

```solidity
if (_targetConfig.target.supportsInterface(type(IDAO).interfaceId) &&
    _targetConfig.operation == Operation.DelegateCall) { revert InvalidTargetConfig(_targetConfig); }
```

It blocks `DAO + DelegateCall` and nothing else. Any **non-IDAO** address paired with `Operation.DelegateCall` is accepted, and `Proposal._execute` then routes proposal execution through `PluginCloneable._execute`'s `_target.delegatecall(...)` branch — the plugin executes chosen code **in its own storage context**. That code can overwrite `DaoAuthorizableUpgradeable.dao_` (repointing every `auth()` check at a fake permission manager), `Settings.votingToken`, `Settings.votingSettings`, or the `proposals` mapping.

The install script feeds this config straight from the environment with no validation:

```solidity
params.targetConfig = IPlugin.TargetConfig({
    target: vm.envOr("TARGET_ADDRESS", address(0)),
    operation: IPlugin.Operation(vm.envOr("TARGET_OPERATION", uint256(0)))
});
```

`_deployPlugin` only substitutes the DAO when `TARGET_ADDRESS == address(0)` (lines 166-168); it never checks that a non-zero `TARGET_ADDRESS` is sane, and never checks the `operation`. A one-character `.env` mistake (`TARGET_OPERATION=1` with a non-DAO `TARGET_ADDRESS`) produces a plugin compromised from block zero, and the existing `InvalidTargetConfig` guard gives a false sense that delegatecall configs are validated. Reachable post-install too: `SET_TARGET_CONFIG_PERMISSION_ID` is granted to the DAO (`InstallNFTVoting.s.sol:198`), so one passing proposal installs a backdoor no subsequent vote can remove (the backdoor owns the permission checks).

**Proof of Concept**:
1. Operator sets `TARGET_ADDRESS=0xEvil`, `TARGET_OPERATION=1` (or governance passes `plugin.setTargetConfig(TargetConfig(0xEvil, DelegateCall))`).
2. `0xEvil` does not implement `IDAO`, so the guard passes and the config is stored.
3. Any proposal reaching `execute()` hits `0xEvil.delegatecall(abi.encodeCall(IExecutor.execute, ...))`.
4. `0xEvil` runs as the plugin, `sstore`s the `dao_` slot to a contract whose `hasPermission` always returns `true` for the attacker. The attacker can now call `updateVotingSettings`, `updateVotingToken` and `execute` directly, and the plugin still holds `EXECUTE_PERMISSION_ID` on the real DAO (`InstallNFTVoting.s.sol:196`) — so the attacker drains the DAO.

**Recommendation**:
```solidity
// script/InstallNFTVoting.s.sol :: _deployPlugin
IPlugin.TargetConfig memory targetConfig = _params.targetConfig;
if (targetConfig.target == address(0)) { targetConfig.target = address(_dao); }
require(targetConfig.operation == IPlugin.Operation.Call,
    "refusing to install with a DelegateCall target; set TARGET_OPERATION=0");
require(targetConfig.target.code.length > 0, "TARGET_ADDRESS has no code");
```
And in `NFTVoting`, unless delegatecall is genuinely needed:
```solidity
function _setTargetConfig(TargetConfig memory _targetConfig) internal virtual override {
    if (_targetConfig.operation == Operation.DelegateCall) {
        revert InvalidTargetConfig(_targetConfig);
    }
    super._setTargetConfig(_targetConfig);
}
```

---

## [AC-4] DAO holds `MINT` + `BURN` + `TRANSFER` on the voting token — a simple majority can permanently seize the electorate
**Severity**: Medium
**Category**: access-control
**Location**: `GovernanceERC721.mint()/burn()/adminTransfer()` (`/home/nnico/public-sector/dao/src/erc721/GovernanceERC721.sol:124-144`); grants at `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:204-207`

**Description**:
The auth wiring itself is **correct** — `mint` is `auth(MINT_PERMISSION_ID)`, `burn` is `auth(BURN_PERMISSION_ID)`, `adminTransfer` is `auth(TRANSFER_PERMISSION_ID)`, `setBaseURI` is `auth(UPDATE_BASE_URI_ID)`, all resolved through `DaoAuthorizableUpgradeable.auth` → `_auth(dao_, address(this), _msgSender(), ...)` with `_msgSender()` being plain `msg.sender` (no trusted-forwarder metatx in this inheritance chain). No bypass found. The issue is the *composition*.

`adminTransfer` calls `ERC721Upgradeable._transfer` directly, which performs **no owner-approval check** — it only requires `_from` be the current owner. There is no mint cap, no cooldown, no timelock. Worse, `_afterTokenTransfer` auto-self-delegates any receiver with no delegate, so freshly minted or seized tokens become live voting power in the next block with zero action from the recipient.

Governance capture is therefore self-reinforcing and irreversible: whoever wins one vote can mint an arbitrary supermajority and/or burn every dissenting holder's NFT, after which no future vote can dislodge them. No member-side protection exists (no exit, no veto window, no non-transferable minority stake). The entire supply is initially minted to the deployer (`_resolveToken`, lines 141-155), so on day one "a simple majority" is one address.

**Proof of Concept**:
1. Attacker holds (or starts with, per AC-1) a bare majority of voting NFTs.
2. Attacker creates a proposal whose actions are DAO-routed calls: `GovernanceERC721.burn(victimTokenId)` and N× `GovernanceERC721.mint(attacker)`.
3. Proposal passes on the existing majority; `EXECUTE_PROPOSAL_PERMISSION_ID` is `ANY_ADDR` so the attacker executes it immediately.
4. Victims' NFTs are burned; attacker's new NFTs self-delegate on mint and count from the next block. `adminTransfer(victim, attacker, id)` achieves the same without destroying value, with the `AdminTransfer` event as the only trace. Every subsequent vote is decided by the attacker.

**Recommendation**:
- Do not grant all four to the same holder by default. Give `MINT`/`BURN` to a dedicated membership plugin or a timelocked executor, not the same address that executes arbitrary treasury actions.
- Consider not granting `TRANSFER_PERMISSION_ID` in the default install, since `adminTransfer` exists purely to override holder consent:
  ```solidity
  // actions[8] = _grantAction(_dao, address(_token), address(_dao), nft.TRANSFER_PERMISSION_ID());
  // ^ opt-in only, behind an explicit GRANT_ADMIN_TRANSFER env flag; the DAO retains ROOT on itself
  //   and can grant it later via proposal if genuinely needed.
  ```
- Add a supply cap so one proposal cannot manufacture an unbounded majority:
  ```solidity
  uint256 public immutable maxSupply;
  function mint(address _to) external virtual auth(MINT_PERMISSION_ID) returns (uint256 tokenId) {
      require(nextTokenId < maxSupply, "supply cap reached");
      return _mintTo(_to);
  }
  ```
- Document this in the README's permission table; today README:22 only says the DAO "can force-transfer via `adminTransfer` and revoke via `burn`" without stating it is unbounded and reachable by a bare majority.

---

## [AC-5] `EXECUTE_PROPOSAL_PERMISSION_ID` permission check in `_vote` is passed the wrong calldata
**Severity**: Low
**Category**: access-control
**Location**: `Votes._vote()` — `/home/nnico/public-sector/dao/src/base/Votes.sol:65-70`

**Description**:
```solidity
if (
    _canExecute(_proposalId)
        && dao().hasPermission(address(this), _voter, EXECUTE_PROPOSAL_PERMISSION_ID, _msgData())
) { _execute(_proposalId); }
```
`_msgData()` here is the calldata of the **`vote(...)` call**, not of an `execute(uint256)` call. Aragon's `PermissionManager.isGranted` forwards that `_data` blob to any `IPermissionCondition` attached to the permission (`PermissionManager.sol:241-249, 265-274, 286-295`). A condition written to inspect the execute selector/arguments — the natural way to write "this address may only execute proposals matching X" — receives `vote(uint256,uint8,bool)` calldata and mis-parses or rejects.

Latent today: the install grants `EXECUTE_PROPOSAL_PERMISSION_ID` to `ANY_ADDR` with a plain `grant` (no condition), and `isGranted` short-circuits on `ALLOW_FLAG` before consulting any condition. It becomes incorrect the moment anyone re-grants via `grantWithCondition`, a normal Aragon operation.

**Proof of Concept**:
1. DAO tightens execution: `dao.grantWithCondition(plugin, ANY_ADDR, EXECUTE_PROPOSAL_PERMISSION_ID, cond)` where `cond` does `abi.decode(_data[4:], (uint256))`.
2. A voter calls `plugin.vote(pid, VoteOption.Yes, true)`.
3. `_vote` calls `hasPermission(..., _msgData())`, passing `abi.encodeWithSelector(vote.selector, pid, 2, true)`.
4. `cond` reads *vote* calldata. The first word happens to be `pid` by coincidence of argument order, but the selector is `vote`, and the remaining words are the vote option and bool — any condition checking the selector or reading further arguments mis-evaluates. It either wrongly permits early execution the condition meant to block, or wrongly blocks all early execution *silently* (the branch just falls through without reverting).

**Recommendation**:
```solidity
if (
    _canExecute(_proposalId)
        && dao().hasPermission(
            address(this), _voter, EXECUTE_PROPOSAL_PERMISSION_ID,
            abi.encodeCall(this.execute, (_proposalId))
        )
) { _execute(_proposalId); }
```

---

## [AC-6] Install script grants no token permissions on the `TOKEN_ADDRESS` path
**Severity**: Low
**Category**: access-control
**Location**: `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:188-209` (`_buildPermissionActions`), gated on `_mintedNewToken`

**Description**:
`_buildPermissionActions` only emits the `MINT`/`BURN`/`TRANSFER`/`UPDATE_BASE_URI` grants inside `if (_mintedNewToken)`. When the operator supplies `TOKEN_ADDRESS`, the install completes with the DAO holding **no permission at all** on the voting token.

The script doc comment (lines 21-23) actively recommends this path — "For a custom initial distribution, mint a token yourself first and pass its address as `existingToken`" — and the natural way to do that is `new GovernanceERC721(dao, settings)` with the same DAO. The result is a DAO that cannot mint to new members, cannot burn, and cannot update `baseTokenURI`, though the token names that DAO as its permission authority.

Recoverable rather than fatal: the DAO holds `ROOT_PERMISSION_ID` on itself, and `PermissionManager.grant`'s `auth(ROOT_PERMISSION_ID)` is checked against `_where = address(dao)` not the token, so a later proposal can `dao.execute` a `grant(token, dao, MINT_PERMISSION_ID)`. But that requires a governance round nothing tells the operator they need.

**Proof of Concept**:
1. Operator deploys `GovernanceERC721(dao, settings)` with a custom receiver list.
2. Operator runs the install with `TOKEN_ADDRESS=<that token>`.
3. `_mintedNewToken == false`, so `actions` has length 6 and contains no token grants.
4. `dao.isGranted(token, dao, MINT_PERMISSION_ID, "")` is `false`. A proposal calling `token.mint(newMember)` reverts with `DaoUnauthorized(dao, token, dao, MINT_PERMISSION)`. Membership is frozen until diagnosed.

**Recommendation**:
```solidity
function _buildPermissionActions(
    DAO _dao, NFTVoting _plugin, IVotesUpgradeable _token, bool _mintedNewToken
) internal view returns (Action[] memory actions) {
    bool daoManagesToken = _mintedNewToken || _tokenIsManagedBy(_token, _dao);
    actions = new Action[](daoManagesToken ? 10 : 6);
    // ... grants 0..5 unchanged ...
    if (daoManagesToken) { /* ... existing 6..9 ... */ }
}

function _tokenIsManagedBy(IVotesUpgradeable _token, DAO _dao) internal view returns (bool) {
    try GovernanceERC721(address(_token)).dao() returns (IDAO tokenDao) {
        return address(tokenDao) == address(_dao);
    } catch { return false; }
}
```
Also print the resulting permission table in `printDeployment()`.

---

## [AC-7] Anyone can create proposals (`CREATE_PROPOSAL_PERMISSION_ID` → `ANY_ADDR`, `minProposerVotingPower` defaults to 0)
**Severity**: Low
**Category**: access-control
**Location**: `Proposal.createProposal()` / `Proposal.canCreateProposal()` (`/home/nnico/public-sector/dao/src/base/Proposal.sol:175-193, 252-315`); grant at `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:197`; default at line 248

**Description**:
The install grants `CREATE_PROPOSAL_PERMISSION_ID` to `ANY_ADDR`, and `MIN_PROPOSER_VOTING_POWER` defaults to `0`. `canCreateProposal` short-circuits to `true` when `minProposerVotingPower_ == 0` (lines 188-190), so proposal creation on a default install is fully permissionless — non-members with zero NFTs and zero delegated power included.

Escalation angles were checked and do not hold up further: proposal ids are `_createProposalId(keccak256(abi.encode(_msgSender(), _actions, _metadata)))` with `_msgSender()` in the preimage (plus `block.chainid, block.number, address(this)` from `ProposalUpgradeable._createProposalId`), so one account cannot front-run or squat another's id; `ProposalAlreadyExists` only fires for the same sender in the same block. `createProposal` also reverts with `NoVotingPower()` when total supply is zero. So this is griefing, not theft.

Residual impact is spam: unbounded proposal creation floods `ProposalCreated` events and the `proposals` mapping (attacker pays gas), degrading any UI/indexer that enumerates proposals and making it easy to bury a legitimate proposal. There is no cancel, no veto and no proposal-expiry cleanup in `Proposal.sol`.

**Proof of Concept**:
1. Default install: `MIN_PROPOSER_VOTING_POWER` unset → `0`; `CREATE_PROPOSAL_PERMISSION_ID` → `ANY_ADDR`.
2. Attacker holds zero NFTs. `plugin.canCreateProposal(attacker)` returns `true` at line 189 without ever consulting the token.
3. Attacker loops `plugin.createProposal(bytes(i), actions, 0, 0, 0)` with varying metadata, producing a distinct id each iteration. Thousands of proposals appear in the DAO UI.
4. Members cannot find the real proposal.

**Recommendation**:
```solidity
// script/InstallNFTVoting.s.sol :: _readVotingSettings
params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(1));
```
With `1`, `canCreateProposal` falls through to `votingToken.getPastVotes(_account, snapshotTimepoint) >= 1`, restricting creation to addresses that actually held/were delegated a voting NFT as of the previous block — which is presumably what the `ANY_ADDR` grant means ("any *member*", enforced in code rather than in the permission). Alternatively replace the `ANY_ADDR` grant with `grantWithCondition` using a membership-checking `IPermissionCondition`, and document that `MIN_PROPOSER_VOTING_POWER=0` means literally anyone.

---

# Checklist items reviewed with no finding (verified in lib/, not assumed)

- **Initializer callable on the un-cloned `NFTVoting` base — NOT vulnerable.** `script/InstallNFTVoting.s.sol:170` does `address nftVotingBase = address(new NFTVoting())`. Inheritance is `NFTVoting → Votes → Proposal → Settings → PluginCloneable` (`src/base/Settings.sol:26`), and `lib/osx-commons/contracts/src/plugin/PluginCloneable.sol:44-48` is `constructor() { _disableInitializers(); }`. That constructor runs as part of `new NFTVoting()`, setting `_initialized = type(uint8).max` on the base's own storage, so a direct `nftVotingBase.initialize(...)` reverts with "Initializable: contract is already initialized". The minimal proxy on line 172 has fresh storage and is unaffected. No other base in the chain (`MetadataExtensionUpgradeable`, `ProposalUpgradeable`, `DaoAuthorizableUpgradeable`, `ERC165Upgradeable`) declares a constructor or resets the flag. Even a successful hijack would be inert: `auth()` resolves through `dao_`, so the attacker would control a contract holding no permission anywhere. `GovernanceERC721`'s separate `new`-deployment pattern is also correct — constructor calls `initialize` then `_disableInitializers()` (lines 80-83), and the `initializer` modifier permits the in-constructor call because `address(this)` has no code yet.
- **`_updateVotingToken` calling `supportsInterface` on a codeless address** — safe. solc 0.8.28 emits an `extcodesize` check for high-level external calls expecting return data, so `IERC165Upgradeable(eoa).supportsInterface(...)` reverts rather than silently returning `true`. Both `require`s (`Settings.sol:165-173`) fail closed for EOAs/empty addresses.
- **`GovernanceERC721.setBaseURI` access control** — correct. `auth(UPDATE_BASE_URI_ID)`; the only other writer of `baseTokenURI` is `initialize`, which is locked. `_baseURI()`/`baseURI()` are view-only.
- **`GovernanceERC721.adminTransfer` access control** — the modifier itself is correct (`auth(TRANSFER_PERMISSION_ID)`, `_transfer` enforces `ownerOf == _from`). The composition concern is AC-4.
- **Grant of `CREATE_PROPOSAL`/`EXECUTE_PROPOSAL` to `ANY_ADDR` reverting** — checked; it does not. `PermissionManager._grant` only rejects `_who == ANY_ADDR` for `ROOT_PERMISSION_ID` or an `isPermissionRestrictedForAnyAddr` id; `DAO.isPermissionRestrictedForAnyAddr` (DAO.sol:227-236) lists only `EXECUTE_PERMISSION`, `UPGRADE_DAO_PERMISSION`, `SET_METADATA_PERMISSION`, `SET_TRUSTED_FORWARDER_PERMISSION`, `REGISTER_STANDARD_CALLBACK_PERMISSION`. Note the script's `SET_METADATA_PERMISSION_ID` grant (line 199) is to `address(_dao)`, not `ANY_ADDR`, so it does not hit that restriction — all install-script grants succeed.
- **Permission completeness** — every `auth()`-gated entry point in scope has a matching grant on the new-token path: `UPDATE_VOTING_SETTINGS_PERMISSION_ID` (covers both `updateVotingSettings` and `updateVotingToken`) → DAO; `SET_TARGET_CONFIG_PERMISSION_ID` → DAO; `SET_METADATA_PERMISSION_ID` → DAO; `CREATE_PROPOSAL`/`EXECUTE_PROPOSAL` → `ANY_ADDR`; DAO `EXECUTE_PERMISSION_ID` → plugin (required for `Proposal._execute` to reach the DAO); token `MINT`/`BURN`/`TRANSFER`/`UPDATE_BASE_URI` → DAO. The gaps found are the *excess* retained by the deployer (AC-1) and the missing token grants on the `TOKEN_ADDRESS` path (AC-6).
- **Acting on behalf of another user** — none. `Votes.vote` uses `_msgSender()` only; no `voteFor`/`voteBySig`. `_msgSender()` resolves to `ContextUpgradeable._msgSender()` (plain `msg.sender`) — `DaoAuthorizableUpgradeable` does *not* implement trusted-forwarder metatx, so the DAO's `trustedForwarder` cannot spoof a voter at the plugin. Delegation is handled inside `ERC721VotesUpgradeable` by the holder.
- **Upgradeability / implementation swap** — N/A. `NFTVoting` is `PluginType.Cloneable` (ERC-1167, no admin slot, no `upgradeTo`); `GovernanceERC721` is `new`-deployed, not proxied. The DAO proxy is UUPS but `UPGRADE_DAO_PERMISSION_ID` is held only by the DAO — though AC-1's retained `EXECUTE_PERMISSION` reaches it too.
- **Pausing** — no pause mechanism in any in-scope contract, and no equivalent hidden chokepoint (execution routes only through `Proposal.execute` / early execution in `_vote`).
- **Two-step ownership transfer** — N/A for Aragon's permission-ID model; grant/revoke is the transfer mechanism and is ROOT-gated.
- **Renounce bricking the contract** — not brickable. If the DAO revoked `UPDATE_VOTING_SETTINGS_PERMISSION_ID` from itself, it still holds `ROOT_PERMISSION_ID` on itself and can re-grant via proposal. The one genuinely unrecoverable state is AC-3's delegatecall backdoor.
- **`execute()` on a nonexistent proposal** — checked; `Proposal.execute` lacks `onlyIfProposalExists`, but for a zero-initialized proposal `_isProposalOpen` is `false`, `votingMode` is `Standard`, and `isSupportThresholdReached` evaluates `1e6*0 > 0*0` → `false`, so `_canExecute` returns `false` and the call reverts with `ProposalExecutionForbidden`. No phantom execution.
- **Proposal-id squatting / front-running** — not possible; `_msgSender()` is in the id preimage (`Proposal.sol:282`) and `ProposalUpgradeable._createProposalId` mixes in `block.chainid`, `block.number`, `address(this)`.
- **Whitelist bypass via aliasing** — N/A; no address whitelist. `ANY_ADDR` semantics verified against `PermissionManager.isGranted`: an `ANY_ADDR` grant with `ALLOW_FLAG` short-circuits to `true` for every caller, which is what the install intends.
