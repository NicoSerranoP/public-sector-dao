# Signature Domain Audit — findings

**Scope**: EIP-712 / signature surface of `/home/nnico/public-sector/dao/src/`.
**Result**: No exploitable signature findings. Every checklist item was walked against the actual pinned library source. Three informational notes follow.

## Ground truth established

**Pinned dependency version** (both OZ submodules): `v4.9.6`
- `/home/nnico/public-sector/dao/lib/openzeppelin-contracts-upgradeable` → tag `v4.9.6`, commit `2d081f24cac1a867f6f73d512f2022e1fa987854`, `package.json` version `4.9.6`.
- `/home/nnico/public-sector/dao/lib/openzeppelin-contracts` → tag `v4.9.6`.
- Remapped in `/home/nnico/public-sector/dao/remappings.txt`: `@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/`.

**Verified directly from library source (not assumed):**

1. **Domain separator is fork-safe (recomputed every call).**
   `lib/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol`:
   ```solidity
   function _domainSeparatorV4() internal view returns (bytes32) {
       return _buildDomainSeparator();                    // no cache branch at all in 4.9.x upgradeable
   }
   function _buildDomainSeparator() private view returns (bytes32) {
       return keccak256(abi.encode(_TYPE_HASH, _EIP712NameHash(), _EIP712VersionHash(), block.chainid, address(this)));
   }
   ```
   `block.chainid` and `address(this)` are read on **every** invocation; the upgradeable variant keeps no cached separator and no cached `_CACHED_CHAIN_ID`. Chain-fork replay of `delegateBySig` is not possible. Checklist item "Chain ID binding" → **verified safe**.

2. **`delegateBySig` has both a nonce and an expiry.**
   `lib/openzeppelin-contracts-upgradeable/contracts/governance/utils/VotesUpgradeable.sol:134-151`:
   ```solidity
   require(block.timestamp <= expiry, "Votes: signature expired");
   address signer = ECDSAUpgradeable.recover(
       _hashTypedDataV4(keccak256(abi.encode(_DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s);
   require(nonce == _useNonce(signer), "Votes: invalid nonce");
   ```
   `_DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)")`, backed by a per-signer `CountersUpgradeable.Counter` in `_nonces` incremented by `_useNonce`. Indefinite replay is not possible. Checklist item "Nonce & replay" → **verified safe**.

3. **Signature malleability is rejected.**
   `lib/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol:134`:
   ```solidity
   if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
       return (address(0), RecoverError.InvalidSignatureS);
   }
   ```
   plus `v ∈ {27,28}` enforcement, and `recover` reverts on `RecoverError` rather than returning `address(0)`. 4.9.6 >> the 4.7.3 floor named in the checklist. Checklist item "ecrecover / malleability" → **verified safe**.

4. **`verifyingContract` is per-deployment; no shared implementation.**
   `GovernanceERC721` is instantiated only with `new` — the single construction site in the repo is `/home/nnico/public-sector/dao/script/InstallNFTVoting.s.sol:155` (`token_ = new GovernanceERC721(IDAO(address(_dao)), settings);`). A grep for `clone|ProxyLib|ERC1967|deployMinimalProxy|deployUUPSProxy` across `src/` and `script/` shows the only proxy deployment is the **plugin**, `nftVotingBase.deployMinimalProxy(...)` at `script/InstallNFTVoting.s.sol:172` for `NFTVoting` — and `NFTVoting` has no EIP-712 / signature surface whatsoever. Two `GovernanceERC721` tokens therefore always have distinct `address(this)` and cannot share a domain separator even with identical `name`. Checklist item "verifyingContract binding" → **verified safe**.

   Additionally, the constructor at `GovernanceERC721.sol:80-83` calls `initialize(...)` and then `_disableInitializers()`. Under 4.9.6 `Initializable`, the in-constructor `initializer` call passes via the `isTopLevelCall && _initialized < 1` branch and leaves `_initializing == false`, so `_disableInitializers()` succeeds and sets `_initialized = type(uint8).max`. The live token can never be re-`initialize`d, so the EIP-712 `name` (and thus the domain separator) cannot be retroactively changed to invalidate or re-target outstanding delegation signatures.

5. **No rename path → EIP-712 name cannot desync from the ERC-721 name.**
   Both `__ERC721_init(_settings.name, ...)` and `__EIP712_init(_settings.name, "1")` are fed the same string at `GovernanceERC721.sol:89-91`. A grep for `setName|setSymbol|_name =` across `src/` returns nothing; the only mutable metadata is `baseTokenURI` via `setBaseURI` (`GovernanceERC721.sol:187`), which is not part of the EIP-712 domain. In 4.9.6 `_EIP712Name()` reads the `_name` **string** from storage (not a pre-hash), so `eip712Domain()` and `_domainSeparatorV4()` are guaranteed consistent. Checklist item "Name/version used in signature vs constructor" → **confirmed absent, no desync**.

6. **Initialization of the Votes/EIP712 chain is complete.**
   `__ERC721Votes_init()` and `__Votes_init()` in 4.9.6 are empty no-ops (verified in `token/ERC721/extensions/ERC721VotesUpgradeable.sol` and `governance/utils/VotesUpgradeable.sol`); `__EIP712_init` is the only initializer that carries state, and `GovernanceERC721.initialize` calls it. There is no missed-initializer hole that would leave the domain separator built over `keccak256("")`. Note `__EIP712_init_unchained` explicitly zeroes `_hashedName`/`_hashedVersion`, which also satisfies the `require(_hashedName == 0 && _hashedVersion == 0, "EIP712: Uninitialized")` guard in `eip712Domain()`.

7. **No custom signature verification anywhere else in `src/`.**
   A grep across `src/` for `ecrecover|ECDSA|SignatureChecker|isValidSignature|permit(|EIP712|_hashTypedDataV4|delegateBySig|DOMAIN_SEPARATOR|recover(` returns exactly two hits, both in `GovernanceERC721.sol` (the comment at line 90 and the `__EIP712_init` call at line 91). `NFTVoting.sol`, `base/Proposal.sol`, `base/Votes.sol` and `base/Settings.sol` gate every state change on Aragon `auth(...)` permissions and `_msgSender()`; none accept a signature, a `v/r/s` triple, or a `bytes signature` blob. `Votes.vote()` derives the voter from `_msgSender()` only — there is no meta-transaction / vote-by-signature path to abuse. Checklist item "Signature surface elsewhere" → **none found**.

---

## [SIG-1] ERC-165 does not advertise ERC-5267 (`eip712Domain`) despite implementing it
**Severity**: Info
**Category**: signatures
**Location**: GovernanceERC721.supportsInterface() — `/home/nnico/public-sector/dao/src/erc721/GovernanceERC721.sol:108-119`
**Description**: `GovernanceERC721` inherits `EIP712Upgradeable` (via `ERC721VotesUpgradeable` → `VotesUpgradeable`), which implements `IERC5267Upgradeable.eip712Domain()` — the standard on-chain mechanism wallets and relayers use to discover a contract's EIP-712 domain before building a `delegateBySig` payload. The hand-rolled `supportsInterface` override enumerates `IERC721Upgradeable`, `IERC721MetadataUpgradeable`, `IVotesUpgradeable` and `IERC6372Upgradeable`, then falls through to `super`. In OZ 4.9.6 neither `EIP712Upgradeable` nor `VotesUpgradeable` registers anything with ERC-165, and `ERC721Upgradeable`/`ERC165Upgradeable` only add `IERC165`. So `supportsInterface(0x84b0196e)` (`type(IERC5267).interfaceId`, the `eip712Domain()` selector) returns `false` even though the function exists and works. No security impact — a client that calls `eip712Domain()` unconditionally gets the correct domain, and nothing about signature verification changes.
**Proof of Concept**: Not exploitable. Interop scenario: a delegation relayer that feature-detects via `token.supportsInterface(0x84b0196e)` before calling `eip712Domain()` concludes the token has no discoverable domain and either refuses to build a `delegateBySig` payload or falls back to guessing the domain fields (e.g. assuming version `"1"` and `name() == ERC721 name`, which happens to be correct here but is not guaranteed for an arbitrary token). The user sees the delegation flow fail, not a loss of funds or votes.
**Recommendation**: Add the interface to the existing override:
```solidity
import {IERC5267Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC5267Upgradeable.sol";

// in supportsInterface:
return _interfaceId == type(IERC721Upgradeable).interfaceId
    || _interfaceId == type(IERC721MetadataUpgradeable).interfaceId
    || _interfaceId == type(IVotesUpgradeable).interfaceId
    || _interfaceId == type(IERC6372Upgradeable).interfaceId
    || _interfaceId == type(IERC5267Upgradeable).interfaceId
    || super.supportsInterface(_interfaceId);
```

## [SIG-2] Auto self-delegation can silently undo a signed `delegateBySig(address(0), ...)`
**Severity**: Info
**Category**: signatures
**Location**: GovernanceERC721._afterTokenTransfer() — `/home/nnico/public-sector/dao/src/erc721/GovernanceERC721.sol:159-170`
**Description**: The override re-delegates any receiver whose delegate is currently `address(0)`:
```solidity
if (to != address(0) && delegates(to) == address(0)) {
    _delegate(to, to);
}
```
The only way to reach `delegates(x) == address(0)` after the first mint/transfer is for `x` to deliberately set it, either with `delegate(address(0))` or by signing a `delegateBySig` with `delegatee == address(0)` — the canonical way a holder renounces their voting power. That renunciation is not durable: the next inbound token (including one force-moved by the DAO via `adminTransfer`, or one pushed by any third party) silently restores self-delegation and re-arms the holder's voting power. This overlaps the delegation domain; it is noted here because the signed-message path is one of the two ways to express the intent, and because a signed renunciation that a later transfer reverses is a mild signer-intent mismatch. It is **not** a signature-security defect: the signature is consumed exactly once, the nonce is burned, and the delegation it requested is applied correctly at the time of execution. Voting power can never be double counted, since `_delegate` moves units rather than minting them.
**Proof of Concept**: (1) Holder `A` owns token #1 and is self-delegated. (2) `A` signs and submits `delegateBySig(address(0), nonce, expiry, v, r, s)` to abstain from governance; `delegates(A) == 0` and `A`'s voting power drops to 0. (3) Anyone transfers token #2 to `A` (or the DAO calls `adminTransfer(B, A, 2)`). (4) `_afterTokenTransfer` observes `delegates(A) == 0` and executes `_delegate(A, A)`, restoring voting power over **both** tokens. `A`'s signed renunciation is undone without `A` acting. No third party gains votes; `A` merely regains their own.
**Recommendation**: If durable renunciation is a requirement, track first-touch rather than inferring it from a zero delegate, so an explicit opt-out is not confused with "never delegated":
```solidity
mapping(address => bool) private _delegationInitialized;

function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
    internal virtual override(ERC721VotesUpgradeable)
{
    super._afterTokenTransfer(from, to, firstTokenId, batchSize);
    if (to != address(0) && !_delegationInitialized[to]) {
        _delegationInitialized[to] = true;
        _delegate(to, to);
    }
}
```
Otherwise, document that delegating to `address(0)` is transient and that holders should delegate to a burn-like sink address instead. (Adding storage here requires care: `GovernanceERC721` is deployed with `new`, so there is no upgrade-layout constraint, but the new slot must be appended after `baseTokenURI`.)

## [SIG-3] No test coverage for the `delegateBySig` / EIP-712 path
**Severity**: Info
**Category**: signatures
**Location**: repo-wide — `/home/nnico/public-sector/dao/test/`
**Description**: A grep across `test/` and `script/` for `delegateBySig`, `eip712Domain` and `nonces(` returns zero hits. The contract explicitly initializes EIP-712 to support signed delegation (`GovernanceERC721.sol:90-91`) and the accompanying comment calls it out as an intentional feature, but nothing exercises it. The path is correct today by inspection of OZ 4.9.6, so there is no live bug — the gap is that a future refactor (e.g. adding a name setter, switching to a proxy deployment, or bumping OZ to 5.x where `Nonces`, `delegateBySig`'s `signature`-bytes form and ERC-5267 semantics all change) would not be caught by CI.
**Proof of Concept**: Not exploitable; this is a regression-risk observation.
**Recommendation**: Add a Foundry test that signs a `Delegation(address delegatee,uint256 nonce,uint256 expiry)` struct against `token.eip712Domain()` and asserts (a) a valid signature delegates, (b) the same signature reverts with `"Votes: invalid nonce"` on replay, (c) a past `expiry` reverts with `"Votes: signature expired"`, and (d) `vm.chainId(...)` to a different chain makes a previously-valid signature fail — which locks in the fork-safety property verified above:
```solidity
bytes32 structHash = keccak256(abi.encode(
    keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
    delegatee, token.nonces(signer), expiry
));
(, string memory name_, string memory version_,,,,) = token.eip712Domain();
bytes32 domainSeparator = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256(bytes(name_)), keccak256(bytes(version_)), block.chainid, address(token)
));
(uint8 v, bytes32 r, bytes32 s) =
    vm.sign(signerPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
token.delegateBySig(delegatee, token.nonces(signer), expiry, v, r, s);
```

---

## Checklist disposition summary

| Checklist item | Disposition |
|---|---|
| Chain ID binding / fork safety | **Verified safe** — `_buildDomainSeparator()` reads `block.chainid` every call in OZ 4.9.6 upgradeable; no cache branch exists |
| `verifyingContract` binding / shared-domain collision | **Verified safe** — `GovernanceERC721` only ever deployed via `new` (`script/InstallNFTVoting.s.sol:155`); only the signature-free `NFTVoting` plugin uses a minimal proxy; constructor `_disableInitializers()` locks the domain |
| Name/version desync via rename | **N/A** — no `setName`/`setSymbol` anywhere in `src/`; 4.9.6 stores the name as a string read by both `eip712Domain()` and the separator, so they cannot diverge |
| Nonce & expiry on `delegateBySig` | **Verified safe** — `VotesUpgradeable.sol:134-151` enforces `block.timestamp <= expiry` and `nonce == _useNonce(signer)` |
| ecrecover / signature malleability | **Verified safe** — OZ 4.9.6 (>= 4.7.3 floor) rejects upper-half-order `s` and non-{27,28} `v`, and reverts instead of returning `address(0)` |
| Custom signature verification elsewhere | **None found** — `NFTVoting`, `Proposal`, `Votes`, `Settings` are entirely permission-gated via `auth(...)` and `_msgSender()` |
