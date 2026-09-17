// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBase} from "./lib/TestBase.sol";

import {NFTDAOBuilder} from "./lib/NFTDAOBuilder.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {NFTVoting} from "../src/NFTVoting.sol";
import {GovernanceERC721} from "../src/erc721/GovernanceERC721.sol";
import {INFTVoting} from "../src/base/INFTVoting.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

contract VotesTest is TestBase {
    DAO dao;
    NFTVoting plugin;
    GovernanceERC721 nft;

    /// @dev Builds a DAO + NFTVoting where each entry in `_receivers` gets one NFT.
    function _build(address[] memory _receivers) internal {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withNewToken(_receivers).build();
        nft = GovernanceERC721(address(token_));
    }

    // -----------------------------------------------------------------------
    // isMember
    // -----------------------------------------------------------------------

    function test_WhenAnAccountHoldsAnNFT_ItIsAMember() external {
        _build(_one(ALICE));

        assertTrue(plugin.isMember(ALICE), "holder is a member");
        assertFalse(plugin.isMember(BOB), "non-holder is not a member");
    }

    function test_WhenAnAccountHasVotesDelegatedToIt_ItIsAMember() external {
        _build(_one(ALICE));

        vm.prank(ALICE);
        nft.delegate(CAROL);

        assertTrue(plugin.isMember(ALICE), "alice still owns the NFT");
        assertTrue(plugin.isMember(CAROL), "carol has delegated votes");
    }

    // -----------------------------------------------------------------------
    // delegation
    // -----------------------------------------------------------------------

    function test_WhenDelegatingToAThirdParty_OnlyTheDelegateCanVote() external {
        _build(_one(ALICE));

        vm.prank(ALICE);
        nft.delegate(CAROL);

        // Move forward so the delegation is checkpointed before the snapshot.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        assertFalse(plugin.canVote(proposalId, ALICE, INFTVoting.VoteOption.Yes), "alice delegated away her power");
        assertTrue(plugin.canVote(proposalId, CAROL, INFTVoting.VoteOption.Yes), "carol holds the voting power");

        vm.prank(CAROL);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 1, "carol cast one vote");
    }

    // -----------------------------------------------------------------------
    // tallying / one NFT = one vote
    // -----------------------------------------------------------------------

    function test_WhenTallying_EachNFTCountsAsOneVote() external {
        address[] memory receivers = new address[](3);
        receivers[0] = ALICE;
        receivers[1] = ALICE;
        receivers[2] = BOB;
        _build(receivers);

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        assertEq(plugin.totalVotingPower(block.number - 1), 3, "3 delegated NFTs");

        vm.prank(ALICE);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);
        vm.prank(BOB);
        plugin.vote(proposalId, INFTVoting.VoteOption.No, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 2, "alice holds 2 NFTs");
        assertEq(tally.no, 1, "bob holds 1 NFT");
    }

    // -----------------------------------------------------------------------
    // voting power in transfers
    // -----------------------------------------------------------------------

    function test_WhenTheHolderTransfersTheNFT_VotingPowerMovesAtTheNextSnapshot() external {
        _build(_one(ALICE));

        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 1);

        // Checkpoint the transfer before creating a proposal.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.prank(BOB);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        assertFalse(plugin.canVote(proposalId, ALICE, INFTVoting.VoteOption.Yes), "alice no longer holds the NFT");
        assertTrue(plugin.canVote(proposalId, BOB, INFTVoting.VoteOption.Yes), "bob received the NFT");
    }

    function test_WhenTheHolderTransfersTheNFT_VotingPowerIsNotModifiedInOpenProposal() external {
        _build(_one(ALICE));

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 1);

        // The transfer should not affect the open proposal's voting power.
        assertTrue(
            plugin.canVote(proposalId, ALICE, INFTVoting.VoteOption.Yes),
            "alice should still be able to vote in the open proposal"
        );
        assertFalse(
            plugin.canVote(proposalId, BOB, INFTVoting.VoteOption.Yes),
            "bob should not be able to vote in the open proposal"
        );
    }

    // -----------------------------------------------------------------------
    // voting modes
    // -----------------------------------------------------------------------

    function test_WhenVoteReplacementIsEnabled_AVoterCanChangeTheirVote() external {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withVoteReplacement().withNewToken(_one(ALICE)).build();
        nft = GovernanceERC721(address(token_));

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        vm.prank(ALICE);
        plugin.vote(proposalId, INFTVoting.VoteOption.No, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 0, "yes cleared");
        assertEq(tally.no, 1, "vote replaced with no");
    }
}
