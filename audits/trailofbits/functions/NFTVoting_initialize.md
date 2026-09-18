## `initialize` in src/NFTVoting.sol (L41-55)

```solidity
// L41-55
function initialize(
    IDAO _dao,
    VotingSettings calldata _votingSettings,
    IVotesUpgradeable _token,
    TargetConfig calldata _targetConfig,
    bytes calldata _pluginMetadata
) external initializer {
    __PluginCloneable_init(_dao);
    _updateVotingSettings(_votingSettings);
    _updateVotingToken(_token);
    _setTargetConfig(_targetConfig);
    _setMetadata(_pluginMetadata);

    emit MembershipContractAnnounced({definingContract: address(_token)});
}
```

**Purpose:** One-shot constructor-equivalent for an EIP-1167 minimal-proxy clone of `NFTVoting`. It wires the clone to its governing DAO, and sets the four pieces of mutable configuration state (`votingSettings`, `votingToken`/`tokenIndexedByTimestamp`, `currentTargetConfig`, plugin metadata) that every other function in `Settings`/`Proposal`/`Votes` reads. Nothing else in the contract writes `dao_`, so if this function is skipped, never succeeds, or is hijacked, every `auth()`-gated function is permanently unusable or usable by the wrong DAO, and `createProposal`/`vote`/`execute` all read zeroed or attacker-chosen configuration.

**Inputs & Assumptions:**
- `_dao` (`IDAO`): the DAO that will own this plugin instance. Trust: **trusted by construction of the calling script**, but **nothing in `initialize` or in `__DaoAuthorizableUpgradeable_init` (L22-24 of `DaoAuthorizableUpgradeable.sol`) validates it** — not checked non-zero, not checked to be a contract, not checked to implement `IDAO`. It is stored verbatim into `dao_` and becomes the sole source of truth for every `auth()` check thereafter (`DaoAuthorizableUpgradeable.sol` L34-37).
- `_votingSettings` (`VotingSettings calldata`): fully attacker/deployer-supplied struct. Trust: **untrusted input, validated by the callee** — see `_updateVotingSettings` below; validation is real but incomplete during initialization (see Block-by-Block, L49).
- `_token` (`IVotesUpgradeable`): the ERC-721 voting token. Trust: **semi-trusted external contract** — validated via two external `ERC165Upgradeable.supportsInterface` calls inside `_updateVotingToken` (Settings.sol L196, L201), which can themselves revert or behave adversarially (see Cross-Function Dependencies).
- `_targetConfig` (`TargetConfig calldata`): execution target + operation. Trust: untrusted input, partially validated by `_setTargetConfig` (Settings.sol L184-190).
- `_pluginMetadata` (`bytes calldata`): opaque, unvalidated.
- Implicit: `msg.sender` is **not checked anywhere in this function** — `initialize` carries no `auth` modifier, only `initializer`. Anyone who can reach an un-initialized clone before the legitimate installer does could call it. Whether that window exists is a property of the *caller*, not of this function — see Cross-Function Dependencies / Open Questions.
- Implicit: `block.timestamp` is read indirectly, once, inside `_detectTokenClock` (via `_updateVotingToken`) to classify the token's clock mode; this classification is never repeated automatically.
- Precondition: this is the **first and only** successful call for this clone's storage. Established by the OZ `initializer` modifier (`Initializable.sol` L84-99) operating on this clone's own `_initialized`/`_initializing` storage slots, which are guaranteed fresh (zero) for a newly created EIP-1167 clone because clone bytecode never runs the implementation's constructor — see Block-by-Block, L47.
- Precondition: the *implementation* contract (the one holding the constructor-run `_disableInitializers()`) can never itself be initialized this way. Established by `PluginCloneable`'s constructor (`PluginCloneable.sol` L46-48), which only executes when the implementation is deployed via `new NFTVoting()`/`new PluginCloneable()`-style creation (confirmed at `script/InstallNFTVoting.s.sol` L177), not when a clone is created via `Clones.clone()`.

**Outputs & Effects:**
- No return value.
- State writes (all clone-local storage, in order): `dao_` (via `__DaoAuthorizableUpgradeable_init`, `DaoAuthorizableUpgradeable.sol` L23); `votingSettings` (`Settings.sol` L162); `votingToken` and `tokenIndexedByTimestamp` (`Settings.sol` L205, L214-220); `currentTargetConfig` (`PluginCloneable.sol` L115, reached via `Settings._setTargetConfig` → `super._setTargetConfig`); the metadata custom storage slot `MetadataExtensionStorageLocation` (`MetadataExtensionUpgradeable.sol` L67-68); and `Initializable`'s own `_initialized`/`_initializing` flags (`Initializable.sol` L90-97).
- Events: `Initialized(1)` (from the `initializer` modifier, `Initializable.sol` L97), `VotingSettingsUpdated` (`Settings.sol` L164-172), `VotingTokenUpdated` (`Settings.sol` L209), `TargetSet` (`PluginCloneable.sol` L117), `MetadataSet` (`MetadataExtensionUpgradeable.sol` L70), `MembershipContractAnnounced` (L54, from `IMembership`).
- External interactions: two `supportsInterface` calls to `_token` (`Settings.sol` L196, L201, raw `IERC165Upgradeable` calls — not wrapped in try/catch, so a token that reverts on an unknown selector, or a plain EOA/no-code address, reverts the whole `initialize` call); one try/catch `clock()` call to `_token` (`Settings.sol` L215-220, exception-safe by design); one `ERC165CheckerUpgradeable.supportsInterface` staticcall against `_targetConfig.target` inside `super._setTargetConfig` (`PluginCloneable.sol` L109, exception-safe by design of `ERC165CheckerUpgradeable`).
- Postcondition on success: the clone is fully configured and `_initialized == 1`, so no code path in this contract (nor in any of its bases, since `_initialized` is a single shared flag) can re-enter `initializer`-guarded logic again; `reinitializer` is never used in this hierarchy, so there is no supported "step 2" of initialization.

**Block-by-Block:**

```solidity
// L47
) external initializer {
```
- **What:** Guards the whole function body with OZ's single-shot initializer semantics.
- **Why here:** Must wrap the entire body since every internal `__*_init`/`_update*` call below is `onlyInitializing` and would otherwise revert if called outside an active `initializer`/`reinitializer` context.
- **Assumes:** the clone's `_initialized` storage is `0` and `_initializing` is `false` on entry. For a genuine EIP-1167 clone this holds because clone bytecode is a delegatecall trampoline with no constructor of its own — the implementation's constructor (which calls `_disableInitializers()`, `PluginCloneable.sol` L47) only ever executes in the implementation's own storage context at `new NFTVoting()` time, never in the clone's.
- **Establishes:** `_initialized = 1` for the *entire* inheritance chain (single flag), and, for the duration of this call, `_initializing = true`, which every `onlyInitializing` callee below depends on.
- **Depended on by:** L48-52 (all four setup calls), and by every future call to any function guarded by `initializer`/`reinitializer` in this hierarchy (there are none besides this one function, so effectively this makes the clone permanently non-re-initializable).

```solidity
// L48
__PluginCloneable_init(_dao);
```
- **What:** Stores `_dao` as the plugin's authorizing DAO.
- **Why here:** Must run first — `auth()` isn't used later in this function, but `_setTargetConfig`'s base implementation and `getTargetConfig()` (used later, e.g., in `createProposal`) depend on `dao()` being set; more importantly every subsequent call to any `auth`-gated public wrapper (`updateVotingSettings`, `updateVotingToken`, `setTargetConfig`, `setMetadata`) after `initialize` returns needs `dao_` populated.
- **Assumes:** `_dao` is a real, honest `IDAO` implementation. **Nothing in this call enforces that** — `__DaoAuthorizableUpgradeable_init` (`DaoAuthorizableUpgradeable.sol` L22-24) does an unconditional assignment with no zero-address or code-existence check.
- **Establishes:** `dao()` returns `_dao` for the remaining lifetime of the clone (no setter exists to change it later — grep confirms `dao_` is written only here).
- **Depended on by:** every `auth(...)` modifier invocation anywhere in the contract (`Settings.sol` L112, L178; `MetadataExtensionUpgradeable.sol` L53; `PluginCloneable.sol` L62; `Proposal.sol` L277); by `getTargetConfig()`'s DAO fallback (`PluginCloneable.sol` L83).

```solidity
// L49
_updateVotingSettings(_votingSettings);
```
- **What:** Validates and stores the full `VotingSettings` struct.
- **Why here:** Runs before `_updateVotingToken` — this ordering matters (see "Assumes" below).
- **Assumes:** Four independent range checks hold on the input (`Settings.sol` L122-144: `supportThreshold ∈ [1, RATIO_BASE-1]`; `minParticipation ∈ [1, 900_000]`; `minDuration ≥ 60 minutes` and `≤ maxBoundDate`; `minApprovals ∈ [1, 900_000]`) — all enforced here, all revert on violation.
- **Establishes / does not establish:** `votingSettings.maxBoundDate != 0` is used at `Settings.sol` L147 as a proxy for "is this the first-ever call (initialize) or a later update". Because storage is zero before this call, that branch (L147-160, which bounds `minProposerVotingPower` against `totalVotingPower(snapshotTimepoint)`) is **skipped during `initialize`**. Even if it weren't skipped, `votingToken` is still the zero address at this point (`_updateVotingToken` hasn't run yet — L50), so `totalVotingPower()` (`Settings.sol` L72-74) would call `getPastTotalSupply` on the zero address. **Net effect: `_votingSettings.minProposerVotingPower` is accepted at initialize time with no upper bound check against actual token supply**, unlike every subsequent call to `updateVotingSettings`. This is a real behavioral difference between init-time and update-time paths, not merely a documentation gap.
- **Depended on by:** `_updateVotingToken`'s ordering assumption above; every read of `votingSettings.*` afterward (`votingMode()`, `supportThreshold()`, etc., and `_validateProposalDates`, `Proposal.sol` L388-431).

```solidity
// L50
_updateVotingToken(_token);
```
- **What:** ERC165-validates `_token` as ERC-721 and `IVotesUpgradeable`, stores it, and detects its clock mode.
- **Why here:** Must run after `_updateVotingSettings` given the ordering dependency noted above; must run before `_setTargetConfig`/`_setMetadata` only in the sense that L54's `emit MembershipContractAnnounced` uses the same `_token` value (not the stored one, so this ordering is not strictly required for L54's correctness, but it is required for `getVotingToken()`/`totalVotingPower()` to work post-initialization).
- **Assumes:** `_token` correctly answers `supportsInterface` for both `IERC721Upgradeable` and `IVotesUpgradeable` without reverting; if `_token` is a plain EOA or a contract without a fallback/`supportsInterface`, the whole `initialize` reverts (unlike `_setTargetConfig`'s target check, which uses the exception-safe `ERC165CheckerUpgradeable`).
- **Establishes:** `votingToken == _token` and a fixed classification `tokenIndexedByTimestamp` based on a *single* call to `_token.clock()` at this exact block (`Settings.sol` L215-220, `_detectTokenClock`). If `_token.clock()` reverts, `tokenIndexedByTimestamp` defaults to `false` (block-number mode) — this is a silent fallback, not a distinguishable "unknown" state.
- **Depended on by:** every snapshot-timepoint computation downstream (`canCreateProposal`, `createProposal`, `_updateVotingSettings`'s later-call branch) which all trust `tokenIndexedByTimestamp` set here and never re-derive it unless `updateVotingToken` is called again.

```solidity
// L51
_setTargetConfig(_targetConfig);
```
- **What:** Validates and stores the execution target/operation.
- **Why here:** No hard ordering dependency on the previous two calls; grouped with the rest of one-time setup.
- **Assumes:** virtual dispatch resolves to `Settings._setTargetConfig` (`Settings.sol` L184-190), the only override in the chain, which unconditionally rejects `Operation.DelegateCall` regardless of target — strictly tighter than the base `PluginCloneable._setTargetConfig` (`PluginCloneable.sol` L105-118), which only rejects `DelegateCall` when the target itself answers `true` to `IDAO`'s interface ID. The base check becomes unreachable dead logic when called through this override, since `Settings` already reverts on any `DelegateCall` before `super._setTargetConfig` runs.
- **Assumes:** no explicit non-zero check on `_targetConfig.target`; a `Call`-operation `TargetConfig` with `target == address(0)` is accepted and stored, but `getTargetConfig()` (`PluginCloneable.sol` L79-87) treats a zero target as "unset" and substitutes `dao()` — so the zero-target case degrades gracefully rather than bricking proposal execution.
- **Establishes:** `currentTargetConfig` for later `getTargetConfig()`/`_execute()` calls (`Proposal.sol` L322, L59-70).

```solidity
// L52
_setMetadata(_pluginMetadata);
```
- **What:** Writes `_pluginMetadata` into the dedicated ERC-7201-style storage slot used by `MetadataExtensionUpgradeable`.
- **Why here:** No dependency on the other three calls; placed last among the setup steps for no functionally required reason.
- **Assumes:** nothing about the content of `_pluginMetadata` — empty bytes are accepted.
- **Establishes:** `getMetadata()` returns `_pluginMetadata` thereafter.

```solidity
// L54
emit MembershipContractAnnounced({definingContract: address(_token)});
```
- **What:** Announces the token contract that defines membership, per `IMembership`.
- **Why here:** Placed after all storage writes so the event reflects a fully-initialized clone; reads the function parameter `_token` directly rather than the just-written `votingToken` storage — equivalent in value on this path since `_updateVotingToken` did not revert, but worth noting the emitted value is not re-derived from storage.
- **Assumes:** `_updateVotingToken` succeeded (otherwise execution never reaches here).
- **Establishes:** an off-chain-indexable record of which token address defines membership for this plugin instance at deployment time.

**Cross-Function Dependencies:**

- **Callee `__PluginCloneable_init` → `__DaoAuthorizableUpgradeable_init`** (internal, `DaoAuthorizableUpgradeable.sol` L22-24): single unconditional path, `dao_ = _dao`. No branch, no validation of `_dao`. `initialize` depends on this to establish the authorization root for the whole contract; it is established **unconditionally and without any sanity check** — an unenforced assumption that `_dao` is a genuine DAO, resting entirely on whoever encodes the `initialize` calldata (in this repo, `script/InstallNFTVoting.s.sol` L182-185, which always passes the actual DAO's address).
- **Callee `_updateVotingSettings`** (internal, `Settings.sol` L119-173): read in full, four validated paths and one conditional path.
  - The four range checks (L122-144) always run and always revert on violation — no path skips them.
  - The `votingSettings.maxBoundDate != 0` branch (L147-160) is the "already initialized" guard; on the `initialize` call path it is always false (fresh storage), so `_votingSettings.minProposerVotingPower` is stored **without being checked against the token's total voting power** on this path only. `initialize` implicitly relies on this being acceptable (i.e., that an over-large `minProposerVotingPower` at genesis is a governance decision that later self-corrects only if `updateVotingSettings` is called again, since `createProposal`'s own gate is `canCreateProposal` → `minProposerVotingPower()` compared directly, not re-validated against supply).
- **Callee `_updateVotingToken`** (internal, `Settings.sol` L194-210): read in full.
  - Two `require` calls (L195-198, L200-203) are plain external calls to `IERC165Upgradeable(address(_token)).supportsInterface(...)` — not wrapped in `ERC165CheckerUpgradeable`'s try/catch/staticcall pattern used elsewhere in the same file's `_setTargetConfig` base logic. A token contract that reverts on an unrecognized selector, or an address with no code, causes `initialize` to revert entirely rather than being rejected gracefully.
  - `_detectTokenClock` (private, L214-221): two paths — `clock()` succeeds and its return is compared to `block.timestamp` (L216); `clock()` reverts and the mode defaults to block-number-indexed (L217-219, `catch` branch swallows the revert reason entirely). Both paths always assign `tokenIndexedByTimestamp` — no path leaves it unset — but the classification is a one-time snapshot; nothing re-runs it automatically if the token's own clock semantics could differ across calls or if a later `updateVotingToken` call installs the same value again without re-detecting (it does re-detect, since `_detectTokenClock` is called every time `_updateVotingToken` runs — only the initial one-time nature within a *single* token's lifetime is the assumption).
  - Both external calls happen while `_initializing == true` (the `initializer` modifier's guard) but **before** `currentTargetConfig` and plugin metadata are set, and in particular **before `votingToken` itself is durably in its final state relative to any reentry that occurs before L205 executes**. If `_token.supportsInterface` reentered the plugin (e.g., called back into a public function on this same clone), reentry into `initialize` itself is blocked (the `initializer` modifier's `isTopLevelCall`/`_initializing` check, `Initializable.sol` L85-89, forces a revert for any nested top-level `initializer` call on a contract with code). Reentry into other public functions (e.g., `updateVotingSettings`, `vote`, `createProposal`) is **not blocked by `_initializing`** — those functions have no `initializer`/`onlyInitializing` guard — but at this point in execution `dao_` is already set (L48 ran first) while no `auth`-gated caller has yet been granted any permission on this plugin (permission grants happen in a separate DAO action batch *after* `_deployPlugin` returns, per `script/InstallNFTVoting.s.sol` L126-129), so an `auth()`-gated reentrant call would need `_auth` to already return true for the reentrant `msg.sender` (the token contract), which nothing at this point grants.
- **Callee `_setTargetConfig`** (internal, virtual, two-contract chain): `Settings._setTargetConfig` (`Settings.sol` L184-190) always runs first via virtual dispatch, single unconditional revert-or-continue branch on `Operation.DelegateCall`, then calls `super._setTargetConfig` (`PluginCloneable.sol` L105-118), whose own `DelegateCall`-to-`IDAO`-target check can never fire when reached through `Settings`'s override (already filtered upstream) — the check at `PluginCloneable.sol` L108-113 is live only for callers that reach `PluginCloneable._setTargetConfig` directly, which is not a path `initialize` uses (virtual dispatch always picks the most-derived override).
- **Callee `_setMetadata`** (internal, `MetadataExtensionUpgradeable.sol` L66-71): single path, unconditional write, no failure mode.
- **Callers:** The only caller found in this repo is `InstallNFTVotingScript._deployPlugin` (`script/InstallNFTVoting.s.sol` L177-186), which deploys the implementation via `new NFTVoting()` (triggering `PluginCloneable`'s `_disableInitializers()` on the implementation's own storage), then calls `ProxyFactory.deployMinimalProxy(initCalldata)` (`ProxyFactory.sol` L39-42), which internally calls `ProxyLib.deployMinimalProxy` (`ProxyLib.sol` L34-42): `Clones.clone()` followed immediately by `functionCall` with the `initialize` calldata, **both inside the same external call/transaction**, so no other transaction can observe or call the freshly created, not-yet-initialized clone in between. This specific caller therefore establishes atomic clone-creation-plus-initialization, closing the general "front-run an uninitialized clone's `initialize`" class of concern for *this* deployment path. `initialize` itself carries no `auth` modifier and no `msg.sender` check, so this guarantee is entirely external to the function and holds only as long as every real deployment path mirrors this script's atomic sequencing.
- **Shared state:** `dao_` is shared with every `auth`-gated function in `Settings`, `MetadataExtensionUpgradeable`, and `PluginCloneable`. `votingSettings`/`votingToken`/`tokenIndexedByTimestamp` are shared with `updateVotingSettings`, `updateVotingToken`, `totalVotingPower`, `canCreateProposal`, `createProposal`, `_vote`/`_canVote`, `isMember`. `currentTargetConfig` is shared with `setTargetConfig`, `getTargetConfig`, `_execute`. The metadata slot is shared with `setMetadata`/`getMetadata`.
- **Invariant coupling:** The contract-wide invariant "every `auth`-gated call is authorized by the real DAO" depends transitively on `_dao` being correct at L48 — nothing downstream re-validates it. The invariant "`minProposerVotingPower` never exceeds current total voting power" (enforced by `_updateVotingSettings`'s L147-160 branch) is **not** part of the initialization-time invariant set — it only becomes enforced starting with the *second* call to `_updateVotingSettings`.

**Open Questions:**
- unclear; need to inspect whether any deployment path other than `script/InstallNFTVoting.s.sol` exists or is planned (e.g., a future `NFTVotingSetup` implementing `IPluginSetup` for use with Aragon's `PluginSetupProcessor`). No such contract exists under `src/` in this repo; if one is added later, its `prepareInstallation` must reproduce the same clone-then-initialize atomicity that `ProxyLib.deployMinimalProxy` provides, or the "no front-running an uninitialized clone" property this analysis relies on for the *current* script would not automatically extend to it.
- unclear; need to inspect `GovernanceERC721`'s actual `supportsInterface`/`clock` implementation (declared in `src/erc721/GovernanceERC721.sol`, not read in this pass) to confirm it never reverts on an unrecognized `supportsInterface` query and that its `clock()` (if any) is stable, since `_updateVotingToken`'s validation and clock-detection behavior at L50 is otherwise only analyzed against the interface contracts, not this repo's concrete token.
- unclear; need to inspect `DAO`'s `execute`/permission-manager semantics (`@aragon/osx` core, out of the stated scope for this pass) to confirm that no permission is implicitly available to an arbitrary reentrant caller during the window between L48 (`dao_` set) and the permission-granting action batch in `installOnExistingDao` (`script/InstallNFTVoting.s.sol` L128-129) — this analysis assumes `_auth` denies by default absent an explicit grant, but the grant/deny default lives in `DAO`/`PermissionManager` source not read here.
