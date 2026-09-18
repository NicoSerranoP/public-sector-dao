# `_afterTokenTransfer(address,address,uint256,uint256)` — `src/erc721/GovernanceERC721.sol` L161-172

## Summary

Internal hook, overriding `ERC721VotesUpgradeable._afterTokenTransfer`, that runs at the end of every
single-token mint, burn, and transfer in `GovernanceERC721`. It first defers to
`super._afterTokenTransfer` (`ERC721VotesUpgradeable`, which moves the transferred voting unit(s) between
the sender's and receiver's current *delegates*), then adds one piece of contract-specific behavior: if the
receiving address `to` is nonzero and currently has no delegate recorded (`delegates(to) == address(0)`),
it force-self-delegates that address via `_delegate(to, to)`. It performs no direct storage writes of its
own; all state mutation happens inside the two functions it calls (`super._afterTokenTransfer` →
`_transferVotingUnits` → checkpoint pushes, and `_delegate` → `_delegation` mapping write + checkpoint
pushes). It never reverts on its own (no `require`/`revert` in this function body); any revert would have to
come from `super._afterTokenTransfer` or `_delegate`.

```solidity
function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
    internal
    virtual
    override(ERC721VotesUpgradeable)
{
    super._afterTokenTransfer(from, to, firstTokenId, batchSize);

    // Automatically turn on delegation on mint/transfer if not delegating to anyone yet.
    if (to != address(0) && delegates(to) == address(0)) {
        _delegate(to, to);
    }
}
```

## Caller

This is a `_afterTokenTransfer` hook, not called directly by any `GovernanceERC721` code. It is invoked by
the OpenZeppelin `ERC721Upgradeable` internal functions `_mint`, `_burn`, and `_transfer`
(`lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol`), each of which calls
it once, always with a hard-coded `batchSize` literal of `1` and after all `_balances`/`_owners` bookkeeping
for that single token has already been committed:

- `_mint` — `_afterTokenTransfer(address(0), to, tokenId, 1)` at
  `lib/openzeppelin-contracts-upgradeable/.../ERC721Upgradeable.sol:290`, called after
  `_balances[to] += 1` / `_owners[tokenId] = to` (lines 283/286).
- `_burn` — `_afterTokenTransfer(owner, address(0), tokenId, 1)` at
  `lib/openzeppelin-contracts-upgradeable/.../ERC721Upgradeable.sol:324`, called after
  `_balances[owner] -= 1` / `delete _owners[tokenId]` (lines 318/320).
- `_transfer` — `_afterTokenTransfer(from, to, tokenId, 1)` at
  `lib/openzeppelin-contracts-upgradeable/.../ERC721Upgradeable.sol:363`, called after the balance/owner
  updates at lines 356-359.

`GovernanceERC721` does not override `_mint`, `_burn`, or `_transfer`, so these are the only three call
sites, and every entrypoint of interest routes through one of them:

- **`mint`** (`src/erc721/GovernanceERC721.sol:126-128`, `auth(MINT_PERMISSION_ID)`) → `_mintTo`
  (`src/erc721/GovernanceERC721.sol:151-156`) → OZ `_mint`. `from == address(0)`.
- **`burn`** (`src/erc721/GovernanceERC721.sol:133-135`, `auth(BURN_PERMISSION_ID)`) → OZ `_burn` directly.
  `to == address(0)`.
- **`adminTransfer`** (`src/erc721/GovernanceERC721.sol:143-146`, `auth(TRANSFER_PERMISSION_ID)`) → OZ
  `_transfer` directly. Both `from` and `to` nonzero (checked inside `_transfer`, OZ line 340: `require(to
  != address(0), ...)`; `from` is implicitly the current owner via the `ownerOf(tokenId) == from` check at
  OZ line 339).
- **`transferFrom` / `safeTransferFrom` / `safeTransferFrom(...,bytes)`** — inherited unmodified from
  `ERC721Upgradeable` (`lib/openzeppelin-contracts-upgradeable/.../ERC721Upgradeable.sol:155-175`); each
  checks `_isApprovedOrOwner(msg.sender, tokenId)` and then calls `_transfer` (directly, or via
  `_safeTransfer` → `_transfer` at line 196, with the `onERC721Received` callback at line 197 firing *after*
  `_transfer` — and hence after this hook — has already run to completion).

So this hook fires on all four of mint, burn, ordinary transfer, and admin (force) transfer, and always with
`batchSize == 1` and a single concrete `firstTokenId`.

`initialize` (`src/erc721/GovernanceERC721.sol:89-104`) also drives this indirectly: it calls `_mintTo` once
per entry in `_settings.receivers`, so every initial receiver goes through the mint path too.

## Step-by-step walkthrough

### 1. Delegate the transferred voting unit(s) via the parent hook (L166)

```solidity
super._afterTokenTransfer(from, to, firstTokenId, batchSize);
```

`ERC721VotesUpgradeable._afterTokenTransfer`
(`lib/openzeppelin-contracts-upgradeable/.../ERC721VotesUpgradeable.sol:31-39`) does:

```solidity
_transferVotingUnits(from, to, batchSize);
super._afterTokenTransfer(from, to, firstTokenId, batchSize); // ERC721Upgradeable's, a no-op (L458)
```

`_transferVotingUnits` (`VotesUpgradeable.sol:170-178`):

```solidity
function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
    if (from == address(0)) { _push(_totalCheckpoints, _add, toUint224(amount)); }
    if (to == address(0)) { _push(_totalCheckpoints, _subtract, toUint224(amount)); }
    _moveDelegateVotes(delegates(from), delegates(to), amount);
}
```

Key point: `_moveDelegateVotes` is given `delegates(from)` and `delegates(to)` — the *delegate addresses*
of the sender/receiver, looked up via the still-unmodified `_delegation` mapping (this function's own write,
if any, happens afterward in step 2). If `delegates(to) == address(0)` (receiver has no delegate — either
never delegated, or explicitly opted out), `_moveDelegateVotes`'s `to` parameter is `address(0)`, and the
credit branch is skipped (`VotesUpgradeable.sol:193`, `if (to != address(0))`), so the incoming voting
unit(s) are *not* credited to anyone at this stage. This is on purpose: the credit is deferred to step 2 as
one lump sum via a full self-delegation.

### 2. Auto-self-delegate a delegate-less receiver (L169-171)

```solidity
if (to != address(0) && delegates(to) == address(0)) {
    _delegate(to, to);
}
```

- `to != address(0)` excludes burns (`to == address(0)`); mints and transfers/admin-transfers always have
  `to != address(0)` (enforced by OZ's `_mint`/`_transfer` `require`s, see Caller section).
- `delegates(to)` (`VotesUpgradeable.sol:119-121`) is a plain mapping read (`_delegation[to]`); Solidity
  mappings have no "was this key ever set" bit, so this condition is **true both when `to` has never called
  `delegate(...)` and when `to` previously called `delegate(address(0))` to explicitly opt out.** The two
  states are indistinguishable from inside this function.
- When true, `_delegate(to, to)` (`VotesUpgradeable.sol:158-164`) runs:
  ```solidity
  address oldDelegate = delegates(account); // == address(0), by the branch condition
  _delegation[account] = delegatee;          // _delegation[to] = to
  emit DelegateChanged(account, oldDelegate, delegatee);
  _moveDelegateVotes(oldDelegate, delegatee, _getVotingUnits(account));
  ```
  `_getVotingUnits(to)` resolves to `ERC721VotesUpgradeable._getVotingUnits` →
  `balanceOf(to)` (`ERC721VotesUpgradeable.sol:46-48`). At this point `balanceOf(to)` already reflects the
  just-completed mint/transfer, because OZ's `_mint`/`_transfer` update `_balances`/`_owners` *before*
  calling `_afterTokenTransfer` (`ERC721Upgradeable.sol:283-290` for mint, `356-363` for transfer). So
  `_moveDelegateVotes(address(0), to, balanceOf(to))` credits `to`'s **entire current balance** (not just
  the one token from this transfer) to `to`'s own checkpoint in a single step — this is what makes deferring
  the credit in step 1 correct rather than double-crediting.

### Net effect per call path

- **Mint** (`from == address(0)`): step 1 increments `_totalCheckpoints`; if `to` had no delegate, step 2
  self-delegates `to` and credits its full balance (which, pre-mint, could already include previously
  minted, never-delegated tokens that had contributed no counted votes until now).
- **Burn** (`to == address(0)`): step 1 decrements `_totalCheckpoints` and debits `delegates(from)`'s
  checkpoint if `from` had a delegate; step 2's `if` is false (`to == address(0)`), so nothing else happens.
- **Ordinary transfer / admin transfer** (`from`, `to` both nonzero): step 1 moves 1 voting unit between
  `delegates(from)` and `delegates(to)` (a no-op on the `to` side if `delegates(to) == address(0)`); step 2
  self-delegates `to` (crediting its whole post-transfer balance) only if `to` had no delegate before this
  call.

## Invariants

- **Every nonzero address that has ever received a token through mint/transfer/admin-transfer and had no
  recorded delegate at that moment ends the call with `delegates(to) == to`.** Established by L169-171 in
  this function; the only way to leave this call with `delegates(to) == address(0)` is for `to` to already
  have had a nonzero delegate before this transfer (in which case the `if` is false and the pre-existing
  delegate is left untouched).
- **This hook never reduces or removes a delegate a receiver had actively chosen for itself (other than
  `address(0)`).** The `if` only fires when `delegates(to) == address(0)`; any nonzero delegate (self or a
  third party) is never overwritten by this function.
- **`batchSize` is always exactly `1` for every call this function will ever receive**, established entirely
  outside this function: the only three call sites of `_afterTokenTransfer` reachable from
  `GovernanceERC721` are OZ's `_mint`/`_burn`/`_transfer`, which each pass the literal `1`
  (`ERC721Upgradeable.sol:290,324,363`), and `GovernanceERC721` inherits only
  `ERC165Upgradeable, ERC721VotesUpgradeable, DaoAuthorizableUpgradeable`
  (`src/erc721/GovernanceERC721.sol:38`) — no `ERC721ConsecutiveUpgradeable` or other batch-minting
  extension is in the inheritance chain, even though such an extension exists in the vendored OZ library
  (`lib/openzeppelin-contracts-upgradeable/contracts/token/ERC721/extensions/ERC721ConsecutiveUpgradeable.sol`)
  and would produce `batchSize > 1`. This function does not itself assume `batchSize == 1` anywhere in its
  own logic — it forwards `batchSize` verbatim to `super._afterTokenTransfer` (L166) and never reads
  `firstTokenId` or `batchSize` again afterward; its own `if` branch operates only on the single address
  `to`, so it would not silently mis-behave if `batchSize` were ever `> 1` (the self-delegation logic is
  address-keyed, not token-count-keyed). The dependency on `batchSize == 1` lives one layer up, in
  `_transferVotingUnits`'s use of `amount` as "number of voting units moved" (`VotesUpgradeable.sol:170`),
  which is out of scope for this specific function but is a fact this function's correctness (crediting the
  right total balance) implicitly rests on.

## Assumptions (and what establishes or fails to establish them)

- **Assumption: `delegates(to) == address(0)` means "should be auto-delegated to itself."** This conflates
  two distinct states — "`to` has never interacted with delegation" and "`to` explicitly called
  `delegate(address(0))` to opt out of voting" — because `VotesUpgradeable`'s `_delegation` mapping
  (`VotesUpgradeable.sol:39`) stores both as the same zero value, and `delegates()`
  (`VotesUpgradeable.sol:119-121`) cannot distinguish "unset" from "explicitly set to the zero address."
  **Nothing in this function, or in `VotesUpgradeable`/`ERC721VotesUpgradeable`, establishes or preserves a
  distinct "opted out" state** — there is no separate boolean/sentinel for "has delegated at least once."
  Consequence walked through below.
- **Consequence for a holder who explicitly opts out:** a holder `H` calls `delegate(address(0))`
  (`VotesUpgradeable.sol:126-129`, `_msgSender() == H`), setting `_delegation[H] = address(0)` and moving
  `H`'s current voting units off of `H`'s previous delegate (`_delegate` body, `VotesUpgradeable.sol:158-164`).
  If `H` then receives **any new token** through **any** of the four paths this hook is wired to —
  - a third party calling `transferFrom`/`safeTransferFrom(from, H, tokenId)` (only the sender/approved
    party's consent is checked, `ERC721Upgradeable.sol:157,173`; `H` is a passive recipient with no say),
  - the `TRANSFER_PERMISSION_ID` holder force-transferring a token to `H` via `adminTransfer`
    (`src/erc721/GovernanceERC721.sol:143-146`),
  - the `MINT_PERMISSION_ID` holder minting a fresh token to `H` via `mint`
    (`src/erc721/GovernanceERC721.sol:126-128`),

  then, on that call, `delegates(H) == address(0)` still reads true (nothing distinguishes it from
  never-delegated), so this hook's `if` at L169 fires and runs `_delegate(H, H)` at L170 — **silently
  re-enrolling `H` into self-delegated voting and crediting `H`'s entire current balance to `H`'s own
  checkpoint**, reversing the effect of `H`'s own explicit opt-out. This is reachable purely by a third
  party's action; `H` need not sign, approve, or be aware of the incoming transfer/mint for it to happen
  (approval for a specific transfer is only required from the *sender* — `_isApprovedOrOwner`,
  `ERC721Upgradeable.sol:226-229` — not from the receiver), and `adminTransfer`/`mint` require only that the
  *caller* hold the relevant DAO permission, not any cooperation from `H`.
- **Assumption: `balanceOf(to)` at the time `_delegate(to, to)` runs already reflects the current
  mint/transfer.** Established by call ordering in the OZ base: `_balances`/`_owners` are updated before
  `_afterTokenTransfer` is invoked in all three of `_mint` (`ERC721Upgradeable.sol:283-290`), `_burn`
  (`318-324`, not relevant here since `to == address(0)` skips this branch), and `_transfer` (`356-363`).
  Confirmed by direct read of those functions above.
- **Assumption: no reentrancy into token-balance-changing calls occurs between the balance update and this
  hook's read of `balanceOf(to)`.** This function itself makes no external call. The only path where an
  external call can occur in the same top-level transaction *around* this hook is `_safeTransfer`/`_safeMint`
  invoking `onERC721Received` on `to` — and that call happens *after* `_transfer`/`_mint` (and hence after
  this hook) has fully completed (`ERC721Upgradeable.sol:195-198` for `_safeTransfer`, `249-254` for
  `_safeMint`), not before or during. So a malicious `to` contract's `onERC721Received` callback observes
  post-self-delegation state and could act on it (e.g. call `delegate(address(0))` again, or re-enter
  `transferFrom`), but that is a new, separate call into the contract rather than reentrancy into this hook
  itself.
- **Assumption: `firstTokenId` is unused by this override.** True as read — this function's own body never
  references `firstTokenId`; it is only forwarded to `super._afterTokenTransfer` (L166), which likewise does
  not use it (`ERC721VotesUpgradeable.sol:31-39` passes it through, unused, to the empty
  `ERC721Upgradeable._afterTokenTransfer` base hook at `ERC721Upgradeable.sol:458`).

## Callees

- **`super._afterTokenTransfer` → `ERC721VotesUpgradeable._afterTokenTransfer`**
  (`lib/openzeppelin-contracts-upgradeable/.../ERC721VotesUpgradeable.sol:31-39`). Source available, single
  unconditional path (no branches): calls `_transferVotingUnits(from, to, batchSize)` then the OZ
  `ERC721Upgradeable._afterTokenTransfer` no-op base hook (`ERC721Upgradeable.sol:458`, empty body). This
  function relies on it to (a) update `_totalCheckpoints` on mint/burn and (b) move `batchSize` voting units
  between `delegates(from)` and `delegates(to)` using the *pre*-self-delegation delegate mapping — i.e., it
  relies on this callee running *before* its own `_delegate(to, to)` call, which is guaranteed by the
  sequencing at L166 (called first) vs. L169-171 (called after).
- **`_transferVotingUnits`** (`VotesUpgradeable.sol:170-178`), called from the callee above. Walked all
  branches: `from == address(0)` → credits `_totalCheckpoints`; `to == address(0)` → debits
  `_totalCheckpoints`; both are independent `if`s (both fire on... never simultaneously in practice, since a
  mint has `to != 0` and a burn has `from != 0`, but nothing in this function itself enforces that — it's a
  structural fact of how `_mint`/`_burn`/`_transfer` call this hook). Then unconditionally calls
  `_moveDelegateVotes(delegates(from), delegates(to), amount)`.
- **`_moveDelegateVotes`** (`VotesUpgradeable.sol:183-202`, `private`, reached only via `_transferVotingUnits`
  and `_delegate`). Walked both branches: no-op if `from == to` (the two *delegate* addresses) or
  `amount == 0`; otherwise debits `from`'s checkpoint (only if `from != address(0)`) and credits `to`'s
  checkpoint (only if `to != address(0)`), each via `_push` → `Checkpoints.push`, using `SafeCastUpgradeable`
  casts to `uint224`/`uint32` that revert (rather than truncate) on overflow.
- **`delegates`** (`VotesUpgradeable.sol:119-121`, `public view`, reads `_delegation[account]`). No branches;
  pure mapping lookup. This function depends on it, per the Assumptions section above, to be unable to
  express "never delegated" separately from "delegated to `address(0)`" — that limitation is intrinsic to
  the callee's storage model, not a bug local to this override.
- **`_delegate`** (`VotesUpgradeable.sol:158-164`, `internal`). Single unconditional path: reads old
  delegate, overwrites `_delegation[account]`, emits `DelegateChanged`, then calls `_moveDelegateVotes` with
  `_getVotingUnits(account)` (i.e. `balanceOf(account)` via the override at
  `ERC721VotesUpgradeable.sol:46-48`) as the amount to move — this function relies on that amount being the
  receiver's *full* current balance (not just the newly transferred token(s)) for the "single lump credit"
  design described in the walkthrough to be correct rather than under/over-counting.

## State / side effects

No direct storage writes in this function's own body. Indirectly, through the two calls it makes:
- `_totalCheckpoints` (via `_transferVotingUnits`, mint/burn only).
- `_delegateCheckpoints[from_delegate]` / `_delegateCheckpoints[to_delegate]` (via `_moveDelegateVotes`,
  called from both `_transferVotingUnits` and, conditionally, `_delegate`).
- `_delegation[to]` (via `_delegate(to, to)`, only on the conditional branch at L169-171).
- Events emitted (indirectly): `DelegateVotesChanged` (0-2 times, from `_moveDelegateVotes`'s two independent
  debit/credit branches) and, conditionally, `DelegateChanged(to, address(0), to)` (only when the L169
  condition is true).

No external calls are made by this function or by any of its direct callees listed above.

## Open questions

- Is the collapse of "never delegated" and "explicitly delegated to `address(0)`" into the same storage
  value (`_delegation[account] == address(0)`) intentional upstream design (i.e., is opting out via
  `delegate(address(0))` documented/expected by OpenZeppelin to be non-durable across future balance
  changes), or is it a gap specific to how `GovernanceERC721` layers auto-self-delegation on top of stock
  `VotesUpgradeable`? The contract's own NatSpec (`src/erc721/GovernanceERC721.sol:34-36`) says "Holders can
  override this at any time by calling `delegate`" but does not address what happens to that override on a
  *subsequent, holder-uninitiated* token receipt.
- Does any code path outside this function (e.g., a future governance/voting module) rely on
  `delegates(account) == address(0)` as a durable signal that `account` has "opted out," in a way that this
  re-triggering behavior would silently break? Not found in `src/erc721/GovernanceERC721.sol`; would need to
  check consumers of `IVotesUpgradeable`/`getVotes`/`getPastVotes` elsewhere in the DAO/plugin contracts to
  know if any such assumption exists.
- Is `batchSize` ever expected to become `> 1` for this token in a future upgrade (e.g., if
  `ERC721ConsecutiveUpgradeable` were mixed in later)? Under the current inheritance
  (`src/erc721/GovernanceERC721.sol:38`) this cannot happen, but nothing in this function's signature or body
  documents that reliance — it is purely a fact about the current, non-upgraded inheritance graph.
