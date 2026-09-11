# X-Ray Report

> NFTVoting Plugin | 576 nSLOC | `d1a0635` (`main`) | Foundry | 29/08/26

Analyzed branch: `main` at `d1a0635`.

---

## 1. Protocol Overview

**What it does:** An Aragon OSx governance plugin where voting power is one-NFT-one-vote, sourced from an OpenZeppelin `Votes`-compatible ERC-721 token, with support/participation/min-approval thresholds and three voting modes.

- **Users**: NFT holders / delegates cast votes; a permissioned "proposer" opens proposals; anyone can execute a passed proposal; the managing DAO administers settings and the token.
- **Core flow**: `createProposal` (snapshots voting power at `block-1`) → `vote` (Yes/No/Abstain, optionally with early execution) → `execute` (runs the proposal's `Action[]` through the DAO).
- **Key mechanism**: Majority voting — support criterion `(RATIO_BASE - supportThreshold)·yes > supportThreshold·no`, participation `yes+no+abstain >= minVotingPower`, min approval `yes >= minApprovalPower`; thresholds applied as ceiled ratios of the creation-time total supply.
- **Token model**: `GovernanceERC721` — ERC721Votes, ids start at 1 and are never reused, auto self-delegation on mint/transfer so every NFT counts without a user action; DAO holds `MINT`/`BURN`/`TRANSFER` permissions (`adminTransfer` force-moves a token).
- **Admin model**: The managing Aragon DAO holds `UPDATE_VOTING_SETTINGS_PERMISSION` on the plugin and the three token permissions. `CREATE_PROPOSAL_PERMISSION` is granted to `ANY_ADDR` behind `VotingPowerCondition`; `EXECUTE_PROPOSAL_PERMISSION` is granted to `ANY_ADDR`. No timelock, no proxy upgrade path (plugin is a `PluginCloneable` minimal proxy; "upgrade" = DAO uninstall + reinstall).

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Voting plugin | `NFTVoting` | 452 | Proposal lifecycle, tally, support/participation/approval math, ERC-6372 clock detection |
| Create gate | `VotingPowerCondition` | 34 | Aragon `PermissionCondition` — blocks `createProposal` unless caller's snapshot voting power ≥ `minProposerVotingPower` |
| Governance token | `GovernanceERC721` | 90 | ERC721Votes token, sequential ids, auto self-delegation, DAO-gated mint/burn/force-transfer |

Interfaces (`INFTVoting`, `IERC721MintableUpgradeable`) excluded from scope.

### How It Fits Together

The core trick: voting power is frozen at a strictly-past timepoint (`block.number - 1` or `block.timestamp - 1`) at proposal creation, so all tally math runs against an immutable census while votes are still mutable.

### createProposal (Proposer, via VotingPowerCondition)

```
Proposer.createProposal(metadata, actions[], allowFailureMap, startDate, endDate, voteOption, tryEarlyExecution)
  ├─ DAO.PermissionManager → VotingPowerCondition.isGranted()   — reverts if snapshot VP < minProposerVotingPower
  ├─ snapshotTimepoint = (tokenIndexedByTimestamp ? block.timestamp : block.number) - 1   — immutable census
  ├─ totalVotingPower_ = votingToken.getPastTotalSupply(snapshotTimepoint)   — reverts if 0
  ├─ proposalId = _createProposalId(keccak256(abi.encode(actions, metadata)))
  │    └─ require(proposal_.parameters.snapshotTimepoint == 0)   — one identical (actions, metadata) ever
  ├─ minVotingPower  = _applyRatioCeiled(totalVotingPower_, minParticipation())
  ├─ minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApproval())
  └─ if voteOption != None → vote(proposalId, voteOption, tryEarlyExecution)
```

*`minVotingPower` / `minApprovalPower` are snapshotted here; later `updateVotingSettings` does not affect live proposals.*

### vote (Voter — permissionless, gated by snapshot voting power)

```
Voter.vote(proposalId, voteOption, tryEarlyExecution)
  ├─ _canVote()  — proposal open, option != None, getPastVotes(voter, snapshot) > 0, not already-voted-unless-VoteReplacement
  └─ _vote()
       ├─ votingPower = votingToken.getPastVotes(voter, snapshot)   — EXTERNAL call before state writes
       ├─ subtract votingPower from prior bucket (yes/no/abstain) if voter had voted
       ├─ add votingPower to new bucket
       ├─ proposal_.voters[voter] = voteOption
       └─ if tryEarlyExecution && _canExecute() && DAO.hasPermission(this, voter, EXECUTE_PROPOSAL_PERMISSION_ID) → _execute()
```

*`getPastVotes` is an external call to a token supplied at init; tally writes happen after it. Comment at NFTVoting.sol:168 acknowledges re-entry and assumes a non-malicious token.*

### execute (Executor — `auth(EXECUTE_PROPOSAL_PERMISSION_ID)`, granted to `ANY_ADDR`)

```
Executor.execute(proposalId)
  ├─ _canExecute()  — not executed; for non-EarlyExecution modes proposal must be closed; _hasSucceeded()
  └─ _execute(proposalId)
       ├─ proposal_.executed = true                    — set BEFORE external call
       └─ ProposalUpgradeable._execute(target, id, actions, allowFailureMap, operation)
            └─ DAO.execute(...)  → runs Action[] as Call or DelegateCall on targetConfig.target
```

### GovernanceERC721 transfer / mint

```
mint(to)  [auth MINT]   → _mintTo → tokenId = ++nextTokenId → _mint(to, id)
transferFrom(from,to,id) [holder]      ─┐
adminTransfer(from,to,id) [auth TRANSFER]├─→ _transfer → _afterTokenTransfer
                                         └─→ super._afterTokenTransfer (moves voting units)
                                             └─ if to != 0 && delegates(to) == 0 → _delegate(to, to)   — auto self-delegation
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Governance** with **Liquid-Staking-style exchange-unit** characteristics (one-NFT-one-vote census + delegation).

Signals: `createProposal()` / `vote()` / `execute()`, quorum + support-threshold math, `getPastVotes` / `getPastTotalSupply` snapshot voting power, delegation, `Action[]` execution through a DAO. No borrowing/AMM/oracle signals — the only external price-like input is the voting token's vote accounting.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Managing DAO | Trusted (is the governance target) | `updateVotingSettings`, `updateMinApprovals` (instant, no timelock); token `mint` / `burn` / `adminTransfer` (instant). Can force-move voting NFTs and reshape thresholds between proposals. Not subject to any pause. |
| Proposer (`ANY_ADDR` + `VotingPowerCondition`) | Bounded (needs snapshot VP ≥ `minProposerVotingPower`; if that is 0, fully permissionless) | Open proposals with arbitrary `Action[]` / `allowFailureMap`, choose `startDate` / `endDate` (≥ `minDuration`), optionally self-vote + early-execute. |
| Voter (`ANY_ADDR`) | Bounded (needs `getPastVotes(voter, snapshot) > 0`) | Cast / (in VoteReplacement) change Yes/No/Abstain; trigger early execution if holding `EXECUTE_PROPOSAL_PERMISSION`. |
| Executor (`ANY_ADDR`) | Bounded (proposal must satisfy `_canExecute`) | Execute any passed proposal's actions through the DAO; pick execution timing. |
| Voting token | Trusted (assumed honest `IVotes`; only ERC-165 `IERC721` checked at init) | Supplies `getPastVotes` / `getPastTotalSupply` — the numerators and denominator of every criterion. |

**Adversary Ranking:**

1. **Malicious / non-standard voting token** — supplied once at `initialize`, only ERC-165-`IERC721`-checked; it is the sole source of all vote weights and the quorum denominator.
2. **Misconfiguring DAO / governance-parameter attacker** — thresholds are only range-checked, not floored; a DAO (or a passed proposal) can set `supportThreshold` / `minParticipation` / `minApprovals` to 0.
3. **Proposal griefer** — permissionless `createProposal` (when `minProposerVotingPower == 0`) plus deterministic proposal ids derived from `(actions, metadata)`.
4. **Front-running voter / early-execution racer** — `vote` and `execute` are permissionless; early execution resolves inside `_vote`.
5. **DAO key holder** — instant `adminTransfer` of voting NFTs and instant settings changes, no delay.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Plugin → voting token** — `NFTVoting.initialize:100` checks only `supportsInterface(IERC721)`; every tally/quorum read (`getPastVotes` NFTVoting.sol:169,276; `getPastTotalSupply` NFTVoting.sol:144) trusts it. No timelock, no re-validation, token is immutable post-init.
- **DAO → plugin settings** — `updateVotingSettings` / `updateMinApprovals` are `auth`-gated to the DAO and execute instantly; only live proposals (already snapshotted) are insulated.
- **DAO → voting NFTs** — `TRANSFER_PERMISSION_ID` allows `adminTransfer` with no holder approval and no delay; snapshot protects open proposals but not proposals created afterward.
- **Proposer/Executor = `ANY_ADDR`** — the install script grants `CREATE_PROPOSAL_PERMISSION` (behind `VotingPowerCondition`) and `EXECUTE_PROPOSAL_PERMISSION` to `ANY_ADDR`; the condition is the only barrier on proposal creation.

*Git signal: `9ebe8b7` "feat(dao): reduce code" removes 3 runtime guards (+0/-3); `d1a0635` rewrites guards (+1/-1) and loosens access control (+1/-2) — elevated risk on the current scope.*

### Key Attack Surfaces

- **Voting-token trust boundary** &nbsp;&#91;[X-3](invariants.md#x-3), [X-4](invariants.md#x-4)&#93; — `NFTVoting.initialize:100` accepts any ERC-165-`IERC721`; `_vote:169`, `_canVote:276`, `totalVotingPower:144` consume its return values directly. Worth tracing what a token with reentrant views, a manipulable `getPastTotalSupply`, or a timestamp/block-number clock ambiguity does to the tally and to `isSupportThresholdReachedEarly`.

- **Unbounded governance parameters** &nbsp;&#91;[I-2](invariants.md#i-2), [I-3](invariants.md#i-3), [E-1](invariants.md#e-1)&#93; — `_updateVotingSettings:485-501` only range-checks ratios; README states the ≥50% majority assumption is "not enforced by the contract code". Worth confirming whether a DAO with `supportThreshold = 0` / `minParticipation = 0` / `minApprovals = 0` lets a single Yes vote pass a proposal.

- **`_vote` external call before tally writes** &nbsp;&#91;[X-3](invariants.md#x-3)&#93; — NFTVoting.sol:169 reads `getPastVotes` from the external token before updating `proposal_.tally` (:183-188) and `proposal_.voters[_voter]` (:190). Worth checking a hookable/malicious token re-entering `vote()` to double-count within one snapshot, and the early-execution branch (:198-203) re-entering `_execute`.

- **Early-execution worst-case subtraction** &nbsp;&#91;[X-4](invariants.md#x-4)&#93; — `isSupportThresholdReachedEarly:378-379` computes `totalVotingPower(snapshot) - tally.yes - tally.abstain`. Worth confirming this cannot revert (DoS on early execution / `hasSucceeded`) when a custom token's `getPastTotalSupply` is below the summed `getPastVotes` of voters.

- **Deterministic proposal ids** &nbsp;&#91;[I-9](invariants.md#i-9), [G-8](invariants.md#g-8)&#93; — `createProposal:578` derives the id from `keccak256(abi.encode(_actions, _metadata))`; `:583` reverts `ProposalAlreadyExists` if that id was ever used. Worth checking whether an attacker front-running with the same `(actions, metadata)` permanently blocks a legitimate proposal or a recurring identical governance action.

- **Permissionless `createProposal` action surface** — proposer supplies `_actions`, `_allowFailureMap`, `_startDate`, `_endDate`; `execute` then runs those actions as `Call` or `DelegateCall` on `targetConfig.target` (DAO by default). Worth tracing the `allowFailureMap` handling and whether `targetConfig.operation == DelegateCall` is reachable in this install.

- **DAO force-transfer of voting NFTs** &nbsp;&#91;[I-13](invariants.md#i-13)&#93; — `GovernanceERC721.adminTransfer:138` moves any token without approval; `_afterTokenTransfer:164` then auto-self-delegates the receiver. Worth tracing the census impact of the DAO reassigning NFTs immediately before a `createProposal` snapshot.

- **Uninitialized `NFTVoting` clone base** — `InstallNFTVoting.s.sol:_deployPlugin` deploys `new NFTVoting()` as the minimal-proxy base with no constructor `_disableInitializers()`. Blast radius is limited for `PluginCloneable` (no delegatecall/upgrade to the base), but worth confirming no `selfdestruct`/`delegatecall` path exists on the base implementation.

### Upgrade Architecture Concerns

- **No proxy upgrade path** — the plugin is a `PluginCloneable` minimal proxy; commit `60176f3` removed UUPS ("install/uninstall does the trick"). "Upgrading" the plugin is a DAO governance action (uninstall + reinstall), which drops all proposal state. `GovernanceERC721` inherits OZ *Upgradeable* bases but is deployed as a plain contract (constructor calls `initialize`); worth confirming the `initializer`-in-constructor pattern fully locks re-init and that `__gap` sizing is irrelevant since there is no proxy.

### Protocol-Type Concerns

**As Governance:**
- `isSupportThresholdReached:371-372` and `...Early:381-382` use cross-multiplication with `RATIO_BASE - supportThreshold`; with `supportThreshold` near `RATIO_BASE-1` the `yes` side coefficient is 1 — worth checking rounding/degenerate behavior at the extremes and when `tally.no == 0`.
- `_applyRatioCeiled(totalVotingPower_, ratio)` (NFTVoting.sol:592-594) is ceiled — for tiny electorates (e.g. `totalVotingPower_ == 1`) any non-zero `minParticipation` ceils `minVotingPower` to 1, so a single vote always satisfies participation; worth confirming this matches intent.
- Vote weight is read per-call from `getPastVotes(voter, snapshot)`; because the snapshot is fixed, a voter's weight is stable across a VoteReplacement change — the subtract/add pair in `_vote:174-188` relies on that. Worth confirming no path lets `snapshot` differ between two `_vote` calls for the same proposal.

### Temporal Risk Profile

**Deployment & Initialization:**
- `NFTVoting.initialize` is invoked atomically inside `deployMinimalProxy(abi.encodeCall(...))` — not front-runnable. `GovernanceERC721.initialize` runs in the constructor — atomic. Empty-state is handled: `createProposal` reverts `NoVotingPower` when `getPastTotalSupply == 0` (G-7).
- `_detectTokenClock:708-727` reverts `TokenClockMismatch` if the token's ERC-6372 `CLOCK_MODE()` string and `clock()` value disagree; a token that implements neither defaults to block-number indexing. Worth confirming a token that implements only one of the two is handled as intended.

**Market Stress** *(governance-specific)*:
- No timelock between "proposal passes" and "actions execute" — for `EarlyExecution` mode the actions can run the instant the worst-case support criterion flips, inside the same `vote` transaction. Users cannot exit / react.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **17 Enforced Guards** (`G-1` … `G-17`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **13 Single-Contract Invariants** (`I-1` … `I-13`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **4 Cross-Contract Invariants** (`X-1` … `X-4`) — plugin ↔ token, condition ↔ plugin/token
> - **2 Economic Invariants** (`E-1` … `E-2`) — pass criteria, flash-loan-governance resistance
>
> The **On-chain=No** blocks (X-3, X-4, and the parameter-floor gap around I-2/I-3) are the high-signal ones. Attack-surface bullets above cross-link into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` — thorough math spec of support/participation/early-execution criteria (per spec) |
| NatSpec | ~104 tags in `NFTVoting`, ~40 in `GovernanceERC721`, ~7 in `VotingPowerCondition` | Most external/public functions and structs documented; a few (`vote`, `getVotingToken` overrides) thin |
| Spec/Whitepaper | Present (in README) | Voting-mode semantics and early-execution derivation are spelled out with formulae |
| Inline Comments | Adequate | Good on snapshot rationale and self-delegation; the `updateMinApprovals` bounds comment is copy-pasted from `minParticipation` ("participation criterion") |

Claims tagged `(per spec)` above are from README math, not re-derived from code.

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 4 (+3 helper/mocks) | File scan (always reliable) |
| Test functions | 25 | File scan (always reliable) |
| Line coverage | Unavailable — `forge coverage --ir-minimum` fails to compile (`Yul exception: ... too deep in the stack` at `NFTVoting.sol:603`) | Coverage tool |
| Branch coverage | Unavailable — same reason | Coverage tool |

Plain `forge test` compiles and runs: 21 unit tests pass; 1 fork test (`InstallNFTVoting.t.sol`) fails only because env var `RPC_URL` is unset — not a code defect.

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 21 | `NFTVoting`, `GovernanceERC721`, `VotingPowerCondition` (broad — settings bounds, tally, delegation, early execution, vote replacement, membership, interface ids) |
| Fork | 1 (currently failing on missing `RPC_URL`) | Full install → create → vote → execute cycle via real `DAOFactory` |
| Stateless Fuzz | 0 | none |
| Stateful Fuzz (Foundry / Echidna / Medusa) | 0 | none |
| Formal Verification (Certora / Halmos / HEVM) | 0 | none |

### Gaps

- **No fuzz or invariant testing** of the support/participation/approval arithmetic — cross-multiplication in `isSupportThresholdReached*`, ceiled-ratio snapshots, and the `_vote` subtract/add tally are the highest-value fuzz targets and are untested.
- **No adversarial-token test** — every test uses the honest `GovernanceERC721` / `MockGovernanceERC721`; the trust assumption on `IVotes` (X-3, X-4) is unexercised.
- **No test for `supportThreshold = 0` / `minParticipation = 0` / `minApprovals = 0`** parameter regimes.
- Fork test is not runnable in CI as configured (needs `RPC_URL`).

---

## 6. Developer & Git History

> Repo shape: normal_dev — 174 commits over 443 days (2025-06-11 → 2026-08-28), 38 source-touching. The repo began as `osx-plugin-template-foundry` with an ERC-20 `TokenVoting` lineage; the in-scope NFT plugin is the product of an August-2026 rewrite that merged the multi-file plugin into one contract and swapped ERC-20 voting power for ERC-721.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Jør∂¡ | 156 | +3839 / -1361 | ~80% |
| NicoSerranoP | 12 | +986 / -2129 | ~20% (net remover — the consolidation work) |
| Evan Aronson / jjavieralv / Carlos Juar.eth | 1–4 each | minor | <1% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 5 (2 material) | Small team |
| Merge commits | 24 of 174 (14%) | Some PR flow, but most source commits landed directly |
| Repo age | 2025-06-11 → 2026-08-28 | ~14.5 months |
| Recent source activity (30d) | 8 source commits | Late burst — the entire in-scope NFT design landed in the last ~3 weeks |
| Test co-change rate | 57.9% | 57.9% of source-changing commits also touched tests (co-modification, not coverage) |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| `src/TokenVoting.sol` | 14 | Deleted — ERC-20 predecessor of `NFTVoting` |
| `src/erc20/GovernanceERC20.sol` | 12 | Deleted — predecessor of `GovernanceERC721` |
| `src/TokenVotingSetup*.sol` | 11 each | Deleted — replaced by `script/InstallNFTVoting.s.sol` |
| `src/base/MajorityVotingBase.sol` | 10 | Deleted — logic folded into `NFTVoting` |
| `src/condition/VotingPowerCondition.sol` | 5 | **In scope** — carried through the rewrite, lightly changed |

The current in-scope files (`NFTVoting.sol`, `GovernanceERC721.sol`) are new enough that churn concentrates in their now-deleted ancestors — history depth on the exact shipping code is shallow.

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| `d1a0635` | 2026-08-28 | feat(plugin): use NFTs for unique voting | 12 | rewrites guards (+1/-1), loosens access control (+1/-2), changes accounting + signature/auth handling, >500 lines, net removal |
| `9ebe8b7` | 2026-08-12 | feat(dao): reduce code | 9 | removes runtime guards (+0/-3), changes auth + accounting |
| `b6b8c5d` | 2026-08-07 | feat(plugin): simplyfing plugin code | 8 | changes transfer + auth + accounting, net removal |
| `97b8783` | 2025-06-11 | Initial commit from osx-plugin-template-foundry | 8 | template baseline |
| `60176f3` | 2026-08-06 | remove UUPS because install/uninstall does the trick | 7 | loosens access control (+1/-2), removes upgrade path |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 1 | `src/erc721/GovernanceERC721.sol` (`d1a0635`) |
| signatures / auth | 1 | `src/erc721/GovernanceERC721.sol` (`d1a0635`) |

### Forked Dependencies

All dependencies are git submodules, not internalized: `openzeppelin-contracts`, `openzeppelin-contracts-upgradeable`, `osx`, `osx-commons`, `ens-contracts`. The reported pragma "mismatches" on the OZ submodules are the normal spread of OZ's own pragmas across files — no evidence of local modification. `lib/plugin-version-1.1/1.2/1.3` submodules were removed during the rewrite.

### Security Observations

- **Late-burst rewrite** — the entire in-scope design (NFT voting + single-contract consolidation) landed in ~3 weeks of August 2026 across `d1a0635`, `bcae63e`, `9ebe8b7`, `cfca664`; little settling time.
- **Guard removal trend** — `9ebe8b7` deletes 3 runtime guards, `d1a0635` and `60176f3` each net-loosen access control; the direction of recent change is toward fewer checks.
- **Two-dev concentration** — Jør∂¡ (~80%) + NicoSerranoP (~20%) account for essentially all source; the NFT-specific logic is one author's recent work.
- **Shallow history on shipping code** — churn metrics point at deleted ERC-20 ancestors; `NFTVoting.sol` / `GovernanceERC721.sol` have few revisions of their own.
- **UUPS removed** — `60176f3` drops the upgrade path in favor of DAO uninstall/reinstall; acceptable but means no in-place fix mechanism.
- **Fork test not CI-runnable** — depends on `RPC_URL`; the one end-to-end install/vote/execute test does not run in the default `forge test`.
- **Dependencies are clean submodules** — no internalized/forked library code to review for divergence.

### Cross-Reference Synthesis

- **`d1a0635` touches both `fund_flows` and `signatures` in `GovernanceERC721`** → the auto-self-delegation + `adminTransfer` interaction (I-13, attack surface "DAO force-transfer") is exactly the code that changed last and is untested for adversarial sequencing.
- **`9ebe8b7` guard removal + no fuzz tests (§5)** → the support/participation arithmetic lost checks in the consolidation and has no property-based coverage; §3 flags I-2/I-3 parameter floors as the On-chain=No gap.
- **`VotingPowerCondition.sol` is the only in-scope file with real history depth (5 mods)** and it reads live plugin config (X-1) → verify no proposal-creation gate bypass when `minProposerVotingPower` is changed mid-flight.

---

## X-Ray Verdict

**FRAGILE** — Unit tests exist and are broad, but there is no fuzz, invariant, or formal coverage of the voting arithmetic; docs are strong; access control has clear roles but no timelock and key operational powers (settings, force-transfer) are instant.

**Structural facts:**
1. 576 nSLOC across 3 in-scope contracts (`NFTVoting` 452, `GovernanceERC721` 90, `VotingPowerCondition` 34); one Aragon OSx plugin plus its token and create-gate.
2. 25 test functions in 4 files; 21 unit tests pass, 1 fork test blocked on `RPC_URL`; 0 fuzz / 0 invariant / 0 formal-verification tests; `forge coverage --ir-minimum` cannot compile (stack too deep).
3. No proxy upgrade path — plugin is a `PluginCloneable` minimal proxy; UUPS was removed in `60176f3`.
4. The managing DAO holds all admin powers (`updateVotingSettings`, `updateMinApprovals`, token `mint`/`burn`/`adminTransfer`) with no timelock; `createProposal` (behind `VotingPowerCondition`) and `execute` are granted to `ANY_ADDR`.
5. Two developers wrote ~100% of source; the entire in-scope NFT design landed in the last ~3 weeks of history, with recent commits net-removing guards.
