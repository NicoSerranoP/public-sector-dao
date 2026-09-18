// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBase} from "../lib/TestBase.sol";
import {NFTDAOBuilder} from "../lib/NFTDAOBuilder.sol";
import {NFTVotingHandler} from "./handlers/NFTVotingHandler.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {NFTVoting} from "../../src/NFTVoting.sol";
import {GovernanceERC721} from "../../src/erc721/GovernanceERC721.sol";
import {INFTVoting} from "../../src/base/INFTVoting.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

/// @notice Step-4 (Trail of Bits secure workflow) property-based test suite: stateful Foundry invariant
///     fuzzing over the create-proposal / vote / execute lifecycle.
/// @dev The properties below come from `audit-context/DOSSIER.md`'s invariants and fragility clusters and
///     `audit-context/FINDINGS.md`'s hunting pass, both built independently from source during this repo's
///     audit-context-building pass. See `test/invariant/handlers/NFTVotingHandler.sol` for what's exercised
///     and what's deliberately out of scope for this suite.
contract NFTVotingInvariantsTest is TestBase {
    uint64 internal constant MAX_BOUND_DATE = 7 days;

    DAO internal dao;
    NFTVoting internal plugin;
    GovernanceERC721 internal nft;
    NFTVotingHandler internal handler;

    // Ghost, kept in the test contract (not the handler) because it must persist and be checked across
    // the whole invariant campaign, not recomputed fresh each call.
    mapping(uint256 => bool) internal seenExecuted;

    function setUp() public {
        address[] memory actors = new address[](5);
        actors[0] = ALICE;
        actors[1] = BOB;
        actors[2] = CAROL;
        actors[3] = DAVID;
        actors[4] = RANDOM_ADDRESS;

        IVotesUpgradeable token;
        (dao, plugin, token) = new NFTDAOBuilder().withNewToken(actors) // one NFT each at genesis
            .withEarlyExecution() // exercises isSupportThresholdReachedEarly, not just the closed-form check
            .withSupportThreshold(500_000) // 50%
            .withMinParticipation(100_000) // 10%
            .withMinApprovals(1) // 0.0001% minimum approval required for a proposal to pass
            .withMinDuration(ONE_HOUR).build();

        nft = GovernanceERC721(address(token));

        (address admin,) = makeWallet("FuzzAdmin");
        // `address(this)` is `daoOwner` (NFTDAOBuilder defaults it to its own deployer). No prank needed for this grant
        dao.grant(address(nft), admin, nft.MINT_PERMISSION_ID());

        handler = new NFTVotingHandler(dao, plugin, nft, admin, actors, MAX_BOUND_DATE);

        targetContract(address(handler));
    }

    /// @notice A proposal's cast-vote tally can never exceed the total supply snapshotted at its own
    ///     creation time — the arithmetic both `isSupportThresholdReached` and, more fragile,
    ///     `isSupportThresholdReachedEarly`'s checked subtraction depend on this holding.
    function invariant_TallyNeverExceedsSnapshotSupply() public view {
        uint256 count = handler.proposalCount();
        for (uint256 i; i < count; i++) {
            uint256 id = handler.proposalIds(i);
            (,, INFTVoting.ProposalParameters memory params, INFTVoting.Tally memory tally,,,) = plugin.getProposal(id);

            uint256 snapshotSupply = nft.getPastTotalSupply(params.snapshotTimepoint);
            assertLe(
                tally.yes + tally.no + tally.abstain,
                snapshotSupply,
                "tally sum exceeds the total supply snapshotted at proposal creation"
            );
        }
    }

    /// @notice Once a proposal is observed executed, it must never be observed un-executed again.
    ///     `_execute` is the sole writer of `proposal_.executed` and only ever sets it to `true`
    ///     (Proposal.sol) — this is the fuzz-level guard for that write-once property.
    function invariant_ExecuteProposalOnlyOnce() public {
        uint256 count = handler.proposalCount();
        for (uint256 i; i < count; i++) {
            uint256 id = handler.proposalIds(i);
            (, bool executed,,,,,) = plugin.getProposal(id);

            if (seenExecuted[id]) {
                assertTrue(executed, "a previously-executed proposal is no longer marked executed");
            }
            if (executed) {
                seenExecuted[id] = true;
            }
        }
    }

    /// @notice An executed proposal must still report `hasSucceeded() == true` afterward. Voting is
    ///     blocked once `executed == true` (`_isProposalOpen` requires `!executed`), so the tally is
    ///     frozen at execution time and the success predicate should remain stable.
    function invariant_ExecutedImpliesSucceeded() public view {
        uint256 count = handler.proposalCount();
        for (uint256 i; i < count; i++) {
            uint256 id = handler.proposalIds(i);
            (, bool executed,,,,,) = plugin.getProposal(id);

            if (executed) {
                assertTrue(plugin.hasSucceeded(id), "an executed proposal no longer reports hasSucceeded()");
            }
        }
    }

    /// @notice `isSupportThresholdReachedEarly`'s worst-case-no-votes subtraction
    ///     (`getPastTotalSupply(snapshot) - tally.yes - tally.abstain`) must never underflow-revert for a
    ///     real, existing proposal — this is the regression guard for the fragility the dossier flagged
    ///     around trusting the voting token's checkpoint accounting.
    function invariant_IsSupportThresholdReachedEarlyNeverReverts() public view {
        uint256 count = handler.proposalCount();
        for (uint256 i; i < count; i++) {
            uint256 id = handler.proposalIds(i);
            try plugin.isSupportThresholdReachedEarly(id) returns (bool) {}
            catch {
                // isSupportThresholdReachedEarly() reverted and was catched here. It cannot revert for an existing proposal
                assertTrue(false, "isSupportThresholdReachedEarly reverted for an existing, in-scope proposal");
            }
        }
    }
}
