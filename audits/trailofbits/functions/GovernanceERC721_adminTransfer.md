## `adminTransfer` in src/erc721/GovernanceERC721.sol (L143-146)

```solidity
function adminTransfer(address _from, address _to, uint256 _tokenId) external virtual auth(TRANSFER_PERMISSION_ID) {
    _transfer(_from, _to, _tokenId);
    emit AdminTransfer({from: _from, to: _to, tokenId: _tokenId});
}
```

**Purpose:** Lets whoever holds `TRANSFER_PERMISSION_ID` move a token between two arbitrary addresses without
the current holder's `approve`/`setApprovalForAll` consent. It reuses OZ's `_transfer` (the same internal used
by the permissionless `transferFrom`/`safeTransferFrom` paths) but skips the `_isApprovedOrOwner` gate that
`transferFrom` normally imposes (L155-159 of `ERC721Upgradeable.sol`), substituting a DAO-permission check for
a holder-consent check.

**Inputs & Assumptions:**
- `_from` (address): claimed current holder. Trust: **untrusted** — caller-supplied, not derived from
  on-chain state before use; `_transfer`'s own `require` (see below) is what ties it to reality.
- `_to` (address): recipient. Trust: **untrusted**, no `code.length`/receiver-interface check (unlike
  `_safeTransfer`/`_safeMint`); `adminTransfer` calls `_transfer` (L144), not `_safeTransfer`, so an
  `onERC721Received` callback is never invoked and a non-receiving contract can still receive the token.
- `_tokenId` (uint256): caller-supplied. Trust: untrusted.
- Implicit: `msg.sender` (used as `_who` in the permission check), `_msgData()` (forwarded to the DAO's
  `PermissionCondition`, if any, as `_data`), the DAO's permission-manager storage (external, see below).
- Precondition: caller holds `TRANSFER_PERMISSION_ID` on `address(this)` in the associated DAO. Established
  by the `auth` modifier (L143) calling into `_auth` (`lib/osx-commons/.../auth.sol:L24-38`), which reverts
  with `DaoUnauthorized` if `dao_.hasPermission(...)` returns false. Nothing in `GovernanceERC721.sol` grants
  or revokes this permission — see Cross-Function Dependencies.
- Precondition (unstated by this function, enforced downstream): `_from` actually owns `_tokenId` — enforced
  by `_transfer`'s first `require` (`ERC721Upgradeable.sol:L339`), not by `adminTransfer` itself.
- Precondition (unstated, enforced downstream): `_to != address(0)` — enforced by `_transfer`'s second
  `require` (`ERC721Upgradeable.sol:L340`).

**Outputs & Effects:**
- No return value.
- State writes (all inside `_transfer`, `ERC721Upgradeable.sol:L338-364`): clears `_tokenApprovals[_tokenId]`
  (L348), decrements `_balances[_from]` / increments `_balances[_to]` (L356-357), reassigns
  `_owners[_tokenId] = _to` (L359).
- Additional state write via the `ERC721Votes` hook chain (see Block-by-Block): moves voting units from
  `_from` to `_to` and, if `_to` has no delegate, sets `_to` as its own delegate.
- Events: OZ `Transfer(_from, _to, _tokenId)` from inside `_transfer` (L361), then this function's own
  `AdminTransfer(_from, _to, _tokenId)` (L145) — both are emitted for every successful call, giving an
  on-chain marker distinguishing a forced transfer from an ordinary one even though both share the same
  `Transfer` event shape.
- No external calls (no `onERC721Received` probe, since `_transfer` is used rather than `_safeTransfer`).
- Postcondition: `_to` owns `_tokenId`; any prior single-token `approve` on it is cleared (delegation of the
  ex-holder's other tokens, if any, is untouched — `_operatorApprovals` is per-owner/operator, not touched by
  `_transfer` at all).

**Block-by-Block:**

```solidity
// L143
function adminTransfer(address _from, address _to, uint256 _tokenId) external virtual auth(TRANSFER_PERMISSION_ID) {
```
- **What:** Gates the whole function behind a DAO permission check evaluated before the function body runs.
- **Why here:** Modifier runs first, so `_transfer`'s effects and the event never happen for an unauthorized
  caller.
- **Assumes:** `dao_` (set once in `__DaoAuthorizableUpgradeable_init`, `DaoAuthorizableUpgradeable.sol:L22-24`)
  is the correct, honest DAO contract; `_auth` trusts `dao_.hasPermission` implicitly (it's an external call
  with no further validation of the response beyond the boolean).
- **Establishes:** `msg.sender` held `TRANSFER_PERMISSION_ID` at the moment of the call (this is a point-in-time
  check with no re-check after, and no reentrancy guard exists on this function).
- **Depended on by:** the entire function body.

```solidity
// L144
_transfer(_from, _to, _tokenId);
```
- **What:** Delegates the entire authority/ownership check and storage mutation to OZ's internal transfer
  primitive.
- **Why here:** Reuses vetted OZ logic instead of reimplementing ownership bookkeeping.
- **Assumes:** `_transfer` will validate `_from`'s ownership and reject `_to == address(0)`; `adminTransfer`
  performs none of these checks itself.
- **Establishes:** on successful return, `_to` is the new owner of `_tokenId`, approvals are cleared, voting
  units have moved, and (per `_afterTokenTransfer` at L169) `_to` is self-delegated if it had no delegate.
- **Depended on by:** the `AdminTransfer` event at L145, which fires only if this line does not revert, and by
  every downstream reader of `ownerOf`/`getVotes`.

```solidity
// L145
emit AdminTransfer({from: _from, to: _to, tokenId: _tokenId});
```
- **What:** Emits a bespoke event for this force-transfer path, in addition to OZ's `Transfer` already emitted
  inside `_transfer`.
- **Why here:** Only reached after `_transfer` succeeds, so it double-confirms (redundantly with `Transfer`)
  the values that were actually applied — except it re-uses the caller-supplied `_from`/`_to` rather than
  reading them back from storage; since `_transfer` already asserted `ownerOf(_tokenId) == _from` before
  mutating state, `_from` in the event is guaranteed accurate at that point, but note the event's `_from`
  variable is the same one passed in, not independently re-derived.
- **Assumes:** nothing beyond L144 having succeeded.
- **Establishes:** an audit trail distinguishing admin-forced transfers from consensual ones.
- **Depended on by:** off-chain indexers/monitoring that want to flag forced transfers specifically.

**Cross-Function Dependencies:**

- **Callee `_auth` (internal free function, `lib/osx-commons/contracts/src/permission/auth/auth.sol:L24-38`),
  reached via the `auth` modifier (`DaoAuthorizableUpgradeable.sol:L34-37`):** read in full. It has exactly one
  path: call `_dao.hasPermission(_where, _who, _permissionId, _data)` and revert with `DaoUnauthorized` if
  false; otherwise return silently. `hasPermission` is an **external call to the DAO contract** — this file
  has no visibility into how that answer is computed. Following it into
  `lib/osx/packages/contracts/src/core/permission/PermissionManager.sol` (`isGranted`, L224, and the
  permission-check helper at L477) shows the answer depends on that contract's own storage — direct grants
  keyed by `(where, who, permissionId)` and optionally a `PermissionCondition` contract's `isGranted` call
  (L321) — none of which `GovernanceERC721` reads, writes, or can observe. Nothing in
  `GovernanceERC721.sol` decides who holds `TRANSFER_PERMISSION_ID`/`MINT_PERMISSION_ID`/`BURN_PERMISSION_ID`;
  that is entirely external DAO/permission-manager state, granted/revoked through the DAO's own
  `grant`/`revoke`/`grantWithCondition` machinery, out of this contract's scope.
- **Callee `_transfer` (internal, OZ, `ERC721Upgradeable.sol:L338-364`):** read in full, both the success path
  and the reverting paths.
  - `require(ERC721Upgradeable.ownerOf(tokenId) == from, ...)` (L339): calls the public `ownerOf`
    (`ERC721Upgradeable.sol:L75-79`), which itself `require`s the token exists (L77, `"ERC721: invalid token
    ID"`) before returning an owner. So for a non-existent `_tokenId`, `adminTransfer` reverts inside
    `ownerOf` with `"ERC721: invalid token ID"`, never reaching the "incorrect owner" message — i.e.
    `adminTransfer` **cannot** be used to conjure a transfer of a token that was never minted or has been
    burned; it also **cannot** move a token away from someone who isn't its current owner, even holding
    `TRANSFER_PERMISSION_ID` — the caller's assertion of `_from` is independently verified, not trusted.
  - `require(to != address(0), ...)` (L340): still enforced, so `adminTransfer(_from, address(0), _tokenId)`
    reverts — `adminTransfer` cannot be used as a substitute for `burn`; a genuine burn still requires
    `BURN_PERMISSION_ID` via the sibling `burn` function.
  - `_beforeTokenTransfer(from, to, tokenId, 1)` (L342) followed by a **re-check** of
    `ownerOf(tokenId) == from` (L345): OZ defends against the hook itself moving the token, which matters
    only if `_beforeTokenTransfer` is overridden to do so; in this contract's inheritance chain
    `_beforeTokenTransfer` is never overridden (only `_afterTokenTransfer` is, at L161-172), so this hook is
    the OZ no-op (`ERC721Upgradeable.sol:L442`) and the re-check is inert here, not a live defense.
  - Approval clearing (`delete _tokenApprovals[tokenId]`, L348) happens unconditionally — this is exactly the
    per-token approval a holder had granted (or withheld) becoming irrelevant to whether the DAO can move the
    token; `adminTransfer` never consults `_tokenApprovals` or `_operatorApprovals` at all, which is the
    concrete mechanism by which holder approval is bypassed (contrast with `transferFrom`'s
    `_isApprovedOrOwner` gate at `ERC721Upgradeable.sol:L157`, never invoked on this path).
  - Balance/owner bookkeeping (L356-359) and `emit Transfer` (L361) run unconditionally once the two
    `require`s above pass.
  - `_afterTokenTransfer(from, to, tokenId, 1)` (L363) — dispatches into the override chain analyzed next.
- **Callee `_afterTokenTransfer` override chain**, triggered identically for `adminTransfer`, `mint`'s
  `_mintTo`→`_mint`, and `burn`:
  - `ERC721VotesUpgradeable._afterTokenTransfer` (`extensions/ERC721VotesUpgradeable.sol:L31-39`, read in
    full): calls `_transferVotingUnits(from, to, batchSize)` then `super._afterTokenTransfer(...)`. This is
    the standard `Votes` checkpointing — it runs for every path through `_transfer`/`_mint`/`_burn`
    unconditionally, no branch skips it.
  - `GovernanceERC721._afterTokenTransfer` (L161-172, this file, overriding the same slot): calls `super.
    _afterTokenTransfer` first (L166 — i.e. votes are moved *before* the self-delegation check, so
    `_getVotingUnits`/balance used inside vote-moving reflects the post-`_transfer` balances since
    `_balances`/`_owners` were already updated at L356-359/L305-320/L283-286 before `_afterTokenTransfer` is
    invoked), then, only if `to != address(0)` (L169) and `delegates(to) == address(0)` (L169), self-delegates
    `to`. For `adminTransfer` this means: **yes, the same auto-self-delegation fires as for an ordinary
    transfer** — a forced-transfer recipient with no prior delegate is auto-delegated to themself exactly as a
    normal `transferFrom` recipient would be, re-deriving independently of any comment in the sibling
    functions. For `burn`, `to == address(0)` so this branch is skipped (consistent with there being no
    recipient to delegate). The self-delegation condition depends only on `delegates(to)`, not on how `to`
    came to hold the token, so `adminTransfer` cannot distinguish itself from `transferFrom` at this layer.
- **Callers:** none found in-repo — `adminTransfer` is presumably invoked directly by whatever address the DAO
  grants `TRANSFER_PERMISSION_ID` to (e.g. a DAO proposal executor or a designated admin plugin), not by
  another function in this contract or elsewhere in `src/`. No caller-side precondition to record beyond what
  `auth` itself checks.
- **Shared state:** `_owners`, `_balances`, `_tokenApprovals` (OZ storage) shared with `mint`
  (`_mintTo`→`_mint`, L126-128/151-156), `burn` (L133-135), and the public `transferFrom`/`safeTransferFrom`
  (not overridden in this contract, so still permissionless subject to `_isApprovedOrOwner`). Voting
  checkpoints (`Votes` storage) and delegate mappings are shared across the same set plus `delegate`/
  `delegateBySig` (inherited, unmodified).
- **Invariant coupling:** `mint` (L126-128) requires `MINT_PERMISSION_ID` and calls `_mintTo`→`_mint`, which
  enforces `to != address(0)` and `!_exists(tokenId)` (`ERC721Upgradeable.sol:L270-271`) — mirrors
  `adminTransfer`'s reliance on OZ's own require statements rather than contract-specific checks. `burn`
  (L133-135) requires `BURN_PERMISSION_ID` and calls `_burn(tokenId)` directly with no ownership argument —
  `_burn` reads current `ownerOf` itself (`ERC721Upgradeable.sol:L305`), so unlike `adminTransfer` there is no
  caller-supplied `_from` to cross-check; all three permissioned functions share the pattern "OZ internal does
  the real state-consistency enforcement, `auth(...)` does the sole access-control enforcement, and none of the
  three re-validates the OZ internal's preconditions before calling it." A single compromised holder of any of
  `MINT_PERMISSION_ID`/`BURN_PERMISSION_ID`/`TRANSFER_PERMISSION_ID` can affect the same `_owners`/`_balances`/
  voting-checkpoint state that the other two permissions also gate, but each permission is independently
  checked (`MINT_PERMISSION_ID` does not imply `TRANSFER_PERMISSION_ID` or vice versa) since `_auth` checks
  only the single `_permissionId` passed by that function's own `auth(...)` modifier.

**Open Questions:**
- unclear; need to inspect the DAO's permission-manager configuration (outside this repo's `src/`, in the
  deployed DAO instance) to know who is actually granted `TRANSFER_PERMISSION_ID`/`MINT_PERMISSION_ID`/
  `BURN_PERMISSION_ID` and whether any `PermissionCondition` narrows those grants — `GovernanceERC721.sol`
  provides no visibility into this and defines only the permission-identifier constants (L40, L43, L46).
  Confirmed already: the check itself lives in `PermissionManager.isGranted`
  (`lib/osx/packages/contracts/src/core/permission/PermissionManager.sol:L224`), but which addresses are
  granted is deployment/governance-configuration state not present in this file.
  - Both `adminTransfer` and `transferFrom` clear the same `_tokenApprovals[tokenId]` slot (L348) and neither
  restores it, so a holder who had approved a third party loses that approval on either kind of transfer —
  behavior identical to standard ERC-721, not something `adminTransfer` changes.
