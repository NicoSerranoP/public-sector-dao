# Entry Point Map

> NFTVoting Plugin | 11 entry points | 3 permissionless | 4 role-gated | 4 admin-only | + 2 initializers

---

## Protocol Flow Paths

### Setup (Deployer / DAO — `InstallNFTVoting.s.sol`)

`DAOFactory.createDao()` → `new GovernanceERC721(dao, name, symbol, {receivers})`  ◄── constructor calls `initialize`, mints one NFT per receiver entry, auto self-delegates each
   → `new NFTVoting()` (clone base) → `base.deployMinimalProxy(abi.encodeCall(NFTVoting.initialize, ...))`  ◄── atomic init
   → `new VotingPowerCondition(plugin)`  ◄── caches `PLUGIN` + `VOTING_TOKEN`
   → `DAO.execute(grant actions)`:
        `grant(plugin, DAO, UPDATE_VOTING_SETTINGS_PERMISSION)`
        `grant(DAO, plugin, EXECUTE_PERMISSION)`
        `grantWithCondition(plugin, ANY_ADDR, CREATE_PROPOSAL_PERMISSION, VotingPowerCondition)`
        `grant(plugin, DAO, SET_TARGET_CONFIG_PERMISSION)`, `grant(plugin, DAO, SET_METADATA_PERMISSION)`
        `grant(plugin, ANY_ADDR, EXECUTE_PROPOSAL_PERMISSION)`
        if new token: `grant(token, DAO, MINT_PERMISSION | BURN_PERMISSION | TRANSFER_PERMISSION)`

### Proposer Flow

`[setup above]` → `NFTVoting.createProposal(metadata, actions[], allowFailureMap, startDate, endDate, voteOption, tryEarlyExecution)`
   ◄── `VotingPowerCondition.isGranted`: `getPastVotes(caller, block-1) >= minProposerVotingPower` (skipped if `minProposerVotingPower == 0`)
   ◄── `getPastTotalSupply(block-1) != 0`
        └─→ if `voteOption != None` → `vote(proposalId, voteOption, tryEarlyExecution)`

`NFTVoting.createProposal(metadata, actions[], startDate, endDate, data)` (IProposal 5-arg) → decodes `data` → calls the 7-arg `createProposal` above (permission check happens there).

### Voter Flow

`[createProposal above]` → [`startDate` reached] → `NFTVoting.vote(proposalId, voteOption, tryEarlyExecution)`
   ◄── `_canVote`: proposal open, `voteOption != None`, `getPastVotes(voter, snapshot) > 0`, (not already voted OR `votingMode == VoteReplacement`)
        └─→ if `tryEarlyExecution` && `_canExecute` && `DAO.hasPermission(plugin, voter, EXECUTE_PROPOSAL_PERMISSION)` → `_execute`

### Executor Flow

`[votes cast]` → [proposal closed, or `EarlyExecution` worst-case support met] → `NFTVoting.execute(proposalId)`
   ◄── `_canExecute`: `!executed`; for `Standard`/`VoteReplacement` the proposal must be closed; `_hasSucceeded` (support + participation + minApproval)
        └─→ `proposal_.executed = true` → `ProposalUpgradeable._execute(target, id, actions, allowFailureMap, operation)` → `DAO.execute(...)`

### Token Maintenance (DAO)

`GovernanceERC721.mint(to)` → `tokenId = ++nextTokenId` → `_mint` → `_afterTokenTransfer` → auto self-delegate `to` if `delegates(to) == 0`
`GovernanceERC721.burn(tokenId)` → `_burn` → voting units removed
`GovernanceERC721.adminTransfer(from, to, tokenId)` → `_transfer` (no approval check) → `_afterTokenTransfer` → auto self-delegate `to` if undelegated → `emit AdminTransfer`

---

## Permissionless

### `NFTVoting.vote()`

| Aspect | Detail |
|--------|--------|
| Visibility | `public virtual` — no reentrancy guard |
| Caller | Any address that had voting power at the proposal snapshot |
| Parameters | `_proposalId` (user-controlled), `_voteOption` (user-controlled), `_tryEarlyExecution` (user-controlled) |
| Call chain | `→ _canVote() → votingToken.getPastVotes() → _vote() → votingToken.getPastVotes() → (early exec) _canExecute() → DAO.hasPermission() → _execute() → ProposalUpgradeable._execute() → DAO.execute()` |
| State modified | `proposals[id].tally.{yes,no,abstain}`, `proposals[id].voters[msg.sender]`, `proposals[id].executed` (on early execution) |
| Value flow | None (governance) |
| Reentrancy guard | no |

### `NFTVoting.execute()`

| Aspect | Detail |
|--------|--------|
| Visibility | `public virtual override`, `auth(EXECUTE_PROPOSAL_PERMISSION_ID)` — granted to `ANY_ADDR` in the reference install |
| Caller | Any address (effective) |
| Parameters | `_proposalId` (user-controlled) |
| Call chain | `→ _canExecute() → _hasSucceeded() → isSupportThresholdReached()/…Early() → isMinParticipationReached() → isMinApprovalReached() → _execute() → ProposalUpgradeable._execute() → DAO.execute()` |
| State modified | `proposals[id].executed` |
| Value flow | None directly; the executed `Action[]` may move DAO funds |
| Reentrancy guard | no (`executed` set before the external call) |

### `GovernanceERC721` holder functions (inherited from OZ `ERC721VotesUpgradeable`)

| Aspect | Detail |
|--------|--------|
| Functions | `transferFrom`, `safeTransferFrom` (x2), `approve`, `setApprovalForAll`, `delegate`, `delegateBySig` |
| Visibility | `public` (OZ), no reentrancy guard; `safeTransferFrom` calls `onERC721Received` on a contract recipient |
| Caller | Token holder / approved operator / (for `delegateBySig`) anyone with a valid signature |
| Parameters | recipient / operator / delegatee (user-controlled); `delegateBySig` sig params (user-signed) |
| Call chain | `→ _transfer/_mint → _afterTokenTransfer → super._afterTokenTransfer (move voting units) → (if delegates(to)==0) _delegate(to,to)` |
| State modified | `_owners`, `_balances`, `_tokenApprovals`, `_operatorApprovals`, `_delegatee`, vote checkpoints |
| Value flow | NFT: `from → to` |
| Reentrancy guard | no |

---

## Role-Gated

### `CREATE_PROPOSAL_PERMISSION_ID` (granted to `ANY_ADDR` with `VotingPowerCondition`)

#### `NFTVoting.createProposal(bytes,Action[],uint256,uint64,uint64,VoteOption,bool)`

| Aspect | Detail |
|--------|--------|
| Visibility | `public virtual`, `auth(CREATE_PROPOSAL_PERMISSION_ID)` |
| Caller | Any address with snapshot voting power ≥ `minProposerVotingPower` (condition), or anyone if that is 0 |
| Parameters | `_metadata` (user-controlled), `_actions[]` (user-controlled), `_allowFailureMap` (user-controlled), `_startDate` / `_endDate` (user-controlled, bounded by `minDuration`), `_voteOption` (user-controlled), `_tryEarlyExecution` (user-controlled) |
| Call chain | `→ VotingPowerCondition.isGranted() → PLUGIN.minProposerVotingPower() → VOTING_TOKEN.getPastVotes()` ; then `→ totalVotingPower() → votingToken.getPastTotalSupply() → _validateProposalDates() → _createProposalId() → (optional) vote()` |
| State modified | `proposals[id]` (parameters, minApprovalPower, targetConfig, actions[], allowFailureMap) |
| Value flow | None |
| Reentrancy guard | no |

#### `NFTVoting.createProposal(bytes,Action[],uint64,uint64,bytes)` (IProposal)

| Aspect | Detail |
|--------|--------|
| Visibility | `external virtual override` — no own modifier; permission enforced by the 7-arg `createProposal` it calls |
| Caller | Same as above |
| Parameters | `_metadata`, `_actions[]`, `_startDate`, `_endDate` (user-controlled); `_data` = abi-encoded `(allowFailureMap, voteOption, tryEarlyExecution)` (user-controlled) |
| Call chain | `→ abi.decode(_data) → createProposal(7-arg)` |
| State modified | via delegated call |
| Value flow | None |
| Reentrancy guard | no |

### `EXECUTE_PROPOSAL_PERMISSION_ID` — early-execution path

#### `NFTVoting._vote()` early-execution branch (reached from permissionless `vote()`)

| Aspect | Detail |
|--------|--------|
| Trigger | `vote(..., _tryEarlyExecution = true)` when `_canExecute` and the voter holds `EXECUTE_PROPOSAL_PERMISSION_ID` (`ANY_ADDR` in reference install) |
| State modified | `proposals[id].executed`, then DAO-side effects of `Action[]` |
| Reentrancy guard | no |

---

## Admin-Only

Restricted to the managing DAO (holder of the permission). No timelock.

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| `NFTVoting` | `updateVotingSettings(VotingSettings)` — `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` | `_votingSettings` (votingMode, supportThreshold, minParticipation, minDuration, minProposerVotingPower) — protocol-derived by the DAO | `votingSettings` |
| `NFTVoting` | `updateMinApprovals(uint256)` — `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` | `_minApprovals` (ratio, ≤ RATIO_BASE) | `minApprovals` |
| `GovernanceERC721` | `mint(address)` — `auth(MINT_PERMISSION_ID)` | `_to` | `nextTokenId`, `_owners`, `_balances`, vote checkpoints, `_delegatee[_to]` (if was 0) |
| `GovernanceERC721` | `burn(uint256)` — `auth(BURN_PERMISSION_ID)` | `_tokenId` | `_owners`, `_balances`, vote checkpoints |
| `GovernanceERC721` | `adminTransfer(address,address,uint256)` — `auth(TRANSFER_PERMISSION_ID)` | `_from`, `_to`, `_tokenId` | `_owners`, `_balances`, vote checkpoints, `_delegatee[_to]` (if was 0); emits `AdminTransfer` |

Note: `NFTVoting` also inherits `setTargetConfig` / `setMetadata` (from `MetadataExtensionUpgradeable` / `IPlugin`), gated by `SET_TARGET_CONFIG_PERMISSION_ID` / `SET_METADATA_PERMISSION_ID`, both granted to the DAO in the reference install.

---

## Initialization (one-time)

| Contract | Function | Guard | Notes |
|----------|----------|-------|-------|
| `NFTVoting` | `initialize(IDAO, VotingSettings, IVotesUpgradeable, TargetConfig, uint256, bytes)` | `initializer` | Called atomically by `deployMinimalProxy`. Requires `_token` to `supportsInterface(IERC721)`. The clone base is deployed without `initialize` and without `_disableInitializers()`. |
| `GovernanceERC721` | `initialize(IDAO, string, string, MintSettings)` | `initializer`, `public` | Called from the constructor. Mints one token per `receivers[]` entry. |
