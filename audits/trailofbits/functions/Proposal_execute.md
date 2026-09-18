## `execute` in src/base/Proposal.sol (L43-55)

**Purpose:** The sole public entrypoint that turns a passed proposal's stored `actions` into an on-chain
call/delegatecall against the plugin's configured `target`. It is the last of two independent gates that
decide whether `_execute` (L59-74) is allowed to run for a given `_proposalId`; the other gate is the
early-execution branch inside `Votes._vote` (`src/base/Votes.sol:L66-71`).

**Inputs & Assumptions:**
- `_proposalId` (uint256): identifies a slot in `proposals` (`src/base/Proposal.sol:L31`). Trust:
  **untrusted** — any address can pass any id, including one that was never created (all-zero `Proposal`
  struct).
- Implicit: `_msgSender()` (default `ContextUpgradeable` behavior; no override found anywhere in
  `src/`, confirmed by `grep` for `_msgSender` in `src/` returning only call sites, not overrides).
- Implicit: `proposal_.parameters.votingToken` — the ERC-721 `Votes` token address captured at proposal
  creation time (`src/base/Proposal.sol:L315`), not necessarily the plugin's *current* `votingToken`
  (`src/base/Settings.sol:L39`, mutable via `updateVotingToken`, `src/base/Settings.sol:L178-180`). So the
  authorization check on L49 is pinned to the token that existed when the proposal was created, even if
  governance later swaps the token.
- Precondition (undocumented in this function): the proposal exists. Unlike `canExecute` (L76-85) and
  `hasSucceeded` (L110-115), `execute` carries **no `onlyIfProposalExists` modifier** (contrast with
  `modifier onlyIfProposalExists` at L34-39, applied to `canExecute` at L81 and `hasSucceeded` at L110 but
  not to `execute` at L43-55). If `_proposalId` was never created, `proposal_.parameters.votingToken` is
  `address(0)` (L45) and `IVotesUpgradeable(address(0)).getPastVotes(...)` at L49 is called against a
  non-contract address — nothing in `execute` itself distinguishes "nonexistent proposal" from "existing
  proposal whose token happens to be zero" (the latter cannot occur post-creation since `createProposal`
  always sets `votingToken` to a real address at L315).
- **No caller-identity/permission gate.** `execute` is `public virtual override(IProposal)` (L43) with no
  `auth(...)` modifier. `EXECUTE_PROPOSAL_PERMISSION_ID` is declared at L27 but a repo-wide search
  (`grep -rn EXECUTE_PROPOSAL_PERMISSION_ID src/`) shows it is referenced **nowhere else** — not in
  `Proposal.sol`, not in `Votes.sol`, not in `NFTVoting.sol` (`src/NFTVoting.sol`, which inherits `Votes`
  without overriding `execute`). Compare with `createProposal` (L277), which does carry
  `auth(CREATE_PROPOSAL_PERMISSION_ID)`, and with `updateVotingSettings`/`updateVotingToken`
  (`src/base/Settings.sol:L109-115`, `L178-180`), which carry `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)`.
  The only restriction on who may call `execute` is the pair of checks at L47-52 below — nothing establishes
  a DAO-permission-manager check on the `_msgSender()` of `execute` itself.

**Outputs & Effects:**
- No direct state writes; delegates all mutation to `_execute(_proposalId)` at L54.
- Reverts with `ProposalExecutionForbidden(_proposalId)` (L51) if either check at L48 or L49 fails.
- External call: `proposalVotingToken.getPastVotes(...)` (L49) — this is a `view`-typed interface call, so
  Solidity emits a `STATICCALL`, meaning the callee cannot write state during this call regardless of its
  implementation.
- On success, calls into `_execute` (L54), which performs the real state writes and external interaction
  (see below).

**Block-by-Block:**

```solidity
// L44-45
Proposal storage proposal_ = proposals[_proposalId];
IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);
```
- **What:** Loads the proposal storage slot and wraps its recorded voting token.
- **Why here:** Both fields are needed by the checks that follow.
- **Assumes:** the proposal exists, i.e. `votingToken != address(0)`. Nothing here checks that (see
  Inputs & Assumptions above); `_proposalExists` (L378-380) exists in this contract but is not called by
  `execute`.
- **Establishes:** nothing; simply reads.
- **Depended on by:** L47-50.

```solidity
// L47-52
if (
    !_canExecute(_proposalId)
        || proposalVotingToken.getPastVotes(_msgSender(), proposal_.parameters.snapshotTimepoint) == 0
) {
    revert ProposalExecutionForbidden(_proposalId);
}
```
- **What:** Two conditions combined with short-circuiting `||`: `_canExecute` is evaluated first; only if it
  returns `true` is `getPastVotes(_msgSender(), snapshotTimepoint)` evaluated.
- **Why here:** Guards the single call to `_execute` at L54; this is the entire admission-control logic for
  the function.
- **Assumes:** `_canExecute` (L91-107, internal, read below) correctly implements "not yet executed, mode
  timing satisfied, thresholds met." Assumes `getPastVotes` on the proposal's snapshotted token returns the
  caller's voting power as of `proposal_.parameters.snapshotTimepoint` without reverting or reentering with
  state changes (guaranteed non-reentrant only in the state-mutation sense, per the `STATICCALL` semantics
  noted above — it can still revert or return attacker-influenced data if the token contract's read path is
  adversarial).
- **Establishes:** if control passes L52, then (a) `proposal_.executed == false` immediately before this
  call (from `_canExecute`'s first check, L95-97), (b) the proposal has succeeded per `_hasSucceeded`
  (L106), and (c) `_msgSender()` held nonzero voting power in the proposal's token at the proposal's
  snapshot. It does **not** establish that `_msgSender()` holds any DAO-granted permission — no such
  check exists on this path (see Inputs & Assumptions).
- **Depended on by:** L54; and, transitively, by every downstream effect of `_execute`.

```solidity
// L54
_execute(_proposalId);
```
- **What:** Invokes the internal executor.
- **Why here:** Only reached if L47-52 did not revert.
- **Assumes:** `_canExecute`'s result at L48 is still valid at this point. Since `execute` performs no
  external call before this line other than the `STATICCALL` to `getPastVotes` (view, cannot write state),
  there is no reentrancy window between the check and this call within `execute` itself.
- **Establishes:** nothing further in this function; `_execute` takes over.
- **Depended on by:** the rest of the system, since this is where the proposal's `actions` actually run.

---

## `_execute` in src/base/Proposal.sol (L59-74)

**Purpose:** Marks the proposal executed and forwards its stored `actions`/`allowFailureMap`/`operation` to
the configured executor (the DAO, or another target/operation via `targetConfig`). It is the single choke
point through which both public-caller execution (`execute`, L54) and vote-triggered early execution
(`Votes._vote`, `src/base/Votes.sol:L70`) run.

**Inputs & Assumptions:**
- `_proposalId` (uint256): passed through unchanged from whichever caller invoked it. Trust depends on the
  caller (see Cross-Function Dependencies) — this function documents (L57) that it "assumes the queried
  proposal exists" but does not itself verify that; both actual call sites reach it only after `_canExecute`
  returned `true` for the same id, which (per `_canExecute` L94-97) implies `proposal_.executed` was `false`
  and (implicitly, since `_hasSucceeded`/threshold logic reads `proposal_.parameters` and `proposal_.tally`)
  the id corresponds to a real, created proposal in practice — but nothing inside `_execute` re-derives that.
- Implicit state read: `proposal_.targetConfig.target`, `proposal_.actions`, `proposal_.allowFailureMap`,
  `proposal_.targetConfig.operation` — all set once at proposal creation (`src/base/Proposal.sol:L322,
  L326-327, L329-334`) and never mutated afterward in this file.
- Precondition: this is the *only* function in the pair that writes `proposal_.executed`; no other write site
  for that field exists in `src/base/Proposal.sol` or `src/base/Votes.sol` (checked by inspection of both
  files — the only assignment is L62).

**Outputs & Effects:**
- State write: `proposal_.executed = true` (L62), unconditionally, **before** the external call.
- External call: `_execute(target, bytes32(_proposalId), actions, allowFailureMap, operation)` (L64-70) — an
  internal-but-inherited overload resolved to `PluginCloneable._execute`
  (`lib/osx-commons/contracts/src/plugin/PluginCloneable.sol:L154-189`, since `Settings` inherits
  `PluginCloneable`, not `Plugin` — `src/base/Settings.sol:L27`). See Cross-Function Dependencies for what
  that overload does and assumes.
- Events: `ProposalExecutionResult(_proposalId, resultFailureMap)` (L72) and `ProposalExecuted(_proposalId)`
  (L73), both emitted **after** the external call returns, so both are skipped if the call reverts the whole
  transaction.
- Postcondition if the whole call succeeds without reverting: `proposal_.executed == true` persists, and
  `resultFailureMap` reflects which of the allowed-to-fail actions (per `proposal_.allowFailureMap`) actually
  failed. `executed == true` does **not** imply every action succeeded — only that none of the
  not-allowed-to-fail actions failed (enforced by the callee, see below).

**Block-by-Block:**

```solidity
// L60-62
Proposal storage proposal_ = proposals[_proposalId];
proposal_.executed = true;
```
- **What:** Flips the executed flag before doing anything externally observable.
- **Why here:** Checks-effects-interactions ordering — the flag is set before the external call at L64-70,
  so any reentrant call into `_canExecute` (directly, or via `execute`/`Votes._vote` for the *same*
  `_proposalId`) during that external call sees `proposal_.executed == true` and is rejected at
  `_canExecute` L95-97.
- **Assumes:** nothing upstream has already set this to `true` for a still-in-flight execution (true by
  construction, since this is the only writer).
- **Establishes:** for the remainder of this call, and for any reentrant call that reaches `_canExecute` with
  the same `_proposalId`, `_canExecute` returns `false` at L96. This is what prevents `_execute` from being
  re-entered for the *same* proposal id via either of its two call sites while the external call at L64-70
  is still on the stack. If that external call itself reverts (e.g., `DAO.execute` reverting via
  `ActionFailed`, `lib/osx/packages/contracts/src/core/dao/DAO.sol:L305`, or `PluginCloneable._execute`'s
  `DelegateCallFailed`/bubbled revert, `lib/osx-commons/contracts/src/plugin/PluginCloneable.sol:L170-179`),
  this write at L62 is rolled back along with everything else in the transaction, so `proposal_.executed`
  reverts to `false` and the proposal remains executable again in a later transaction.
- **Depended on by:** `_canExecute` (L95-97) on every subsequent call for this `_proposalId`, from either
  `execute` or `Votes._vote`'s early-execution branch.

```solidity
// L64-70
(, uint256 resultFailureMap) = _execute(
    proposal_.targetConfig.target,
    bytes32(_proposalId),
    proposal_.actions,
    proposal_.allowFailureMap,
    proposal_.targetConfig.operation
);
```
- **What:** Forwards the proposal's stored actions to the plugin's inherited executor overload.
- **Why here:** After the `executed` flag flip, so the flag is set before any externally-observable side
  effect of running the actions.
- **Assumes:** the callee (`PluginCloneable._execute`, five-arg overload) either reverts the whole
  transaction or returns a `failureMap` that only has bits set for actions whose corresponding
  `allowFailureMap` bit was `1` — see Cross-Function Dependencies for how that is actually enforced
  (in `DAO.execute`, not here).
- **Establishes:** nothing new in this function; `resultFailureMap` is only used for the event at L72.
- **Depended on by:** L72 (event data only — not used for any control-flow decision in this function).

```solidity
// L72-73
emit ProposalExecutionResult(_proposalId, resultFailureMap);
emit ProposalExecuted(_proposalId);
```
- **What:** Emits the two execution-outcome events.
- **Why here:** Only reachable if L64-70 did not revert.
- **Assumes:** nothing further.
- **Establishes:** the on-chain record that this proposal id was executed, including the failure bitmap for
  off-chain consumers.
- **Depended on by:** off-chain indexers/observers only; no other on-chain logic reads these events.

---

**Cross-Function Dependencies (for the pair):**

- **Callee `_canExecute` (internal, `src/base/Proposal.sol:L91-107`):** read in full.
  - L95-97: `if (proposal_.executed) return false;` — the re-execution guard both `execute` and
    `Votes._vote` rely on.
  - L99-104: for `VotingMode.Standard` and `VotingMode.VoteReplacement`, returns `false` while
    `_isProposalOpen` (L251-256) is `true` — i.e. execution before `endDate` is only possible in
    `EarlyExecution` mode.
  - L106: delegates the actual success determination to `_hasSucceeded` (L121-152), which itself branches on
    `_isOpen` and checks support threshold, min participation, and min approval (L124-149). All of these read
    `proposal_.tally`/`proposal_.parameters`, which are mutated only by `Votes._vote`
    (`src/base/Votes.sol:L42-56`) and set once by `createProposal` (`src/base/Proposal.sol:L310-334`).
  - `_canExecute` does not check `onlyIfProposalExists`; for a nonexistent id every field it reads is the
    zero value, `proposal_.executed` is `false`, `_isProposalOpen` depends on `startDate<=now<endDate` with
    both dates `0` (false unless `block.timestamp` is treated specially — with `startDate=endDate=0`,
    `_isProposalOpen` L254 requires `currentTime < 0`, impossible for `uint64`, so `isProposalOpen` is
    `false`), so `_hasSucceeded` runs the closed-proposal branch (L138) with all tallies `0`. Whether that
    branch can return `true` for an all-zero proposal is an open question (see below) but is a path
    `execute`'s own logic (L47-52) does not foreclose by itself — it relies entirely on `_canExecute`/
    `_hasSucceeded`'s arithmetic to reject it.
- **Callee `PluginCloneable._execute` (internal, five-arg overload,
  `lib/osx-commons/contracts/src/plugin/PluginCloneable.sol:L140-189`):** read in full. Two branches on
  `_op`:
  - `Operation.DelegateCall` (L147-167 there, i.e. L161-181 in the five-arg copy at L154-189): delegatecalls
    `_target` with `IExecutor.execute(_callId, _actions, _allowFailureMap)`. On failure, bubbles the revert
    data if present (L170-176) or reverts `DelegateCallFailed()` (L178) if not. `Settings._setTargetConfig`
    (`src/base/Settings.sol:L184-190`) rejects `Operation.DelegateCall` outright, so in this plugin's actual
    configuration this branch is unreachable — `_execute` (Proposal.sol) always resolves to the `Call`
    branch. This is enforced by `Settings`, not by `Proposal.sol`/`PluginCloneable` themselves.
  - `Operation.Call` (else branch, L182-187 in the five-arg copy): calls `IExecutor(_target).execute(...)`
    directly — an external call to whatever `_target` is, typically the DAO (via
    `getTargetConfig`, `PluginCloneable.sol:L79-87`, falling back to `dao()` when `currentTargetConfig.target
    == address(0)`).
  - Neither branch itself decides revert-vs-allow-failure semantics; that is entirely the responsibility of
    whatever `_target` implements `IExecutor.execute`. For the default target, that is `DAO.execute`
    (`lib/osx/packages/contracts/src/core/dao/DAO.sol:L272-337`), read in full:
    - `nonReentrant` (L279) and `auth(EXECUTE_PERMISSION_ID)` (L280) — this is the actual DAO-permission
      check in the whole call chain, but it authorizes `_who = _msgSender()` **as seen by the DAO**, i.e. the
      plugin contract's own address (since the plugin makes this call), not the original transaction sender
      who called `execute(uint256)`/`vote(...)` on the plugin. So `EXECUTE_PERMISSION_ID` on the DAO gates
      "is this plugin allowed to make the DAO execute actions," not "is this specific caller of the plugin's
      `execute` allowed to trigger it."
    - `MAX_ACTIONS` bound (L284-286), independent of this plugin's own `actions.length <= 256` check enforced
      only at proposal-creation time (`src/base/Proposal.sol:L282`), not at execution time.
    - Per-action loop (L293-327): if `allowFailureMap` bit `i` is `0` and the call fails, reverts
      `ActionFailed(i)` (L302-306) — this is what would unwind `proposal_.executed = true` from
      `Proposal._execute` L62, per the check-effects note above. If the bit is `1`, a failing call only sets
      a bit in `failureMap` (L317-318) and execution continues, **unless** the failure is indistinguishable
      from a 63/64-gas griefing pattern (L313-315, `InsufficientGas()` revert) — this guards the allow-fail
      path specifically, not the atomic path.
    - Returns `(execResults, failureMap)` and emits `Executed(...)` (L329-336) with `actor: msg.sender`,
      i.e. the plugin's address, not the original caller of `Proposal.execute`.
  - **What `Proposal._execute` depends on this callee to establish:** that `resultFailureMap` (L64 in
    Proposal.sol) only has bits set where `allowFailureMap` permitted a failure, and that any
    not-allowed failure reverts the entire external call (and therefore the whole `_execute` transaction,
    undoing L62). Both properties are established by `DAO.execute`'s loop, not by `PluginCloneable._execute`
    or by `Proposal._execute` itself — if `targetConfig.target` were ever something other than the DAO (a
    custom `IExecutor`), nothing in `Proposal.sol` re-validates that the substitute target honors the same
    all-or-nothing-per-bit semantics.
- **Callers of `execute`/`_execute`:**
  - `execute(uint256)` is `public` with no `auth` modifier (see above) — reachable by any address, subject
    only to the L47-52 checks.
  - `Votes._vote` (`src/base/Votes.sol:L66-71`), the second call site for `_execute`, called from
    `Votes.vote` (`src/base/Votes.sol:L15-22`), which is itself `public virtual` with **no `auth` modifier
    either** and gated only by `_canVote` (`src/base/Votes.sol:L93-126`). The early-execution branch
    (L66-69) re-implements the *same* two-part check as `Proposal.execute` L47-52 — `_canExecute(_proposalId)
    && getPastVotes(_voter, snapshotTimepoint) > 0` — but keyed on `_voter` (the address that just cast a
    vote) rather than `_msgSender()` of a separate `execute` call. The two checks are independent copies of
    the same logic in two files; nothing ties them together structurally beyond both calling the same
    `_canExecute`.
  - Both call sites reach `_execute` only after their own `_canExecute` check passed in the same
    transaction, with no external call in between (the `getPastVotes` calls at `Proposal.sol:L49` and
    `Votes.sol:L37,L68` are `view`-typed `STATICCALL`s, so they cannot themselves flip `proposal_.executed`).
- **Shared state:** `proposals[_proposalId].executed`, written only at `Proposal.sol:L62`; read at
  `_canExecute` L95, `_isProposalOpen` L255, and `getProposal` L240. `proposals[_proposalId].tally`, written
  only by `Votes._vote` (L42-56 there), read by `_hasSucceeded`/`isSupportThresholdReached*`/
  `isMinParticipationReached`/`isMinApprovalReached` (all in `Proposal.sol`).
- **Invariant coupling:** the system's central execution invariant — "a given `_proposalId` runs its actions
  at most once" — rests entirely on `proposal_.executed` being set (L62) strictly before the external call
  (L64-70) that could reenter, combined with `_canExecute`'s L95-97 check. It holds for reentrancy through
  either of the two call sites analyzed here. It does not, by itself, say anything about who is allowed to
  trigger that single execution — that question is answered only by the L47-52 / L66-69 voting-power checks,
  since no DAO-permission check gates the plugin-level `execute`/`vote` entrypoints themselves.

**Open Questions:**
- unclear; need to inspect whether `EXECUTE_PROPOSAL_PERMISSION_ID` (`src/base/Proposal.sol:L27`) was
  intended to gate `execute` (as `CREATE_PROPOSAL_PERMISSION_ID` gates `createProposal` at L277) and was
  simply never wired in, or whether it is dead/vestigial and the design intends `execute` to be permissionless
  modulo the voting-power check at L49. Nothing in `Proposal.sol`, `Votes.sol`, or `NFTVoting.sol` applies
  this constant anywhere.
- unclear; need to inspect whether `_canExecute`/`_hasSucceeded` can return `true` for a genuinely
  nonexistent `_proposalId` (all-zero `Proposal` struct), since `execute` (L43-55) never calls
  `onlyIfProposalExists`/`_proposalExists` unlike `canExecute` (L81) and `hasSucceeded` (L110). This depends
  on the exact arithmetic in `isSupportThresholdReached` (L157-158: `(RATIO_BASE - 0) * 0 > 0 * 0` → `false`)
  and `isMinParticipationReached`/`isMinApprovalReached` for all-zero tallies/thresholds — a first pass
  suggests these are `false`/`false` for zero `minVotingPower`/`minApprovalPower` only if `>=` with `0 >= 0`
  is `true` (L179, L187 both use `>=`), which would make `isMinParticipationReached`/`isMinApprovalReached`
  return `true` for a nonexistent proposal since `0 >= 0`. Whether `isSupportThresholdReached`'s strict `>`
  at L157-158 (`0 > 0` is `false`) then also returns `false` and blocks this path is the deciding factor;
  this needs to be traced with the actual zero-valued `proposal_.parameters.supportThreshold` in mind, since
  `RATIO_BASE - 0 = RATIO_BASE` and `RATIO_BASE * 0 = 0`, so the condition is `0 > 0`, `false` — meaning
  `_hasSucceeded` would return `false` for a nonexistent proposal via the support-threshold branch before
  reaching the participation/approval checks. This resolves the question in favor of "not exploitable through
  this specific arithmetic," but it is derived from re-reading the formulas above rather than from any
  explicit existence check, so it is recorded here as a fact that rests on arithmetic coincidence
  (`supportThreshold == 0` yielding a false `>` comparison) rather than on an enforced precondition.
- unclear; need to inspect `getPastVotes` in the specific ERC-721 `Votes` implementation the DAO deploys
  (referenced only as `IVotesUpgradeable` here) to know whether it can revert, consume unbounded gas, or be
  influenced by the token owner in a way that affects the L49/L68 checks, since both call sites treat it as a
  trusted oracle of historical voting power without further validation in this file.
- unclear; need to inspect whether any other plugin/permission-setup code outside `src/` (e.g. deployment or
  setup contracts not covered by this analysis) grants `EXECUTE_PROPOSAL_PERMISSION_ID` to some role and
  expects it to matter, even though the current `execute` function never checks it.
