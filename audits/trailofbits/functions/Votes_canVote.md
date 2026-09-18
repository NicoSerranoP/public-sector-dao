## `_canVote` in src/base/Votes.sol (L93-126)

**Purpose:** Gates every vote cast. It is the sole authorization check invoked by the state-changing entry
point `vote()` (L15-22) before `_vote()` (L29-72) is allowed to mutate the tally and the per-voter record. It
also backs the read-only `canVote()` (L78-86). Without it, `vote()` would let anyone record a vote on any
proposal ID (existent or not), with any voting power, at any time, any number of times.

**Inputs & Assumptions:**
- `_proposalId` (uint256): identifies a slot in `proposals` (declared `Proposal.sol:L31`). Trust:
  **untrusted** — arbitrary caller-supplied value, not range-checked anywhere before use (L99).
- `_account` (address): the address whose voting eligibility is being evaluated. Trust: from `vote()`, this is
  always `_msgSender()` (`Votes.sol:L16`), i.e. the transaction's authenticated caller, so it cannot be spoofed
  through that path. `canVote()` (L78-86) is `public` and passes `_account` through unchecked, so a third
  party can query (but not act on) eligibility for any address.
- `_voteOption` (VoteOption): one of `None | Abstain | Yes | No` (`INFTVoting.sol:L30-35`). Trust: untrusted
  caller input, validated only for the `None` sentinel (L108-110).
- Implicit: `proposals[_proposalId]` storage (`ProposalParameters`, `Tally`, `voters` mapping — all defined
  `INFTVoting.sol:L76-104`); `block.timestamp` (via `_isProposalOpen`, `Proposal.sol:L252`); the external
  `votingToken`'s historical checkpoint state via `getPastVotes`.
- Precondition (documented, not enforced by this function): the doc comment states "It assumes the queried
  proposal exists" (L88). The function does **not** call `_proposalExists` (`Proposal.sol:L378-380`, which
  checks `snapshotTimepoint != 0`). Instead, non-existence is caught incidentally by `_isProposalOpen` — see
  Block-by-Block and Cross-Function Dependencies below for exactly why that holds.

**Outputs & Effects:**
- Pure boolean return, `view`, no state writes, no events.
- Two external calls to `proposal_.parameters.votingToken` (an `IVotesUpgradeable`): `getPastVotes` at L113,
  reached only if the proposal is open and the option is not `None`.

**Block-by-Block:**

```solidity
// L99-100
Proposal storage proposal_ = proposals[_proposalId];
IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);
```
- **What:** Binds a storage reference and wraps the stored token address (possibly `address(0)` for a
  never-created proposal) in the token interface.
- **Why here:** Needed by every later check; wrapping `address(0)` here is harmless because no call is made
  through `proposalVotingToken` yet.
- **Assumes:** nothing yet — no external call has occurred.
- **Establishes:** local aliases used by the rest of the function.
- **Depended on by:** L103, L113.

```solidity
// L102-105
// The proposal vote hasn't started or has already ended.
if (!_isProposalOpen(proposal_)) {
    return false;
}
```
- **What:** Rejects proposals that are not currently open.
- **Why here:** First gate, before any external call, so a non-existent or closed proposal never reaches the
  token call at L113.
- **Assumes:** `_isProposalOpen` returns `false` for a zero-initialized (never-created) `Proposal` struct.
  Traced in `Proposal.sol:L251-256`:
  `return proposal_.parameters.startDate <= currentTime && currentTime < proposal_.parameters.endDate && !proposal_.executed;`
  For a struct that was never written, `parameters.endDate == 0`. Since `currentTime = block.timestamp` is a
  realistic-chain value `> 0`, `currentTime < 0` is never true, so `_isProposalOpen` returns `false`.
  This is **not** an explicit non-existence check; it is an emergent property of `endDate` never being `0` for
  a real proposal. That, in turn, is guaranteed by `Settings.sol:L132-133`
  (`if (_votingSettings.minDuration < 60 minutes) revert ...`), which forces every configured `minDuration` to
  be `>= 1 hour`, combined with `Proposal.sol:L413` (`earliestEndDate = startDate + votingSettings.minDuration`)
  and `L415-421` (rejecting `_end < earliestEndDate`), so every created proposal's `endDate` is strictly
  greater than its `startDate`, which itself is `>= currentTimestamp` at creation time (L396-408) — never `0`
  on any real chain. The chain doing this gating is: `Settings` minDuration floor → `_validateProposalDates`
  → `endDate != 0` on creation → `_isProposalOpen` false for the zero struct → `_canVote` false. No single
  line in `_canVote` says "does this proposal exist"; the guarantee is inherited transitively.
- **Establishes:** for the rest of `_canVote`, the proposal is open — `startDate <= now < endDate` and not
  executed — hence (by the argument above) it also exists.
- **Depended on by:** L113 (the token call is otherwise made against a proposal whose `votingToken` could be
  `address(0)` with no code, which would make `getPastVotes` — a `view` call compiled as `STATICCALL` returning
  no code — fail to decode a `uint256` and revert; this line prevents that call from ever being reached for a
  non-existent proposal, converting what would be a revert into a clean `false`).

```solidity
// L107-110
// The voter votes `None` which is not allowed.
if (_voteOption == VoteOption.None) {
    return false;
}
```
- **What:** Rejects the `None` sentinel as an explicit vote choice.
- **Why here:** Placed after the open-check (cheap check first would be equally valid; order here does not
  interact with later checks) and before the two checks that read voter-specific state.
- **Assumes:** `VoteOption.None == 0` is reserved to mean "has not voted" elsewhere (`_vote` L38, `voters`
  mapping default). Confirmed: `INFTVoting.sol:L31` lists `None` first, i.e. value `0`, matching Solidity's
  mapping default for the enum.
- **Establishes:** `_voteOption ∈ {Abstain, Yes, No}` for the remainder of the function.
- **Depended on by:** L118-123 (the replacement check below reasons about `proposal_.voters[_account]`, a
  value of the same enum type, and relies on `None` meaning "no vote cast").

```solidity
// L112-115
// The voter has no voting power.
if (proposalVotingToken.getPastVotes(_account, proposal_.parameters.snapshotTimepoint) == 0) {
    return false;
}
```
- **What:** Requires non-zero historical voting power for `_account` at the proposal's fixed
  `snapshotTimepoint` (set once at proposal creation, `Proposal.sol:L314`).
- **Why here:** After the cheaper checks, gating the (only) external call in this function.
- **Assumes:** `getPastVotes(account, snapshotTimepoint)` is a deterministic, immutable function of history —
  i.e. querying the same `(account, snapshotTimepoint)` pair again later (from `_vote`, L37, or from a later
  replacement-vote transaction) returns the identical value. This is a property of a correct checkpoint-based
  `Votes` token; the concrete token in this repo, `GovernanceERC721` (`src/erc721/GovernanceERC721.sol:L10-13`),
  inherits OpenZeppelin's `ERC721VotesUpgradeable`, which implements `getPastVotes` via immutable per-block
  checkpoints, satisfying this. **Nothing in `Votes.sol` or `Proposal.sol` enforces this property** for
  whatever address is stored in `proposal_.parameters.votingToken` — it is set from `address(votingToken)`
  (`Proposal.sol:L315`) at proposal-creation time and never re-validated. `_vote`'s own comment (`Votes.sol:L36`,
  "This could re-enter, though we can assume the governance token is not malicious") acknowledges the token is
  trusted rather than sandboxed.
- **Establishes:** `getPastVotes(_account, snapshot) > 0` at the moment of this call. Note: this checks
  historical power *at the snapshot*, not current live balance/delegation — a voter who has since transferred
  away or burned their tokens (zero *current* voting power) still passes this check and is not treated
  inconsistently, because `_vote` (L37) queries the exact same `(voter, snapshot)` pair rather than current
  power. Current-time voting power is never read by either function.
- **Depended on by:** the caller `vote()` → `_vote()`, whose tally arithmetic (L37-56) queries the identical
  `(voter, snapshotTimepoint)` pair again as a second, independent external call. The two calls agreeing is an
  assumption about the token, not something either function cross-checks (see Cross-Function Dependencies).

```solidity
// L117-123
// The voter has already voted but vote replacment is not allowed.
if (
    proposal_.voters[_account] != VoteOption.None
        && proposal_.parameters.votingMode != VotingMode.VoteReplacement
) {
    return false;
}
```
- **What:** Blocks a second vote from the same account unless the proposal's `votingMode` (frozen at creation,
  `Proposal.sol:L316`) is `VoteReplacement`.
- **Why here:** Last check, after voting power is confirmed positive, so a zero-power voter is rejected for
  "no power" rather than "already voted" when both would apply (order affects nothing observable, since both
  return `false`, but it does mean the "already voted" branch is only reached when the account currently has
  power).
- **Assumes:** `proposal_.voters[_account]` reflects the account's prior recorded vote and is only ever written
  by `_vote` (L58, `proposal_.voters[_voter] = _voteOption`). True by inspection — no other write site to the
  `voters` mapping exists in this file or in `Proposal.sol`.
- **Establishes / does not establish (vote-replacement semantics):** This is the entire gate governing
  repeat votes, and it makes **no distinction between resubmitting the same `_voteOption` and switching to a
  different one**. For an account with `proposal_.voters[_account] != VoteOption.None` (i.e. it has voted
  before, in *any* option), the condition depends solely on `proposal_.parameters.votingMode`:
  - `Standard` or `EarlyExecution`: condition is `true` → `_canVote` returns `false` regardless of whether the
    new `_voteOption` equals or differs from the previous one. A second `vote()` call of any kind reverts via
    `VoteCastForbidden` (L19).
  - `VoteReplacement`: condition is `false` → `_canVote` proceeds to `return true` (L125), again regardless of
    whether `_voteOption` equals or differs from the stored `proposal_.voters[_account]`. There is no
    "resubmitting the same option is a no-op/rejected" special case anywhere in `_canVote`; that symmetry is
    the caller's (`_vote`'s) problem, not this function's.
  - Downstream effect of that symmetry (in `_vote`, not this function): when `_voteOption` equals the
    previously stored option, `_vote` (L41-56) subtracts `votingPower` from the bucket matching the old state
    and then immediately adds the freshly-queried `votingPower` back to the same bucket. If the token's second
    `getPastVotes` call (L37) returns the same value as the first (the assumed-but-unenforced property from the
    previous block), this nets to zero change other than gas spent and a new `VoteCast` event (L60). If it
    returns a *smaller* value than what was originally added, the checked subtraction at L42/44/46 (ordinary
    Solidity 0.8 arithmetic, not `unchecked`) reverts rather than corrupting the tally; if it returns a
    *larger* value, the tally would end up inflated by the difference instead of reverting. Either deviation
    depends entirely on the token, not on anything `_canVote` checks.
- **Depended on by:** L125's unconditional `true`, and by `_vote`'s tally-adjustment logic, which trusts that
  every account reaching it via `_canVote == true` under `VoteReplacement` mode is either voting for the first
  time (`state == None`, no subtraction branch taken) or replacing a prior vote (state matches one of the three
  tracked buckets).

```solidity
// L125
return true;
```
- **What:** All four gates passed.
- **Establishes:** the postcondition `vote()` relies on to call `_vote()` unconditionally (L21) — no further
  checks happen between `_canVote` returning `true` and the tally mutation.

**Cross-Function Dependencies:**

- **Callee `_isProposalOpen` (internal, `Proposal.sol:L251-256`):** read in full; single path, no branches
  beyond the boolean expression itself. It reads `proposal_.parameters.startDate`, `.endDate`, and
  `proposal_.executed` — never `snapshotTimepoint`, which is the field `_proposalExists`
  (`Proposal.sol:L378-380`) actually keys off. `_canVote` therefore never directly checks the field that the
  rest of the codebase uses as the existence flag; it relies on the derived fact (argued above) that
  `endDate == 0 ⟺ proposal never created`, given the `minDuration >= 1 hour` floor in `Settings.sol:L132-133`.
  If that floor were ever bypassable, or if some future code path could leave `endDate == 0` on an otherwise
  "created" proposal, `_isProposalOpen` would not reject it here, and `_canVote` would fall through to the
  voting-power check with `proposal_.parameters.votingToken == address(0)` (a scenario this function currently
  never reaches, but only because of that off-site guarantee).
- **Callee `getPastVotes` (external, black-box beyond the one concrete implementation in this repo,
  `GovernanceERC721` via `ERC721VotesUpgradeable`):** `_canVote` sends `(_account, proposal_.parameters.snapshotTimepoint)`
  and trusts a `uint256` back. Declared `view` on `IVotesUpgradeable`, so Solidity emits a `STATICCALL` for it
  — the EVM itself would revert any attempt by the callee to write state or make a further state-changing
  call through this specific call site, which forecloses classic reentrancy *through this call*. What is not
  foreclosed: the callee returning a value that is not time-invariant (different answers for the same
  historical `(account, snapshot)` pair on different calls), which is the assumption flagged above and is
  never cross-checked against the second, independent call `_vote` makes at L37.
- **Callers:**
  - `vote()` (`Votes.sol:L15-22`): calls `_canVote` directly, with no `onlyIfProposalExists` modifier. It
    relies entirely on the implicit gating traced above to reject a non-existent `_proposalId`; there is no
    second, explicit existence check on this path.
  - `canVote()` (`Votes.sol:L78-86`): a `public view` wrapper that adds `onlyIfProposalExists(_proposalId)`
    (`Proposal.sol:L34-39`), which explicitly checks `_proposalExists` (`snapshotTimepoint != 0`,
    `Proposal.sol:L378-380`) and reverts with `NonexistentProposal` before ever calling `_canVote`. So the two
    public-facing paths to `_canVote`'s logic enforce non-existence through **different mechanisms**: one
    explicit modifier keyed on `snapshotTimepoint`, one implicit fallthrough keyed on `endDate`. Both currently
    agree (a proposal is "created" iff both fields are non-zero, set together at L312-315), but nothing ties
    the two fields to each other beyond both being written in the same `createProposal` call.
- **Shared state:** `proposals[_proposalId].voters` is written only by `_vote` (L58) and read here (L119) and
  by `getVoteOption` (L74-76, public getter, no side effects). `proposal_.parameters.*` is written only at
  proposal creation (`Proposal.sol:L312-320`) and never mutated afterward in any file reviewed, so all fields
  `_canVote` reads (`startDate`, `endDate`, `votingToken`, `snapshotTimepoint`, `votingMode`) are effectively
  immutable per-proposal for the lifetime of the check.
- **Invariant coupling:** `_canVote`'s "already voted" gate (L118-123) and `_vote`'s subtract-then-add tally
  logic (L41-56) jointly assume the tally's implicit invariant
  `tally.yes + tally.no + tally.abstain == Σ getPastVotes(v, snapshot)` over all `v` with `voters[v] != None`.
  That invariant's maintenance depends on the token-determinism assumption above; `_canVote` supplies the
  authorization gate but does no bookkeeping itself, so it cannot detect or prevent drift in that invariant —
  only `_vote`'s arithmetic (checked, so at least fails closed via revert on a downward deviation) touches it.

**Open Questions:**
- unclear; need to inspect whether any upgrade/migration path could ever construct a `Proposal` with
  `endDate == 0` while `snapshotTimepoint != 0` (or vice versa) — the two existence proxies (`Proposal.sol:L379`
  vs. `Proposal.sol:L254`) are written together at creation (L312-315) but nothing enforces they stay coupled
  if a future code path writes one without the other.
- unclear; need to inspect all deployable/whitelisted `votingToken` implementations (beyond the in-repo
  `GovernanceERC721`) to confirm `getPastVotes` is guaranteed immutable-per-snapshot for every token this
  plugin can be configured with, since `_canVote` (L113) and `_vote` (L37) each independently trust that
  without cross-checking the two results against each other.
- unclear; need to inspect whether `votingToken` can be changed after proposals exist (a `VotingTokenUpdated`
  event is declared in `INFTVoting.sol:L143` but no setter appears in the three files reviewed here) — if it
  can, `proposal_.parameters.votingToken` being snapshotted per-proposal (L315) would still isolate `_canVote`
  from that change, but this was not confirmed by reading the setter itself.
