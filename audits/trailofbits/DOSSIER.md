# Audit Context Dossier — NFTVoting plugin + GovernanceERC721

Built independently from source only (`src/`, plus library sources it calls into under `lib/`). Prior manual
audit reports in `audits/` (pashov, ethskills) were deliberately **not** read while producing this dossier or
the 13 per-function analyses it indexes, per instruction. Any overlap with those reports below is coincidental
convergence from re-reading the same code, not cross-referencing.

Scope: `src/NFTVoting.sol`, `src/base/{INFTVoting,Proposal,Settings,Votes}.sol`, `src/erc721/GovernanceERC721.sol`.

Per-function detail lives in `audit-context/functions/*.md` (13 files, listed at the bottom). This file is the
cross-function synthesis: modules, entrypoints, actors, state, and — most importantly — the assumptions
nothing in the code establishes, and the open questions.

---

## Modules

| Module | Path | Role |
|---|---|---|
| `NFTVoting` | `src/NFTVoting.sol` | Top-level plugin contract; assembles `Votes`→`Proposal`→`Settings`; owns `initialize` and interface-ID advertising. |
| `Settings` | `src/base/Settings.sol` | Voting-settings storage, voting-token storage, clock-mode detection, target-config gate. |
| `Proposal` | `src/base/Proposal.sol` | Proposal storage, creation, date validation, execution, success/eligibility predicates. |
| `Votes` | `src/base/Votes.sol` | Vote casting, vote-eligibility, membership check. |
| `INFTVoting` | `src/base/INFTVoting.sol` | Shared enums/structs/events/errors — no logic. |
| `GovernanceERC721` | `src/erc721/GovernanceERC721.sol` | ERC-721 `Votes`-compatible governance token; independent contract, DAO-authorized, not clone-based. |

Inheritance: `NFTVoting is Votes is Proposal is Settings` (linearized single chain, each layer adding state +
logic on top of the last). `GovernanceERC721` is separate and only interacts with the plugin via the
`IVotesUpgradeable`/`IERC721Upgradeable`/ERC-165 interfaces.

## Actors

| Actor | Trust | Reachable entrypoints |
|---|---|---|
| DAO (via passing proposal / `EXECUTE_PERMISSION_ID` on itself) | trusted | `updateVotingSettings`, `updateVotingToken`, `setTargetConfig` (all `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` / DAO-mediated) |
| Whoever holds `CREATE_PROPOSAL_PERMISSION_ID` | semi-trusted (DAO-configured) | `createProposal` (both overloads) |
| Whoever holds `MINT_PERMISSION_ID` / `BURN_PERMISSION_ID` / `TRANSFER_PERMISSION_ID` / `UPDATE_BASE_URI_ID` on `GovernanceERC721` | semi-trusted (DAO-configured) | `mint`, `burn`, `adminTransfer`, `setBaseURI` |
| Any token holder with nonzero delegated voting power at a proposal's snapshot | untrusted | `vote()` |
| **Anyone at all** | untrusted | `execute(uint256)` — see Cross-Cutting Fact 1 below |
| Token holder (self) | untrusted | `transferFrom`/`safeTransferFrom`/`delegate`/`delegateBySig` (standard ERC-721/Votes surface, not separately analyzed here) |

## State (plugin-wide, mutable, vs. per-proposal, pinned)

This is the single most important structural fact this pass surfaced, confirmed independently by 6 of the 13
analyses (`Proposal_createProposal`, `Proposal_isSupportThresholdReachedEarly`, `Proposal_canExecute`,
`Settings_updateVotingToken`, `Votes_vote`, `Votes_canVote`):

- **Pinned at `createProposal` time**, into `proposal_.parameters` (`Proposal.sol:312-320`), and never rewritten
  afterward (confirmed by grep — no other writer exists): `votingMode`, `supportThreshold`, `startDate`,
  `endDate`, `snapshotTimepoint`, `votingToken` (address), `minVotingPower`; also `proposal_.minApprovalPower`,
  `proposal_.targetConfig`.
- **Live, plugin-wide, mutable at any time** via `Settings`: `votingSettings` struct, `votingToken` (the
  contract-level variable — distinct from the per-proposal pinned copy of the same name), `tokenIndexedByTimestamp`.
- **Every per-proposal voting-power/eligibility read** (`Proposal.execute` L45, `isSupportThresholdReachedEarly`
  L163, `Votes._vote` L34/L100, `Votes._canVote` L100) reads the **pinned** `proposal_.parameters.votingToken`,
  never the live `votingToken`. This is what makes `updateVotingToken` mid-flight safe for existing proposals —
  confirmed independently by both the `Settings_updateVotingToken` and `Proposal_isSupportThresholdReachedEarly`
  passes, which each walked every read site.
- Consumers of the **live** state instead (by design, forward-looking only): `getVotingToken`, `totalVotingPower`,
  `canCreateProposal`, `createProposal` (at the moment of pinning), `_updateVotingSettings`'s own
  `minProposerVotingPower` check, `Votes.isMember`.

## Entrypoints and what gates them

| Function | Gate found | Notes |
|---|---|---|
| `NFTVoting.initialize` | `initializer` (OZ `Initializable`) | One-shot per clone; see Cross-Cutting Fact 3. |
| `Settings.updateVotingSettings` | `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` | |
| `Settings.updateVotingToken` | `auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)` | Same permission gates both settings and token swap. |
| `Proposal.createProposal` (5-arg) | `auth(CREATE_PROPOSAL_PERMISSION_ID)` + `canCreateProposal` check | |
| `Proposal.createProposal` (`bytes _data` overload) | Delegates to the 5-arg overload (same gate) | |
| `Proposal.execute` | **Nothing found** | See Cross-Cutting Fact 1. |
| `Votes.vote` | `_canVote` (voting-power + state check, not a DAO permission) | Permissionless by design — gated by holding power, not by a granted permission ID. |
| `GovernanceERC721.mint` | `auth(MINT_PERMISSION_ID)` | |
| `GovernanceERC721.burn` | `auth(BURN_PERMISSION_ID)` | |
| `GovernanceERC721.adminTransfer` | `auth(TRANSFER_PERMISSION_ID)` | Bypasses holder approval, not ownership (`_transfer` still requires `_from` to own the token). |
| `GovernanceERC721.setBaseURI` | `auth(UPDATE_BASE_URI_ID)` | |

---

## Cross-cutting facts worth carrying into the hunting phase

**1. `EXECUTE_PROPOSAL_PERMISSION_ID` is declared but never checked anywhere in `src/`.**
Confirmed independently by both the `Proposal_execute` and `Proposal_canExecute` passes via full-repo grep:
the constant is declared at `Proposal.sol:27` and appears nowhere else. `execute(uint256)` (`Proposal.sol:43-55`)
carries no `auth(...)` modifier and no other access check — its only gates are `_canExecute()` and a
nonzero-voting-power check on `_msgSender()`. Contrast with `createProposal` (`auth(CREATE_PROPOSAL_PERMISSION_ID)`)
and `updateVotingSettings`/`updateVotingToken` (`auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)`), which do have
modifiers. Whether this is intentional (execution meant to be permissionless, permission ID vestigial) or an
unwired gate is an open question — nothing in `src/` resolves it either way.

**2. `EarlyExecution`'s soundness rests on an assumption established in a different file than the one that
uses it.** `isSupportThresholdReachedEarly` (`Proposal.sol:161-170`) is only sound if already-cast
`tally.yes`/`tally.abstain` can't decrease before `endDate`. That's not guaranteed anywhere in `Proposal.sol`
— it's guaranteed by `Votes._canVote` (`Votes.sol:118-123`) refusing a second vote whenever
`votingMode != VoteReplacement`. Both are `virtual`; an override of `_canVote`/`_vote` in a derived contract
that reintroduces vote retraction under `EarlyExecution` would silently break `isSupportThresholdReachedEarly`'s
premise without touching `Proposal.sol` at all. Flagged by both `Proposal_canExecute` and `Votes_vote`.

**3. Two independent "does this proposal exist" sentinels, not cross-checked.** `_proposalExists`
(`Proposal.sol:378-380`, used by `onlyIfProposalExists`/`isMinParticipationReached`/`isMinApprovalReached`) keys
off `parameters.snapshotTimepoint != 0`. `_isProposalOpen` (used by `_canVote`, `_canExecute`) keys off
`endDate` being in the currently-open window, which is `false` for a zero-initialized (never-created) proposal
because `endDate == 0`. Both fields are written together at creation (`Proposal.sol:312-314`) so they currently
agree, but nothing structurally ties them — confirmed as a live open question by `Votes_canVote`,
`Proposal_execute`, and `Proposal_canExecute` independently. Also: `execute(uint256)` itself has no
`onlyIfProposalExists` guard (unlike `canExecute`/`hasSucceeded`), relying entirely on this indirect
zero-initialization argument.

**4. `getPastVotes`/`getPastTotalSupply` determinism-across-calls is trusted, never verified.** Multiple
functions (`Votes._vote`, `Votes._canVote`, `Proposal.isSupportThresholdReachedEarly`) call the same
`(account/none, snapshotTimepoint)` pair on the pinned voting token more than once per transaction and assume
identical results each time. True for the in-repo `GovernanceERC721` (checkpoint-based, immutable once past),
but `Settings._updateVotingToken`'s admission check is ERC-165 self-report only (`Settings.sol:196-203`) — it
never verifies actual checkpoint-accounting correctness. A token that passes the two interface checks but
lies about past-vote determinism would violate assumptions in at least three functions at once. Flagged
independently by `Votes_vote`, `Votes_canVote`, and `Proposal_isSupportThresholdReachedEarly`.

**5. `minProposerVotingPower`'s bound is checked at most once, against a point-in-time supply figure, and
never on the very first call.** `_updateVotingSettings`'s upper-bound check on `minProposerVotingPower`
(`Settings.sol:155-159`) is gated by `votingSettings.maxBoundDate != 0` — which is unconditionally `false`
during `NFTVoting.initialize` (fresh clone storage), so **no bound is enforced at genesis**, only from the
second call onward. Even when checked, it compares against aggregate total supply, not what any individual
account can reach (`Proposal.canCreateProposal` compares per-account power) — so passing the check says
nothing about the setting being reachable by anyone. Independently confirmed by `NFTVoting_initialize` and
`Settings_updateVotingSettings`.

**6. `maxBoundDate` has no upper bound, and is reused for two additive (not shared) purposes.**
`_updateVotingSettings` only requires `maxBoundDate >= minDuration` (`Settings.sol:136-138`) — no ceiling.
`_validateProposalDates` (`Proposal.sol`) uses it once to bound how far in the future `startDate` may be set
(L405-407) and again, independently, to bound `endDate - startDate` (L425-429). These compose additively:
worst case `endDate` can reach `currentTimestamp + 2*maxBoundDate`. Flagged by `Proposal_validateProposalDates`
and `Settings_updateVotingSettings` from two different angles (date arithmetic vs. settings bounds).

**7. Auto-self-delegation can silently reverse an explicit opt-out, triggerable by a third party.**
`GovernanceERC721._afterTokenTransfer` (`L161-172`) self-delegates any receiver whose `delegates(to)` reads
`address(0)`. OZ's `VotesUpgradeable` storage cannot distinguish "never delegated" from "explicitly delegated
to `address(0)`" (same zero value, no separate opt-out flag — confirmed by reading `VotesUpgradeable.sol`
directly). A holder who opts out this way has it silently reversed the next time *anyone* sends them a new
token — via ordinary `transferFrom`/`safeTransferFrom` (sender-initiated, receiver passive), `adminTransfer`,
or `mint` — with no cooperation or awareness required from the holder. Confirmed by
`GovernanceERC721_afterTokenTransfer`.

**8. Clone-vs.-`new` deployment split is real and changes what "initializer" protects.** `NFTVoting` is
deployed as an EIP-1167 minimal-proxy clone (`PluginCloneable`), so `_disableInitializers()` in its
implementation contract's constructor locks only the *implementation*, never the clones — clone-level
protection against front-running an uninitialized clone rests entirely on whatever deployment path is used to
clone-and-call-initialize atomically (confirmed in-repo only for `script/InstallNFTVoting.s.sol`'s
`ProxyFactory`/`ProxyLib` path; no `IPluginSetup`/`PluginSetupProcessor`-based install path exists in `src/` to
verify against). `GovernanceERC721`, by contrast, is deployed via `new` with `initialize()` called from its own
constructor immediately before `_disableInitializers()` — for this contract, `_disableInitializers()` **does**
fully lock the exact deployed instance, no external atomicity assumption required. Don't conflate the two
initializer stories. Confirmed by `NFTVoting_initialize` and `GovernanceERC721_initialize`.

**9. Minor cross-agent inconsistency, noted rather than resolved:** the `Votes_canVote` analysis, working only
from `Votes.sol`/`Proposal.sol`/`INFTVoting.sol` (plus a grep of `Settings.sol` limited to `minDuration`),
stated it found no setter for `votingToken` and flagged that as an open question. `Settings_updateVotingToken`
and `Proposal_createProposal` (which read `Settings.sol` in full) confirm the setter is
`Settings.updateVotingToken`/`_updateVotingToken` (`Settings.sol:178-210`). Not a contradiction about the code
— just an artifact of one pass's narrower read scope. Included per the instruction to quote disagreements
rather than quietly reconcile them.

---

## Fragility clusters (where the complexity concentrates)

1. **The pinned-vs-live split** (state table above) is the load-bearing mechanism that makes `updateVotingToken`
   and `updateVotingSettings` safe to call with open proposals. It is correct everywhere checked in this pass,
   but it is an emergent property of every read site individually choosing the right field — there is no single
   enforced rule (e.g. a type system distinction) preventing a future change from reading the live variable
   where the pinned one belongs.
2. **The `EarlyExecution` support-threshold math** (`isSupportThresholdReachedEarly`) is sound only under a
   chain of assumptions spanning three files (`Proposal.sol`'s arithmetic, `Votes.sol`'s vote-monotonicity
   enforcement, and the external token's checkpoint correctness) — see Facts 2 and 4.
3. **Two unlinked existence/openness sentinels** (Fact 3) plus **one entrypoint (`execute`) that checks
   neither directly** is a cluster worth the hunting phase's attention even though this pass found no concrete
   break — it found only that the safety argument is indirect everywhere it was traced.

## Open questions carried forward (not resolved by this pass)

- Whether `EXECUTE_PROPOSAL_PERMISSION_ID` is dead/vestigial by design or an unwired gate (Fact 1).
- Whether any deployment path other than `script/InstallNFTVoting.s.sol` preserves clone-then-initialize
  atomicity for `NFTVoting` (Fact 8).
- Whether any realistic ERC-6372 token would defeat `Settings._detectTokenClock`'s two-value
  (`block.timestamp`/`block.number`) classification.
- Whether `block.number == 1` / `block.timestamp == 1` is reachable on any real or test deployment target,
  which would make `_proposalExists`'s `snapshotTimepoint != 0` sentinel collide with a genuine proposal
  (`Proposal_createProposal`).
- Whether `_settings.receivers.length` (GovernanceERC721 constructor) is bounded by any deployment tooling
  outside `src/` — unbounded, its only failure mode is a reverted (atomic, non-corrupting) deployment.
- Whether other code (not found in `src/`) relies on `delegates(account) == address(0)` as a durable opt-out
  signal that Fact 7's re-triggering would break.

## Per-function analyses index

All under `audit-context/functions/`:
`NFTVoting_initialize.md` · `Proposal_createProposal.md` · `Proposal_validateProposalDates.md` ·
`Proposal_execute.md` · `Proposal_canExecute.md` · `Proposal_isSupportThresholdReachedEarly.md` ·
`Votes_vote.md` · `Votes_canVote.md` · `Settings_updateVotingSettings.md` · `Settings_updateVotingToken.md` ·
`GovernanceERC721_afterTokenTransfer.md` · `GovernanceERC721_initialize.md` ·
`GovernanceERC721_adminTransfer.md`
