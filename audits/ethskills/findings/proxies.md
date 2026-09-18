# Proxy & Upgrade Audit — findings

**Headline results:**
1. `PluginCloneable`'s constructor **does** call `_disableInitializers()` — the un-cloned `NFTVoting` base **is** protected. Confirmed by source AND runtime test. Not a finding.
2. `ProxyLib.deployMinimalProxy` is **NOT atomic under Foundry broadcast**. Empirically proven via broadcast artifact: it produces two separate transactions (clone CREATE, then initialize CALL), leaving the plugin clone front-runnably uninitialized. This is the real High-severity finding.
3. `MAJORITY_VOTING_BASE_INTERFACE_ID` is built from a phantom selector (`0x9cba3021`) for a function that does not exist in this fork's ABI. Low.

---

## [PROXY-1] Foundry broadcast splits `deployMinimalProxy` into two transactions, leaving the NFTVoting clone front-runnably uninitialized
**Severity**: High
**Category**: proxies
**Location**: `script/InstallNFTVoting.s.sol:170-184` (`InstallNFTVotingScript._deployPlugin()`), via `ProxyLib.deployMinimalProxy` (`lib/osx-commons/contracts/src/utils/deployment/ProxyLib.sol:34-42`)

**Description**:
`ProxyLib.deployMinimalProxy` is an `internal` library function, so it is inlined into the script contract's own frame. Its two steps — `_logic.clone()` (a `CREATE`) and `minimalProxy.functionCall(_initCalldata)` (a `CALL`) — therefore both originate at the script's top level while `vm.startBroadcast` is active. Foundry records **each top-level `CREATE`/`CALL` as a separate on-chain transaction**. The clone and its `initialize()` are consequently *not* atomic: the EIP-1167 proxy is published to the chain in one transaction and sits with `_initialized == 0` until a later, independent transaction initializes it.

`NFTVoting.initialize()` is `external initializer` with **no access control** on who may call it and no constraint on the `_dao` argument, so the first caller to reach the deployed clone chooses the plugin's managing DAO, voting token, voting settings and target config permanently.

The transaction split was verified empirically (not assumed) via a probe script using the exact same `ProxyLib.deployMinimalProxy` call under `vm.startBroadcast`, which produced this broadcast artifact:

```
NUMBER OF BROADCAST TRANSACTIONS: 3
0 | type=CREATE | contractName=Probe | to=None       | data[:10]=0x60806040   <- implementation
1 | type=CREATE | contractName=None  | to=None       | data[:10]=0x3d602d80   <- EIP-1167 clone (uninitialized)
2 | type=CALL   | contractName=None  | to=0x20f0a...  | data[:10]=0xfe4b84df   <- initialize()
```

Transactions 1 and 2 are distinct. In the real script the full broadcast sequence is:
`createDao` -> `new GovernanceERC721` -> `new NFTVoting` -> **clone CREATE** -> **`initialize()` CALL** -> `dao.execute(grants)`.

Note this is specifically a *script/deployment* defect, not a defect in `PluginCloneable` — see PROXY-4, the base implementation itself is correctly locked.

**Proof of Concept**:
Runtime PoC (compiled and run against this repo, passed):

```solidity
function test_uninitializedCloneIsHijackable() public {
    NFTVoting base = new NFTVoting();
    address attackerDao = address(new DAO());
    IVotesUpgradeable tok = _token(attackerDao);

    // broadcast tx #1: clone CREATE, left uninitialized
    address clone = Clones.clone(address(base));

    // attacker front-runs broadcast tx #2
    vm.prank(address(0xA77ACC));
    NFTVoting(clone).initialize(
        IDAO(attackerDao), _settings(), tok,
        IPlugin.TargetConfig({target: address(0xCAFE), operation: IPlugin.Operation.Call}), "pwned"
    );
    assertEq(address(NFTVoting(clone).dao()), attackerDao);   // passes

    // the deployer's own initialize() now reverts
    address realDao = address(new DAO());
    vm.expectRevert("Initializable: contract is already initialized");
    NFTVoting(clone).initialize(IDAO(realDao), _settings(), tok,
        IPlugin.TargetConfig({target: address(0), operation: IPlugin.Operation.Call}), "");
}
```
Output:
```
Q2 RESULT: uninitialized clone hijacked; dao() = 0x2e234DAe75C793f67A35089C9d99245E1C58470b
Q2 RESULT: legitimate initialize() now reverts (deployment DoS)
[PASS] test_uninitializedCloneIsHijackable()
```

Exploitation steps on a chain with a public mempool:
1. Operator runs `forge script ... --broadcast`. The clone-CREATE transaction lands; the plugin address is now on-chain and uninitialized.
2. Attacker watches for a `NFTVoting`-shaped EIP-1167 clone creation (or simply front-runs the pending `initialize()` calldata, which reveals the target address directly) and submits their own `initialize(attackerDAO, settings, attackerToken, targetConfig, "")` with higher priority fee.
3. The attacker's DAO now backs every `auth(...)` check on the plugin, so the attacker holds `CREATE_PROPOSAL`, `EXECUTE_PROPOSAL`, `UPDATE_VOTING_SETTINGS` and `SET_TARGET_CONFIG` on it, and supplies a voting token in which they hold all voting power (`_updateVotingToken` only checks ERC-165 support for `IERC721Upgradeable` / `IVotesUpgradeable`, both trivial to fake).
4. The operator's `initialize()` transaction reverts.

Minimum impact: permanent hijack of that plugin instance plus a deployment DoS forcing a redeploy.
Escalation to full DAO takeover: the *next* broadcast transaction is `_dao.execute(_buildPermissionActions(...))` (`script/InstallNFTVoting.s.sol:129-130`), which grants the plugin `EXECUTE_PERMISSION_ID` on the real DAO. Foundry's default (non-`--slow`) broadcast submits queued transactions without waiting for each prior receipt, and the reverted `initialize()` still consumes its nonce, so this grant can still land. If it does, the real DAO has granted `EXECUTE_PERMISSION` to a plugin whose `dao()` and voting token are attacker-controlled — the attacker creates a proposal whose action grants themselves `ROOT_PERMISSION` on the real DAO, votes with their own token, and executes. Rated High rather than Critical because it requires a public mempool (not exploitable behind a private L2 sequencer mempool) and the takeover path depends on the grant transaction landing.

Also note: adding a `require(plugin_.dao() == address(_dao))` guard in the *script body* does **not** fix this — script-body assertions execute during Foundry's local simulation, before broadcasting, so they never observe the attacker's on-chain state.

**Recommendation**:
Make clone + initialize atomic by performing both inside a single on-chain transaction. The minimal change is to move the deployment into a helper contract, so the script makes exactly one external call:

```solidity
// src/NFTVotingFactory.sol
contract NFTVotingFactory {
    using ProxyLib for address;

    address public immutable base = address(new NFTVoting());

    /// @notice Deploys and initializes an NFTVoting clone in a single transaction.
    function deploy(
        IDAO _dao,
        INFTVoting.VotingSettings calldata _votingSettings,
        IVotesUpgradeable _token,
        IPlugin.TargetConfig calldata _targetConfig,
        bytes calldata _pluginMetadata
    ) external returns (NFTVoting plugin_) {
        plugin_ = NFTVoting(
            base.deployMinimalProxy(
                abi.encodeCall(
                    NFTVoting.initialize,
                    (_dao, _votingSettings, _token, _targetConfig, _pluginMetadata)
                )
            )
        );
    }
}
```

and in `_deployPlugin`:

```solidity
NFTVotingFactory factory = new NFTVotingFactory();   // broadcast tx 1
plugin_ = factory.deploy(                            // broadcast tx 2: CREATE + initialize, atomic
    IDAO(address(_dao)), _params.votingSettings, _token, targetConfig, _params.pluginMetadata
);
require(address(plugin_.dao()) == address(_dao), "plugin init mismatch");
```

Because `deployMinimalProxy` is now called from *inside* `NFTVotingFactory.deploy`, the `CREATE` and the `initialize` `CALL` are nested sub-calls of one transaction and Foundry broadcasts them as one. The same restructuring should cover the whole install: ideally have the factory also perform `_dao.execute(permissionActions)` so a partially-completed install cannot be observed on-chain at all.

---

## [PROXY-2] `MAJORITY_VOTING_BASE_INTERFACE_ID` is computed from a selector for a function that does not exist on the contract
**Severity**: Low
**Category**: proxies
**Location**: `src/NFTVoting.sol:23-26` (`NFTVoting.MAJORITY_VOTING_BASE_INTERFACE_ID`), advertised via `NFTVoting.supportsInterface()` at `src/NFTVoting.sol:60-63`

**Description**:
The interface ID XORs seven real selectors with a hardcoded string hash:

```solidity
^ bytes4(keccak256("createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64,uint8,bool)"));
```

That signature (`0x9cba3021`) is the *upstream Aragon `MajorityVotingBase`* `createProposal`, which took trailing `VoteOption` and `tryEarlyExecution` parameters. This fork removed those parameters — the actual function is `createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64)` = `0x6e7fc2c3` (`src/base/Proposal.sol:252-258`). Confirmed against the compiled ABI:

```
| createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64) | 6e7fc2c3 |
| createProposal(bytes,(address,uint256,bytes)[],uint64,uint64,bytes)   | ea65ab82 |
```
`0x9cba3021` is absent from the method table.

The inline comment ("use keccak string due to 2 createProposal functions declared in the contract") explains *why* a literal string is used (overload ambiguity blocks `this.createProposal.selector`) but the string itself was copied from upstream without being updated to this fork's signature.

The degenerate-collision case the checklist asks about is **not** present: the resulting ID is `0x852402fb`, which is neither `0x00000000` nor `0xffffffff` nor any well-known interface ID (ERC-165 `0x01ffc9a7`, ERC-721 `0x80ac58cd`, etc.). So this is a correctness/integration bug, not a false-positive-detection vulnerability.

**Proof of Concept**:
Selector arithmetic (verified with `cast sig`):
```
minDuration()                                                      0x56715761
getVotingToken()                                                   0xe28c3b19
minProposerVotingPower()                                           0xf60046b2
votingMode()                                                       0x23d07188
totalVotingPower(uint256)                                          0x536f9f42
getProposal(uint256)                                               0xc7f758a8
updateVotingSettings((uint8,uint32,uint32,uint64,uint256,uint256)) 0xec2bae72
XOR of the seven above                                             0x199e32da
  ^ 0x9cba3021 (hardcoded, phantom)  ->  0x852402fb   <- what is actually advertised
  ^ 0x6e7fc2c3 (real createProposal) ->  0x77e1f019   <- what should be advertised
```

Scenario: an integrator (indexer, UI, router contract) performs ERC-165 detection, sees `supportsInterface(0x852402fb) == true`, and concludes the plugin implements the member set that ID encodes — which includes `createProposal(bytes,Action[],uint256,uint64,uint64,uint8,bool)`. Calling it reverts: `NFTVoting` has no fallback function. Conversely, an integrator that computes the ID correctly from this fork's actual ABI gets `0x77e1f019` and `supportsInterface` returns `false`, so a correctly-built integration fails to detect the plugin at all.

**Recommendation**:
Update the hardcoded signature to the function that actually exists:

```solidity
bytes4 internal constant MAJORITY_VOTING_BASE_INTERFACE_ID = this.minDuration.selector
    ^ this.getVotingToken.selector ^ this.minProposerVotingPower.selector ^ this.votingMode.selector
    ^ this.totalVotingPower.selector ^ this.getProposal.selector ^ this.updateVotingSettings.selector
    ^ bytes4(keccak256("createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64)"));
```

and add a regression test pinning the value so the constant cannot silently drift from the ABI again:

```solidity
function test_interfaceIdMatchesAbi() public view {
    bytes4 expected = NFTVoting.minDuration.selector ^ NFTVoting.getVotingToken.selector
        ^ NFTVoting.minProposerVotingPower.selector ^ NFTVoting.votingMode.selector
        ^ NFTVoting.totalVotingPower.selector ^ NFTVoting.getProposal.selector
        ^ NFTVoting.updateVotingSettings.selector
        ^ bytes4(keccak256("createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64)"));
    assertTrue(plugin.supportsInterface(expected));
}
```

If instead the intent was to stay wire-compatible with upstream Aragon's `MAJORITY_VOTING_BASE_INTERFACE_ID`, note that the constant already diverges from upstream anyway (this fork adds `getVotingToken` to the XOR and changed the `VotingSettings` struct with `minApprovals`), so compatibility is not preserved either way — document the intent explicitly in a comment.

---

## [PROXY-3] No storage gaps in `Settings` / `Proposal` / `Votes`
**Severity**: Info
**Category**: proxies
**Location**: `src/base/Settings.sol:26`, `src/base/Proposal.sol:18`, `src/base/Votes.sol:13`

**Description**:
None of the repo's abstract contracts reserve gap slots (`grep -rn "__gap" src/` returns nothing). The Aragon parents do: `DaoAuthorizableUpgradeable` and `ProposalUpgradeable` each declare `uint256[49] __gap`, and `MetadataExtensionUpgradeable` sidesteps the issue entirely with ERC-7201 namespaced storage. Verified layout via `forge inspect`:

```
slot 0    _initialized / _initializing   (Initializable)
slot 1    __gap[50]                      (ContextUpgradeable)
slot 51   __gap[50]                      (ERC165Upgradeable)
slot 101  dao_                           (DaoAuthorizableUpgradeable)
slot 102  __gap[49]                      (DaoAuthorizableUpgradeable)
slot 151  currentTargetConfig            (PluginCloneable)          <- no trailing gap (upstream)
slot 152  proposalCounter                (ProposalUpgradeable)
slot 153  __gap[49]                      (ProposalUpgradeable)
slot 202  votingSettings                 (Settings)                 <- no gap
slot 205  votingToken / tokenIndexedByTimestamp (Settings)
slot 206  proposals                      (Proposal)                 <- no gap
```

This is **not currently exploitable**. `NFTVoting` extends `PluginCloneable`, which is explicitly non-upgradeable ("An abstract, non-upgradeable contract to inherit from when creating a plugin being deployed via the minimal clones pattern"). There is no `_authorizeUpgrade`, `upgradeTo`, `upgradeToAndCall` or `proxiableUUID` anywhere in `src/` or `script/` (searched and confirmed absent), and the install script bypasses `PluginSetupProcessor` entirely, so no in-place upgrade path exists — a new version means a fresh clone with fresh storage.

Recording it as latent risk for two reasons:
1. If the team later migrates to `PluginUUPSUpgradeable` (the standard Aragon choice for upgradeable plugins), the absence of a gap in `Settings` becomes live: adding one variable to `Settings` shifts `Proposal.proposals` from slot 206, corrupting every existing proposal in deployed instances.
2. `GovernanceERC721` is deployed with `new` here, but it inherits `Initializable` + `ERC721VotesUpgradeable` + `DaoAuthorizableUpgradeable` and exposes a `public initializer initialize`, so it is structurally clonable. A clone of a `GovernanceERC721` instance would have `_initialized == 0` (the constructor's `_disableInitializers()` only locks that one instance's storage), reintroducing PROXY-1's uninitialized-clone problem for the token. It also has no storage gaps of its own.

Separately, upstream `PluginCloneable` declares `currentTargetConfig` (slot 151) with no trailing gap. That is an osx-commons issue, out of this repo's control, and harmless for the clone pattern.

**Proof of Concept**:
No exploit today. Hypothetical: switch `Settings` to sit behind a UUPS proxy, ship v2 with `uint256 public quorumFloor;` added after `tokenIndexedByTimestamp`, upgrade. `proposals` moves from slot 206 to 207; every stored proposal's `parameters.snapshotTimepoint` reads as 0, so `_proposalExists` returns false for all of them and `canExecute`/`hasSucceeded` revert with `NonexistentProposal`, permanently bricking all in-flight governance.

**Recommendation**:
Cheap insurance, costs nothing today since no instance is deployed yet:

```solidity
// end of src/base/Settings.sol
uint256[47] private __gap;

// end of src/base/Proposal.sol
uint256[49] private __gap;

// end of src/base/Votes.sol
uint256[50] private __gap;
```

(`Settings` uses 47 because `votingSettings` occupies 3 slots and `votingToken`+`tokenIndexedByTimestamp` share one; adjust to whatever rounds each contract's block to 50.)

Additionally, add an explicit `@dev` note on `GovernanceERC721` stating it must only be deployed with `new` and never used as a clone/EIP-1167 implementation — the existing comment at `src/erc721/GovernanceERC721.sol:75-77` already says this, so just keep it in sync if the contract is ever reused.

---

## [PROXY-4] Confirmed safe: `NFTVoting`'s base implementation is locked against direct `initialize()` by `PluginCloneable`'s constructor
**Severity**: Info
**Category**: proxies
**Location**: `lib/osx-commons/contracts/src/plugin/PluginCloneable.sol:44-48`, consumed by `src/base/Settings.sol:26` -> `src/NFTVoting.sol:20`

**Description**:
This is the checklist's critical-investigation item. Ground truth, confirmed by reading the source and by a runtime test — **the base is protected, and `NFTVoting` needs no `_disableInitializers()` of its own.**

`PluginCloneable` (resolved by remapping `@aragon/osx-commons-contracts/` -> `lib/osx-commons/contracts/`) declares:

```solidity
/// @notice Disables the initializers on the implementation contract to prevent it from being left uninitialized.
/// @custom:oz-upgrades-unsafe-allow constructor
constructor() {
    _disableInitializers();
}
```

`NFTVoting` declares no constructor of its own (`grep -rn "constructor" src/` matches only `GovernanceERC721`), so `new NFTVoting()` in `InstallNFTVotingScript._deployPlugin` runs `PluginCloneable`'s constructor, which sets `_initialized = type(uint8).max` in the base's own storage (OZ `Initializable.sol:145-151`). `nftVotingBase` is therefore permanently uninitializable. Clones are unaffected because they get fresh storage with `_initialized == 0`.

**Proof of Concept**:
Confirming test (passed):
```solidity
function test_baseImplementationIsLocked() public {
    NFTVoting base = new NFTVoting();
    vm.expectRevert("Initializable: contract is already initialized");
    base.initialize(IDAO(address(0xBEEF)), _settings(), tok,
        IPlugin.TargetConfig({target: address(0xBEEF), operation: IPlugin.Operation.Call}), "");
}
// Q1 RESULT: base implementation IS locked by PluginCloneable constructor
// [PASS] test_baseImplementationIsLocked()
```

Defense in depth is also present even if the lock were absent: the base's `dao_` would be `address(0)`, so every `auth(...)`-gated function would revert when decoding the return of a `hasPermission` staticcall to a codeless address.

**Recommendation**:
No change required. Consider adding the above test to the suite as a regression guard, so a future switch of base class (e.g. to a contract without a locking constructor) is caught immediately.

---

## [PROXY-5] Confirmed safe: no UUPS surface, no CREATE2/metamorphic exposure, all OZ imports are upgradeable variants
**Severity**: Info
**Category**: proxies
**Location**: `src/`, `script/InstallNFTVoting.s.sol`, `foundry.toml`

**Description**:
Remaining checklist items, each searched and confirmed rather than assumed:

- **No upgrade function exists.** `grep -rn "_authorizeUpgrade\|upgradeToAndCall\|upgradeTo\|proxiableUUID\|UUPSUpgradeable\|PluginUUPSUpgradeable" src/ script/` -> no matches. The UUPS-only checklist items are genuinely N/A. `ProxyLib.deployUUPSProxy` exists in the library but is never called by this repo.
- **No constructor state in the proxy implementation.** `NFTVoting` has no constructor; all state setup happens in `initialize()` (`__PluginCloneable_init`, `_updateVotingSettings`, `_updateVotingToken`, `_setTargetConfig`, `_setMetadata`). Every parent is an upgradeable-safe variant with `__X_init()` functions: `PluginCloneable.__PluginCloneable_init`, `DaoAuthorizableUpgradeable.__DaoAuthorizableUpgradeable_init`, `ProposalUpgradeable`, `MetadataExtensionUpgradeable` (ERC-7201). `PluginCloneable`'s only constructor body is `_disableInitializers()` — it sets no shared state that a clone would miss.
- **All OZ imports are the `Upgradeable` variants.** `grep -rn "@openzeppelin/contracts/" src/` -> no matches; every import goes through `@openzeppelin/contracts-upgradeable/`. Confirmed: `IVotesUpgradeable`, `IERC721Upgradeable`, `IERC165Upgradeable`, `IERC6372Upgradeable`, `SafeCastUpgradeable`, `ERC721Upgradeable`, `ERC721VotesUpgradeable`, `ERC165Upgradeable`, `Initializable`.
- **No CREATE2 / metamorphic exposure.** `grep -rn "create2\|CREATE2\|cloneDeterministic\|selfdestruct\|salt" src/ script/` -> no matches. `ProxyLib.deployMinimalProxy` uses `Clones.clone` (plain `CREATE`, nonce-derived), not `cloneDeterministic`. No contract in scope contains `selfdestruct`, so the commented alternative `evm_version` values in `foundry.toml` (`shanghai` for Chiliz, `london` for Peaq — where pre-EIP-6780 `selfdestruct` semantics still apply) create no metamorphic-redeploy risk here. Note this does *not* mitigate PROXY-1: front-running the clone's `initialize()` requires no address prediction at all, since the attacker simply observes the clone-CREATE (or the pending `initialize` calldata) on-chain.
- **`supportsInterface` does not return true for `0xffffffff`.** None of the ORed conditions in `NFTVoting.supportsInterface` / `Settings.supportsInterface` evaluates to `0xffffffff`, and `ERC165Upgradeable` returns false for it, so ERC-165 compliance holds. (The separate ID-value issue is PROXY-2.)
- **`GovernanceERC721`'s `_disableInitializers()` ordering is correct** (already fixed per git log; re-verified). `constructor` calls `initialize()` (which sets `_initialized = 1` and leaves `_initializing == false` on exit) and then `_disableInitializers()`, whose only precondition is `!_initializing` — satisfied. Storage ends at `_initialized == 255`.

**Proof of Concept**: N/A — these are confirmations of absence/correctness.

**Recommendation**: No change required. If the plugin is ever ported to `PluginUUPSUpgradeable`, revisit PROXY-3 (storage gaps) and the UUPS-specific checklist items at that time.
