## `createProposal(bytes,Action[],uint256,uint64,uint64)` in src/base/Proposal.sol (L271-337)

**Purpose:** The primary, permissioned entry point that turns a set of proposed `Action`s into on-chain
governance state: it snapshots the voting token's total supply, freezes the plugin's current voting
settings and execution target into a per-proposal record, and stores the actions for later `execute()`.
Every later read of "what this proposal requires to pass" (`isSupportThresholdReached`,
`isMinParticipationReached`, `isMinApprovalReached`, `_canExecute`) reads fields this function writes once
and never again. It is also the sole caller-facing path that assigns a `proposalId`; without it, `execute`,
`hasSucceeded`, and `getProposal` have no valid key to look up (`_proposalExists`, L378-380, depends on a
field this function sets).

**Inputs & Assumptions:**
- `_metadata` (bytes calldata): opaque, only hashed into the `proposalId` salt (L303) and re-emitted in
  `ProposalCreated` (L336, L348). Trust: untrusted, but never interpreted as anything other than bytes here.
- `_actions` (Action[] calldata): each element is `{target, value, data}` (per `IExecutor.Action`, not
  re-read here), stored verbatim for later execution. Trust: untrusted content — this function does not
  inspect `target`/`value`/`data`, it only bounds the array length (L282) and copies it (L329-334).
- `_allowFailureMap` (uint256): bitmap of action indices allowed to revert on execution. Trust: untrusted,
  unvalidated against `_actions.length` here (no check that set bits are `< _actions.length`).
- `_startDate`, `_endDate` (uint64): 0 means "fill in a default". Trust: untrusted; validated entirely by
  `_validateProposalDates` (L301, L388-431).
- Implicit: `_msgSender()` (L278, L279, L303, L336) — identity used for the permission check, the
  `canCreateProposal` check, the `proposalId` salt, and the emitted `creator`. `block.timestamp` /
  `block.number` (L289/L291, snapshot; L394, date validation; embedded in `proposalId` via
  `_createProposalId`, see callee section). `tokenIndexedByTimestamp` (Settings.sol L42) — plugin-wide flag
  read to choose which clock the snapshot uses.
- Precondition: caller holds `CREATE_PROPOSAL_PERMISSION_ID` on this plugin. Established by the `auth`
  modifier (L277), which calls `_auth` → `dao_.hasPermission(...)` (auth.sol L24-38) and reverts
  `DaoUnauthorized` otherwise. This is checked by the DAO's permission manager, out of scope here — treated
  as trusted infrastructure.
- Precondition: `_msgSender()` currently meets `minProposerVotingPower`. Established by `canCreateProposal`
  (L278, L194-212) — see callee analysis; note it recomputes its own snapshot timepoint independently of the
  one computed at L284-293 rather than reusing it.
- Precondition: the DAO-wide token has non-zero total supply at the snapshot. Established at L295-299 by
  reverting `NoVotingPower` if `totalVotingPower(snapshotTimepoint) == 0`.
- Precondition: `_actions.length <= 256`. Enforced at L282 via a bare `require` (no custom error, unlike the
  rest of the contract's error style).
- Precondition: the computed `proposalId` is not already in use. Established at L305-307 via
  `_proposalExists`, whose sentinel is discussed below.

**Outputs & Effects:**
- Returns `proposalId` (uint256), computed at L303 and used as the mapping key for the newly created
  `proposals[proposalId]` entry.
- Storage writes (all on a `Proposal storage proposal_` obtained after the existence check, L310):
  - `proposal_.parameters.{startDate, endDate, snapshotTimepoint, votingToken, votingMode,
    supportThreshold, minVotingPower}` (L312-318) — a frozen copy of plugin-wide settings at creation time.
  - `proposal_.minApprovalPower` (L320) — likewise frozen from `minApproval()`.
  - `proposal_.targetConfig` (L322) — frozen copy of `getTargetConfig()` (see callee section: this is
    itself derived from mutable `currentTargetConfig` storage in `PluginCloneable`).
  - `proposal_.allowFailureMap` (L325-327) — written **only if `_allowFailureMap != 0`**; left at its
    storage default (0) otherwise. See Block-by-Block for the implication.
  - `proposal_.actions` (L329-334) — each `_actions[i]` pushed individually.
  - `proposal_.executed`, `proposal_.tally`, `proposal_.voters` are never touched here; they rely on the
    storage slot being pristine (zero) rather than being explicitly zeroed.
- Event: `ProposalCreated(proposalId, _msgSender(), _startDate, _endDate, _metadata, _actions,
  _allowFailureMap)` emitted via the helper `_emitProposalCreatedEvent` (L336, L340-349) — note this emits
  the raw `_allowFailureMap` argument, not `proposal_.allowFailureMap`, so the event is accurate even on the
  zero-map path where storage was left untouched.
- External interactions (both before any storage write): `votingToken.getPastVotes` inside
  `canCreateProposal` (L211) and `votingToken.getPastTotalSupply` inside `totalVotingPower` (Settings.sol
  L73), reached via L278 and L295 respectively. Both are calls into the plugin's configured ERC-721 `Votes`
  token.
- No proposal-scoped reentrancy-relevant state is written before these two external calls, so a malicious
  token cannot yet observe or corrupt an in-progress proposal via reentry into `createProposal` itself
  (nothing has been written to `proposals[proposalId]` yet at that point) — though it could reenter other
  plugin entry points; not evaluated here.

**Block-by-Block:**

```solidity
// L277-L280
) public virtual auth(CREATE_PROPOSAL_PERMISSION_ID) returns (uint256 proposalId) {
    if (!canCreateProposal(_msgSender())) {
        revert ProposalCreationForbidden(_msgSender());
    }
```
- **What:** Gate 1 (DAO permission) then gate 2 (proposer voting power) before anything else runs.
- **Why here:** Cheapest reverts first; avoids the array-length loop and external calls below for callers
  who fail either gate.
- **Assumes:** `canCreateProposal` correctly reflects the caller's current voting power at a
  backrun-resistant snapshot (see callee analysis — it does, but via its *own* snapshot computation, not the
  one computed later in this function).
- **Establishes:** caller is both DAO-authorized and individually above `minProposerVotingPower` (or that
  threshold is 0).
- **Depended on by:** nothing downstream re-checks this; it is a one-time gate.

```solidity
// L282
require(_actions.length <= 256, "Too many actions (256+) in the proposal");
```
- **What:** Bounds the action array.
- **Why here:** Bounds the loop at L329-334 and the `_execute`/`allowFailureMap` bit-width usage later
  (`allowFailureMap` is a `uint256`, so 256 actions is the natural ceiling for one bit per action).
- **Assumes:** nothing upstream already bounds `_actions.length`.
- **Establishes:** `_actions.length <= 256` for the rest of this call.
- **Depended on by:** L329-334 (bounded loop), and implicitly `_allowFailureMap`'s bit semantics used later
  in `execute`/`_execute` (not analyzed here).

```solidity
// L284-L293
uint256 snapshotTimepoint;
unchecked {
    // The time point must be already mined (block) or in the past (timestamp) to
    // protect against backrunning transactions causing census changes.
    if (tokenIndexedByTimestamp) {
        snapshotTimepoint = block.timestamp - 1;
    } else {
        snapshotTimepoint = block.number - 1;
    }
}
```
- **What:** Computes a "one unit in the past" checkpoint so `getPastVotes`/`getPastTotalSupply` reads a
  finalized checkpoint rather than the still-forming current block/timestamp.
- **Why here:** Must happen before `totalVotingPower_` is read (L295) and before it is stored into
  `proposal_.parameters.snapshotTimepoint` (L314); this is the timepoint every later vote-weight and success
  computation for this proposal is pinned to.
- **Assumes:** `block.timestamp >= 1` or `block.number >= 1` respectively; the subtraction is `unchecked`, so
  if either underlying counter were `0` the result would wrap to `type(uint256).max` rather than revert.
  Wrapping is later caught indirectly by `SafeCastUpgradeable.toUint64` at L314, which `require`s the value
  fit in 64 bits (SafeCastUpgradeable.sol L426-429) and reverts otherwise — so the wrap case reverts the
  whole transaction rather than silently storing a huge value.
- **Establishes:** a timepoint that is guaranteed to already be mined/passed relative to the current
  transaction, intended to prevent a proposer from front-running/back-running their own proposal creation to
  manipulate the token census used for `totalVotingPower_`, `minVotingPower`, and `minApprovalPower`.
- **Depended on by:** L295 (`totalVotingPower_`), L314 (`proposal_.parameters.snapshotTimepoint`), and via
  that field, every later vote-weight lookup (`isSupportThresholdReachedEarly`, `execute`'s
  `getPastVotes` check) and the `_proposalExists` sentinel (see Open Questions / Cross-Function
  Dependencies below for the `snapshotTimepoint == 0` edge case).
- **Note:** this same computation is independently re-executed inside `canCreateProposal` (L195-204) rather
  than the two functions sharing one value. Within a single transaction both reads see the same
  `block.timestamp`/`block.number`, so they agree in practice, but they are not structurally the same
  variable.

```solidity
// L295-L299
uint256 totalVotingPower_ = totalVotingPower(snapshotTimepoint);

if (totalVotingPower_ == 0) {
    revert NoVotingPower();
}
```
- **What:** Reads the ERC-721 token's total supply at the snapshot and rejects proposal creation if it is
  zero.
- **Why here:** After the snapshot is fixed, before it is used to derive `minVotingPower` /
  `minApprovalPower` — division by a supply of 0 is not the concern (ratios are multiplicative, see
  `_applyRatioCeiled`), but a proposal with `minVotingPower == 0` and `minApprovalPower == 0` would trivially
  satisfy participation/approval thresholds forever, which this guard prevents.
- **Assumes:** `votingToken.getPastTotalSupply(snapshotTimepoint)` (Settings.sol L73) returns a value the
  plugin can trust to represent minted-token count. Trust boundary: the voting token is configured by
  `updateVotingToken` (Settings.sol L178-210), gated by `UPDATE_VOTING_SETTINGS_PERMISSION_ID`, so it is
  semi-trusted (DAO-governed, not attacker-controlled by an arbitrary caller of `createProposal`).
- **Establishes:** `totalVotingPower_ > 0` for the rest of the function.
- **Depended on by:** L318 (`minVotingPower = _applyRatioCeiled(totalVotingPower_, minParticipation())`) and
  L320 (`minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApproval())`).

```solidity
// L301
(_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);
```
- **What:** Normalizes and bounds-checks the proposal's voting window.
- **Why here:** Before `proposalId` is derived — note `_startDate`/`_endDate` themselves are **not** part of
  the `proposalId` salt (L303 only hashes sender/actions/metadata), so this reordering doesn't affect
  uniqueness, but it must precede storing `proposal_.parameters.startDate/endDate` (L312-313).
- **Assumes:** `votingSettings.minDuration` and `votingSettings.maxBoundDate` are sane (enforced at
  configuration time by `_updateVotingSettings`, Settings.sol L132-138: `minDuration >= 60 minutes` and
  `minDuration <= maxBoundDate`).
- **Establishes:** `startDate <= endDate` bounds consistent with current `votingSettings`; see callee
  analysis for the exact bounds and the one path that does not re-validate against `maxBoundDate` the same
  way as `minDuration`.
- **Depended on by:** L312-313 and all downstream time-window logic (`_isProposalOpen`, `_canExecute`).

```solidity
// L303-L307
proposalId = _createProposalId(keccak256(abi.encode(_msgSender(), _actions, _metadata)));

if (_proposalExists(proposalId)) {
    revert ProposalAlreadyExists(proposalId);
}
```
- **What:** Derives a deterministic ID from `(chainid, block.number, address(this), sender, actions,
  metadata)` (see `_createProposalId` callee) and rejects if that exact ID is already in use.
- **Why here:** Must happen before `proposals[proposalId]` is touched (L310) so the existence check reads
  the pre-write state.
- **Assumes:** `_proposalExists` correctly reports "never written" vs "already created" using
  `proposals[_proposalId].parameters.snapshotTimepoint != 0` (L378-380) as its sole sentinel.
- **Establishes:** the mapping slot at `proposals[proposalId]` is either genuinely untouched, or (in the
  documented edge case below) has `snapshotTimepoint == 0` despite carrying other data.
- **Depended on by:** every subsequent write in this function assumes it is writing to a zero-initialized
  struct rather than appending onto pre-existing `actions`/`tally`/`voters` data.

```solidity
// L310-L322
Proposal storage proposal_ = proposals[proposalId];

proposal_.parameters.startDate = _startDate;
proposal_.parameters.endDate = _endDate;
proposal_.parameters.snapshotTimepoint = snapshotTimepoint.toUint64();
proposal_.parameters.votingToken = address(votingToken);
proposal_.parameters.votingMode = votingMode();
proposal_.parameters.supportThreshold = supportThreshold();
proposal_.parameters.minVotingPower = _applyRatioCeiled(totalVotingPower_, minParticipation());

proposal_.minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApproval());

proposal_.targetConfig = getTargetConfig();
```
- **What:** Copies seven plugin-wide, currently-mutable settings (`votingToken`, `votingMode()`,
  `supportThreshold()`, `minParticipation()`, `minApproval()`, `getTargetConfig()`) plus the freshly computed
  `totalVotingPower_`/`snapshotTimepoint`/dates into per-proposal storage.
- **Why here:** This is the pinning step — every value read here is a live getter over mutable state
  (`votingSettings`, `votingToken`, `currentTargetConfig` in `PluginCloneable`) that `updateVotingSettings`,
  `updateVotingToken`, or `setTargetConfig` can change *after* this call returns. Reading them exactly once,
  here, is what makes already-created proposals immune to later governance-settings changes.
- **Assumes:** `votingMode()`, `supportThreshold()`, `minParticipation()`, `minApproval()` (Settings.sol
  L78-104) all read `votingSettings` directly with no additional validation at read time — their validity was
  established once, at whichever `_updateVotingSettings` call last wrote them (Settings.sol L119-173), not
  here.
- **Establishes:** `proposal_.parameters`, `proposal_.minApprovalPower`, `proposal_.targetConfig` become
  immutable for the lifetime of this proposal (nothing in this file writes them again).
- **Depended on by:** `isSupportThresholdReached`, `isSupportThresholdReachedEarly`,
  `isMinParticipationReached`, `isMinApprovalReached`, `_isProposalOpen`, `execute`/`_execute` (target and
  operation for the actual call).

```solidity
// L324-L327
// Reduce costs
if (_allowFailureMap != 0) {
    proposal_.allowFailureMap = _allowFailureMap;
}
```
- **What:** Skips the `SSTORE` for `proposal_.allowFailureMap` when the caller passes `0`.
- **Why here:** Gas optimization: a fresh mapping slot's `uint256` field already defaults to `0`, so writing
  `0` explicitly would cost a nonzero-to-zero-or-zero-to-zero `SSTORE` for no semantic gain, since
  `_allowFailureMap == 0` and "leave the field at its default 0" are indistinguishable in the stored data.
- **Assumes:** the slot is truly fresh (default 0) at this point — the same assumption established (or not)
  by the L305-307 existence check. If that check ever passed on a slot with a stale nonzero
  `allowFailureMap` left over from a previous partial or reused write, this branch would silently preserve
  the stale value instead of resetting it to the caller's intended `0`.
- **Establishes:** `proposal_.allowFailureMap == _allowFailureMap` in both the zero and nonzero cases, given
  a genuinely fresh slot — the branch is behavior-preserving, not a semantic special-case, under that
  assumption.
- **Depended on by:** `_execute` (L64-70) reads `proposal_.allowFailureMap` when executing.

```solidity
// L329-L334
for (uint256 i; i < _actions.length;) {
    proposal_.actions.push(_actions[i]);
    unchecked {
        ++i;
    }
}
```
- **What:** Copies each calldata `Action` into the proposal's storage array one at a time.
- **Why here:** After the existence/freshness check, so `proposal_.actions` is assumed empty before the
  first `push`.
- **Assumes:** `proposal_.actions` was empty on entry (same freshness assumption as above) — otherwise
  `push` appends rather than replacing, producing a longer-than-intended actions array.
- **Establishes:** `proposal_.actions` holds exactly `_actions` in order, length `<= 256` (from L282).
- **Depended on by:** `_execute` (L67, passes `proposal_.actions` to the executor).

```solidity
// L336
_emitProposalCreatedEvent(_metadata, _actions, _allowFailureMap, proposalId, _startDate, _endDate);
```
- **What:** Emits `ProposalCreated` via a private helper.
- **Why here:** Last statement — all state is already committed to storage before the event fires.
- **Assumes:** nothing further; purely observational.
- **Establishes:** an off-chain-indexable record of the creation, using the raw `_allowFailureMap` argument
  (not the possibly-unwritten `proposal_.allowFailureMap`), so indexers see the caller's intent even on the
  zero-map optimization path.

**Cross-Function Dependencies:**

- **Callee `canCreateProposal` (internal, L194-212):** read in full, single path (no branch that skips the
  check other than the `minProposerVotingPower_ == 0` short-circuit at L207-209, which is an intentional
  "no threshold configured" bypass, not a gap). Depends on `votingToken.getPastVotes` (external call,
  semi-trusted token). Establishes the "proposer meets `minProposerVotingPower`" precondition using its own
  independently computed snapshot (L195-204), structurally identical to but not shared with the one at
  L284-293.
- **Callee `totalVotingPower` (Settings.sol L72-74, internal wrapper over an external call):** single path,
  no branching; a straight passthrough to `votingToken.getPastTotalSupply(_timePoint)`. This function
  depends on it to establish `totalVotingPower_`, the base for both `minVotingPower` and
  `minApprovalPower`. Since it's a single external call with no local validation, a token contract that
  returns an unexpectedly small or large value (rather than reverting) is not detected here — no bounds
  check on the returned supply beyond the `== 0` guard at L297.
- **Callee `_validateProposalDates` (internal, L388-431):** read in full, three sub-paths:
  - `_start == 0` (L396-397): `startDate = currentTimestamp`, no upper/lower bound check needed since it's
    derived, not user-supplied.
  - `_start != 0` (L398-408): checked against `[currentTimestamp, currentTimestamp + maxBoundDate]`,
    reverting `DateOutOfBounds` outside that range.
  - `_end == 0` vs `_end != 0` (L415-430): default end is `startDate + minDuration` (no upper bound needed,
    self-derived); explicit end is checked against `[earliestEndDate, startDate + maxBoundDate]`. The
    comment at L424 ("mirrors the configurable ceiling already enforced on `minDuration` in `Settings`")
    is the only place asserting `maxBoundDate` is itself sane; that assertion is actually enforced in
    `Settings._updateVotingSettings` (Settings.sol L136-138: `minDuration <= maxBoundDate`), a different
    file, at configuration time, not here.
  - This function depends on `_validateProposalDates` to establish `startDate <= endDate` and both within
    governance-configured bounds before they are pinned into `proposal_.parameters` at L312-313.
- **Callee `_createProposalId` (ProposalUpgradeable.sol L32-34, internal): `uint256(keccak256(abi.encode(
  block.chainid, block.number, address(this), _salt)))`.** Single path, no branches. This function depends
  on it for `proposalId` uniqueness, but uniqueness is scoped to `(chainid, block.number, address(this),
  salt)` — the salt itself (`keccak256(sender, actions, metadata)`, L303) does not include `_startDate`,
  `_endDate`, or `_allowFailureMap`. Two calls with identical `(sender, actions, metadata)` in the *same*
  block collide and the second reverts via `_proposalExists` (L305-307); the same tuple submitted in a
  *different* block produces a different ID and is not deduplicated at all, regardless of date/allowFailureMap
  differences.
- **Callee `_proposalExists` (private, L378-380): `proposals[_proposalId].parameters.snapshotTimepoint !=
  0`.** This is the sole existence sentinel for the entire contract (also used by `onlyIfProposalExists`,
  `isMinParticipationReached`, `isMinApprovalReached`). `createProposal` is the only function found in this
  file that writes `parameters.snapshotTimepoint`, and grepping `src/` finds no function that ever resets it
  to `0` afterward — so once a proposal is created, `_proposalExists` stays `true` for that ID for the life
  of the contract. The one path by which `createProposal` itself could write `snapshotTimepoint == 0` is the
  unchecked computation at L284-293 evaluating to exactly `0`: `block.number == 1` when
  `tokenIndexedByTimestamp == false`, or `block.timestamp == 1` when `tokenIndexedByTimestamp == true`. On
  any real chain post-genesis both conditions are already false by the time this plugin can be deployed, but
  nothing in the code itself excludes the case — it is excluded only by real-world chain state, not by a
  check in `createProposal` or `_proposalExists`.
- **Callee `_applyRatioCeiled` (Ratio.sol L18-31, pure, external-source-available library function):**
  single path other than its own revert. Reverts `RatioOutOfBounds` if `_ratio > RATIO_BASE`; this function
  passes `minParticipation()` and `minApproval()` as `_ratio`, both of which are bounded to
  `[1, MAX_GOVERNANCE_RATIO=900_000]` by `Settings._updateVotingSettings` (Settings.sol L128-129, L142-143)
  at configuration time — `_applyRatioCeiled` does not re-derive that bound, it only guards against
  `_ratio > RATIO_BASE = 10**6`, a looser check than the governance-time one. `createProposal` depends on
  `_applyRatioCeiled` only for the ceiling-division arithmetic (`result = ceil(_value * _ratio /
  RATIO_BASE)`), not for bounding `_ratio` itself.
- **Callee `getTargetConfig` (PluginCloneable.sol L79-87, internal):** single path, no external call. Reads
  `currentTargetConfig` (private storage in `PluginCloneable`, settable via `setTargetConfig`, gated by
  `SET_TARGET_CONFIG_PERMISSION_ID`, PluginCloneable.sol L60-64); if `target == address(0)` it substitutes
  `{dao(), Operation.Call}` (L82-84). This function depends on it to pin, at creation time, whichever target
  is currently configured — a later `setTargetConfig` call does not retroactively change
  `proposal_.targetConfig` for proposals already created (by design, per the field's own doc comment in
  INFTVoting.sol L73-75: "applied to the proposal when it was created").
- **Callee `auth` modifier / `_auth` (DaoAuthorizableUpgradeable.sol L34-37, auth.sol L24-38):** single path;
  calls `dao_.hasPermission(where, who, permissionId, data)` (an external view call into the DAO contract,
  out of scope) and reverts `DaoUnauthorized` if it returns `false`. This function depends on it for the
  sole DAO-level access-control gate; no local fallback or additional check exists in `createProposal`
  itself.
- **Callers:** none within `src/base/Proposal.sol` other than the 5-argument wrapper overload
  `createProposal(bytes,Action[],uint64,uint64,bytes)` (L352-367), which is the `IProposal`-interface-mandated
  signature. That wrapper decodes `allowFailureMap` from `_data` (L362-364, defaulting to `0` if `_data` is
  empty) and forwards to this function (L366) — the comment at L359 notes this is intentional so the
  permission check (`auth`) and `canCreateProposal` check both live in one place. Any external caller
  (typically the DAO's proposal-creation UI/relayer holding `CREATE_PROPOSAL_PERMISSION_ID`) can also call
  this 5-arg `uint256`-`_allowFailureMap` overload directly; both entry points converge here.
- **Shared state:** `proposals` mapping — written here, read by `execute`, `_execute`, `canExecute`,
  `_canExecute`, `hasSucceeded`, `_hasSucceeded`, `isSupportThresholdReached(Early)`,
  `isMinParticipationReached`, `isMinApprovalReached`, `getProposal`, `_isProposalOpen`. `votingSettings` and
  `votingToken` (Settings.sol) — mutable, written by `updateVotingSettings`/`updateVotingToken`, only *read*
  here (via the getters) to seed the frozen per-proposal copy. `currentTargetConfig`
  (PluginCloneable.sol) — mutable, written by `setTargetConfig`, only read here via `getTargetConfig()`.
- **Invariant couplings:** The system-wide invariant "a proposal's pass/fail thresholds are fixed at
  creation and independent of later governance changes" depends entirely on this function reading every
  mutable setting exactly once (L312-322) rather than proposals re-reading `votingSettings` live at
  evaluation time. The invariant "`_proposalExists(id) == true` forever once set" depends on no code path
  anywhere zeroing `snapshotTimepoint` post-creation, which holds only because no such code path exists in
  `src/` (not because it is actively guarded against).

**Open Questions:**
- unclear; need to inspect whether `Action.data`/`Action.target`/`Action.value` (defined in
  `IExecutor.sol`, imported but not read in this analysis) are validated anywhere before or after storage —
  `createProposal` stores them unconditionally.
- unclear; need to inspect whether any deployment/initialization path could plausibly hit
  `block.number == 1` or `block.timestamp == 1` at the moment `createProposal` is first called on a given
  chain (e.g., a private/test chain reset to genesis), which is the only identified way
  `proposal_.parameters.snapshotTimepoint` could be written as `0` and collide with the `_proposalExists`
  sentinel.
- unclear; need to inspect `IDAO.hasPermission` (out of scope here) to know whether it can have
  side effects or reenter the caller — `_auth` treats it as a pure permission oracle but it is an external
  call.
- unclear; need to inspect whether `_allowFailureMap` bits at indices `>= _actions.length` are ever
  validated anywhere (not in this function, and not confirmed in `_execute`/`Executor` from the files read
  here).
