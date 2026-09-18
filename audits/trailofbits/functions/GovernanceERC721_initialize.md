## `initialize` in src/erc721/GovernanceERC721.sol (L89-104)

```solidity
// L89-104
function initialize(IDAO _dao, TokenSettings memory _settings) public initializer {
    __ERC721_init(_settings.name, _settings.symbol);
    // `ERC721Votes` relies on `EIP712` for `delegateBySig`, so it must be initialized explicitly.
    __EIP712_init(_settings.name, "1");
    __DaoAuthorizableUpgradeable_init(_dao);

    baseTokenURI = _settings.baseURI;

    for (uint256 i; i < _settings.receivers.length;) {
        _mintTo(_settings.receivers[i]);

        unchecked {
            ++i;
        }
    }
}
```

**Purpose:** One-time setup of the ERC-721 governance token: names the token for `ERC721`/`EIP-712` purposes,
binds the managing DAO used by every `auth(...)`-gated function (`mint`, `burn`, `adminTransfer`,
`setBaseURI`), sets the metadata base URI, and mints the genesis token distribution. It is the only place
`nextTokenId`, `baseTokenURI`, `_name`/`_symbol` (ERC721), the EIP-712 domain, and `dao_`
(`DaoAuthorizableUpgradeable`) are ever set to their initial values. Per L38's inheritance list and the
`initializer` modifier (OZ `Initializable.sol:L84-L99`), it is designed to run exactly once per storage
instance.

**Inputs & Assumptions:**
- `_dao` (IDAO): the DAO that will hold every `auth`-gated permission on this token. Trust: **trusted** in the
  sense that the constructor caller chooses it (see Callers below), but nothing in `initialize` or in
  `__DaoAuthorizableUpgradeable_init` (`lib/osx-commons/contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol:L22-L24`)
  validates it is non-zero or that it implements `IDAO`. It is stored verbatim into `dao_` (L23 of that file)
  and later dereferenced by every `auth(...)` call via `_auth(dao_, ...)` (`auth.sol:L31`), which calls
  `_dao.hasPermission(...)`.
- `_settings` (TokenSettings memory): `{name, symbol, baseURI, receivers}` (L62-L67). Trust: **trusted** at
  the constructor boundary (deployer-supplied, not attacker-reachable post-deployment since `initialize` can
  only run once — see below), but `receivers` entries are arbitrary addresses with no validation beyond what
  `_mint` performs (see `_mintTo` cross-function section).
- Implicit: `_initializing` / `_initialized` state from `Initializable` (inherited at L38); `nextTokenId` and
  `baseTokenURI` storage slots (L52, L55), both `private` and untouched before this call since the contract is
  only ever `new`-deployed (constructor comment L76-78).
- Precondition: this is the first and only call to `initialize` for this storage. Established by the
  `initializer` modifier's guard (`Initializable.sol:L84-L99`) *for this call*, and made permanent for all
  future calls by `_disableInitializers()` at L83 of the constructor — see the dedicated ordering analysis
  under Cross-Function Dependencies.
- Precondition (implicit, unenforced here): `_settings.receivers.length` is bounded such that the mint loop
  fits in one block's gas limit, since minting happens inside the constructor's single deployment transaction.
  Nothing in `initialize`, `TokenSettings`, or the constructor enforces a maximum length (L66, L97). See Open
  Questions.

**Outputs & Effects:**
- No return value.
- State writes: `_name`/`_symbol` (ERC721Upgradeable, via `__ERC721_init_unchained`), EIP-712
  `_name`/`_version`/`_hashedName`/`_hashedVersion` (via `__EIP712_init_unchained`), `dao_`
  (`DaoAuthorizableUpgradeable`), `baseTokenURI` (L95), and — via the loop — `nextTokenId`, `_owners`,
  `_balances`, vote checkpoints (`_totalCheckpoints`, `_delegateCheckpoints`), and `_delegation` for each
  receiver (see `_mintTo` below). Also sets `Initializable._initialized = 1` and toggles `_initializing`
  around the whole body (`Initializable.sol:L90-L98`).
- Events: one `Initialized(1)` (end of `initializer` modifier), and per receiver: `Transfer(0, receiver,
  tokenId)` (ERC721 `_mint`), `DelegateVotesChanged` and, on a receiver's first mint only, `DelegateChanged`
  (from the self-delegation hook, see below).
- No external calls: `_mint` (not `_safeMint`) never invokes `onERC721Received` on the receiver
  (`lib/openzeppelin-contracts-upgradeable/.../ERC721Upgradeable.sol:L269-L291` has no callback), so an
  attacker-controlled address placed in `receivers` cannot re-enter during this loop.
- Postcondition: every address in `_settings.receivers` holds one token per occurrence, self-delegated iff it
  had no delegate before this call, and `nextTokenId` equals `_settings.receivers.length` (starting from 0, so
  the first token id is 1, matching the doc comment at L51).

**Block-by-Block:**

```solidity
// L89
function initialize(IDAO _dao, TokenSettings memory _settings) public initializer {
```
- **What:** Entry point, guarded by OZ's `initializer` modifier.
- **Why here:** `public` so it is callable both from the constructor (L82) and, in principle, externally —
  the external path is neutralized only by `_disableInitializers()` running immediately after in the
  constructor (L83), not by anything in this function's own signature.
- **Assumes:** the `initializer` modifier's `require` (`Initializable.sol:L86-L89`) correctly gates
  first/only execution. See ordering analysis below for what happens if the constructor's two lines were
  swapped.
- **Establishes:** `_initializing = true` for the duration of the body, which is what lets the
  `onlyInitializing`-guarded `__*_init` callees below execute.

```solidity
// L90-93
__ERC721_init(_settings.name, _settings.symbol);
__EIP712_init(_settings.name, "1");
__DaoAuthorizableUpgradeable_init(_dao);
```
- **What:** Sets ERC-721 name/symbol, EIP-712 domain name/version, and the managing DAO.
- **Why here:** Must run before any minting, since `_mint`/`_afterTokenTransfer` do not depend on these but
  `delegateBySig` (EIP-712) and `auth(...)` (DAO) would be broken/unset if skipped; order among the three
  does not matter to each other since they touch disjoint storage.
- **Assumes:** all three are `onlyInitializing`-guarded (confirmed: `ERC721Upgradeable.sol:L45`,
  `EIP712Upgradeable.sol:L59`, `DaoAuthorizableUpgradeable.sol:L22`), so they revert if ever called outside an
  `initializer`/`reinitializer` context — not reachable here since `_initializing` is true.
- **Establishes:** `_name`/`_symbol` for ERC-721 and EIP-712 domain separator inputs; `dao_` for every future
  `auth(...)` check. **Does not establish** `_dao != address(0)` — nothing does (see Inputs & Assumptions).
- **Depended on by:** `supportsInterface`, `name()`/`symbol()` (inherited getters), `delegateBySig`, and every
  `auth(MINT_PERMISSION_ID | BURN_PERMISSION_ID | TRANSFER_PERMISSION_ID | UPDATE_BASE_URI_ID)` call
  elsewhere in the contract.

```solidity
// L95
baseTokenURI = _settings.baseURI;
```
- **What:** Sets the metadata base URI.
- **Why here:** No ordering dependency on the lines around it; placed before minting only stylistically —
  `_baseURI()` is not read during `_mint`.
- **Assumes:** nothing beyond `_settings` being valid memory (guaranteed by Solidity calldata/memory decoding).
- **Establishes:** the value `_baseURI()` (L177) returns thereafter, until `setBaseURI` (L189-198, gated by
  `UPDATE_BASE_URI_ID`) changes it.

```solidity
// L97-103
for (uint256 i; i < _settings.receivers.length;) {
    _mintTo(_settings.receivers[i]);
    unchecked {
        ++i;
    }
}
```
- **What:** Mints one token to each entry of `receivers`, in order, including duplicates.
- **Why here:** Placed last so name/symbol/DAO/URI are all set before any `Transfer`/`DelegateVotesChanged`
  event is emitted, though nothing in `_mint` or the vote-tracking path actually reads those values.
- **Assumes:** `_mintTo` never reverts for a valid, non-zero, distinct-per-call `tokenId` and that duplicate
  `_to` values are safe — both confirmed in the `_mintTo`/`_mint` walk below. Also assumes
  `_settings.receivers.length` is small enough to fit the deployment transaction in one block's gas limit —
  nothing in this loop or its caller bounds `length` (see Open Questions).
  `i` is `unchecked`-incremented (L100-102); at `type(uint256).max` iterations this would wrap, but reaching
  that requires an array of that length, which is unreachable well before any gas limit.
- **Establishes:** `nextTokenId == _settings.receivers.length` on exit (each `_mintTo` call increments it by
  exactly 1, per `_mintTo` below); every listed address holds a token and, per occurrence, an extra vote
  checkpoint if already self-delegated.
- **Depended on by:** all subsequent `mint`/`burn`/`adminTransfer` calls, which read/write `nextTokenId` and
  the ownership/vote state this loop first populates.

**Cross-Function Dependencies:**

- **Callee `_mintTo` (internal, L151-156):**
  ```solidity
  function _mintTo(address _to) internal virtual returns (uint256 tokenId) {
      unchecked {
          tokenId = ++nextTokenId;
      }
      _mint(_to, tokenId);
  }
  ```
  Read in full; single path, no branches. `nextTokenId` starts at the type's default (0, since this storage
  is fresh per the "deployed with `new` only" constructor comment at L76-78) and is pre-incremented, so the
  first call anywhere (in `initialize` or later via `mint`, L126-128) always produces `tokenId = 1`, matching
  the doc comment at L51. Because the counter is a single monotonically-increasing `uint256` shared by every
  call site, **every `_mintTo` invocation — including repeated calls for the same `_to` within the
  `initialize` loop — produces a distinct `tokenId`**, so `_mint`'s `require(!_exists(tokenId), ...)`
  (`ERC721Upgradeable.sol:L271,L276`) can never fire from within this loop. This is what makes the
  documented "list address `n` times to grant it `n` tokens/votes" behavior (L61) safe: duplicates never
  collide on `tokenId`, they simply consume `n` sequential ids for the same owner.
- **Callee `_mint` (OZ `ERC721Upgradeable.sol:L269-291`, source available):** read in full, both the guarded
  and post-hook paths.
  - `require(to != address(0), ...)` (L270): if any `receivers[i] == address(0)`, the whole `initialize` call
    — and therefore the whole constructor and deployment — reverts. There is no partial-mint outcome; EVM
    contract creation is atomic.
  - `require(!_exists(tokenId), ...)` both before and after `_beforeTokenTransfer` (L271, L276): both are
    satisfied here because `tokenId` is fresh (see above); the second check exists only to guard against a
    hook that mints during `_beforeTokenTransfer`, which `ERC721Upgradeable`'s own hook is a no-op for
    (`ERC721Upgradeable.sol:L442`) and `GovernanceERC721` does not override.
  - Balance/`_owners` updates (L283-286) are unconditional once past the guards; `_afterTokenTransfer` (L290)
    is then dispatched through the override chain: `GovernanceERC721._afterTokenTransfer` (L161-172) →
    `super` = `ERC721VotesUpgradeable._afterTokenTransfer`
    (`ERC721VotesUpgradeable.sol:L31-39`, calls `_transferVotingUnits(0, to, 1)` then its own `super`, a
    no-op) → back in `GovernanceERC721`, self-delegates `to` iff `delegates(to) == address(0)` (L169-171).
    Walked against `VotesUpgradeable` (`lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/VotesUpgradeable.sol`):
    on a receiver's *first* mint, `delegates(to)` is `address(0)` (L119-121), so `_delegate(to, to)` runs
    (L158-164), which calls `_moveDelegateVotes(0, to, _getVotingUnits(to))`
    (`VotesUpgradeable.sol:L183-196`) crediting the checkpoint. On a *second* mint to the same address within
    the same `initialize` call, `delegates(to)` is now `to` (non-zero), so the self-delegate branch is
    skipped, but `_transferVotingUnits(0, to, 1)` (`VotesUpgradeable.sol:L170-178`) still calls
    `_moveDelegateVotes(delegates(0)=0, delegates(to)=to, 1)`, crediting `to`'s existing delegate checkpoint
    by one more unit. Net effect confirmed: `n` occurrences of the same address in `receivers` yield a
    balance of `n`, `n` accumulated vote-checkpoint units under that address's own delegate, and exactly one
    `DelegateChanged` event (from the first mint) plus `n` `DelegateVotesChanged` events — matching the intent
    stated in the `receivers` doc comment (L61).
- **Callee `__ERC721_init` / `__EIP712_init` / `__DaoAuthorizableUpgradeable_init`:** each is a thin,
  `onlyInitializing`-guarded setter with no branches (`ERC721Upgradeable.sol:L45-52`,
  `EIP712Upgradeable.sol:L59-70`, `DaoAuthorizableUpgradeable.sol:L22-24`); none can be invoked outside an
  active `initializer`/`reinitializer` context, and none re-enter or call external code. `__EIP712_init`
  additionally zeroes `_hashedName`/`_hashedVersion` (L68-69) "in case of upgrading" — not applicable to this
  non-upgradeable, `new`-only deployment, but not harmful either since those slots start zero regardless.
- **Callee `_disableInitializers` (OZ `Initializable.sol:L145-151`), called from the constructor at L83, not
  from `initialize` itself, but its correctness depends on the call order established by the constructor —
  see the dedicated analysis below.**
- **Callers:** only the constructor (L81-84), which calls `initialize(_dao, _settings)` (L82) then
  `_disableInitializers()` (L83). `initialize` is also reachable as a standalone `public` call by anyone,
  before the constructor's `_disableInitializers()` line executes — but since Solidity executes constructor
  code atomically as part of contract creation, there is no window in which an external transaction can call
  `initialize` between L82 and L83; the only caller in practice is the constructor itself.
- **Shared state:** `nextTokenId` is also written by `mint` (L126-128, via `_mintTo`) and read implicitly
  through `_exists`/`ownerOf`; `baseTokenURI` also written by `setBaseURI` (L189-198); `dao_` is read by every
  `auth(...)` modifier use (`mint`, `burn`, `adminTransfer`, `setBaseURI`) but has no other writer anywhere in
  this contract — `initialize` is the only place it is ever set.
- **Invariant coupling:** the contract-wide invariant "`balanceOf(a)` equals the sum of vote-checkpoint units
  currently delegated by `a`'s delegate on `a`'s behalf" (the basis for `ERC721VotesUpgradeable._getVotingUnits`,
  `ERC721VotesUpgradeable.sol:L46-48`) is established incrementally by every `_mint`/`_burn`/transfer call,
  including the ones inside this loop; the walk above confirms the loop does not violate it even with
  duplicate receivers.

**`_disableInitializers()` ordering — constructor L81-84:**

```solidity
// L81-84
constructor(IDAO _dao, TokenSettings memory _settings) {
    initialize(_dao, _settings);
    _disableInitializers();
}
```
Read against `Initializable.sol` in full:
- `initializer` modifier (`L84-99`): on the first call, `_initializing` is `false`, so `isTopLevelCall = true`
  (L85); the `require` (L86-89) is satisfied by the left disjunct alone (`isTopLevelCall && _initialized < 1`,
  since `_initialized` starts at its zero value). `_initialized` is set to `1` (L90), `_initializing` to
  `true` (L92), the body (this `initialize` function) runs, then `_initializing` reverts to `false` and
  `Initialized(1)` is emitted (L95-98).
- `_disableInitializers()` (`Initializable.sol:L145-151`) then runs with `_initializing == false`, satisfying
  its own `require(!_initializing, ...)` (L146). Since `_initialized` (`1`) `!= type(uint8).max` (`255`), it
  sets `_initialized = 255` (L148) and emits `Initialized(255)`.
- Consequence for **this exact deployed instance**: any future call to `initialize` re-enters the `initializer`
  modifier with `isTopLevelCall = true` again, but now `_initialized == 255`, so neither disjunct of the
  `require` (L87) holds (`255 < 1` is false; `255 == 1` is false) — the call reverts unconditionally. There is
  no code path, `reinitializer(n)` included for any `n <= 255`, that can execute again, since `reinitializer`'s
  own guard (`Initializable.sol:L120`, `_initialized < version`) also fails for any `version <= 255`. This
  matches the constructor's doc comment (L76-78) that `_disableInitializers()` "locks this specific
  deployment's storage against any further `initialize` call once the constructor's own call has run" — that
  claim is directly confirmed by the modifier logic, not just asserted.
- **If the two lines at L82-83 were swapped** (`_disableInitializers()` before `initialize(...)`):
  `_disableInitializers()` would run first with `_initializing == false` (its own precondition, satisfied) and
  set `_initialized = 255` immediately. The subsequent `initialize(...)` call would then hit the `initializer`
  modifier's `require` (L86-89) with `_initialized == 255`, satisfying neither disjunct, and revert with
  `"Initializable: contract is already initialized"`. Because this all happens inside the constructor, the
  revert would propagate and abort the entire contract creation — the token would never deploy, rather than
  deploying in some uninitialized or partially-initialized state. This is a directly observable consequence
  of the `require` at `Initializable.sol:L86-89`, not an inferred one.
- Note on `AddressUpgradeable.isContract` (the right-hand disjunct of the same `require`,
  `Initializable.sol:L87`): `isContract(address(this))` is `account.code.length > 0`
  (`AddressUpgradeable.sol:L40-46`), which is `false` for the contract under construction (code is only
  stored once the constructor returns). This disjunct is irrelevant to the actual call sequence here (the
  left disjunct alone decides both the real call and the hypothetical swapped one), but it is what would let
  a `_initialized == 1` contract be re-initialized once *if* it were still mid-construction — not a state this
  contract ever reaches, since `initialize` and `_disableInitializers()` both run inside the same, single
  constructor invocation.

**Open Questions:**
- unclear; need to inspect whether any deployment tooling or factory in this repo constructs
  `GovernanceERC721` with a `receivers` array whose length is bounded by policy — nothing in
  `TokenSettings` (L62-67) or `initialize` (L97) enforces a maximum, so the only limit on how many receivers
  can be seeded is the block gas limit at deployment time, since minting happens inside the constructor's
  single transaction and a revert from exceeding the limit aborts the entire deployment rather than degrading
  gracefully.
- unclear; need to inspect whether `_dao` is ever validated (zero-address or code-existence) anywhere in the
  deployment pipeline outside this file — `__DaoAuthorizableUpgradeable_init` (`DaoAuthorizableUpgradeable.sol:L22-24`)
  performs no such check, and neither does `initialize`.
