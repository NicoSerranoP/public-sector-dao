// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBase} from "./lib/TestBase.sol";

import {NFTDAOBuilder} from "./lib/NFTDAOBuilder.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {NFTVoting} from "../src/NFTVoting.sol";
import {GovernanceERC721} from "../src/erc721/GovernanceERC721.sol";
import {MockGovernanceERC721} from "./mocks/MockGovernanceERC721.sol";
import {INFTVoting} from "../src/base/INFTVoting.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

contract ProposalTest is TestBase {
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
    // totalVotingPower / createProposal
    // -----------------------------------------------------------------------

    function test_WhenTheTotalSupplyIsZero_CreateProposalReverts() external {
        _build(new address[](0)); // NFTDAOBuilder falls back to minting 1 NFT to msg.sender

        // Move the single NFT out via burn is not available here; instead build with a token that has supply 0.
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "Empty", symbol: "MT", baseURI: "https://example.com/", receivers: new address[](0)
        });

        MockGovernanceERC721 emptyToken = new MockGovernanceERC721(IDAO(address(0)), settings);
        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(emptyToken))).build();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(INFTVoting.NoVotingPower.selector));
        plugin.createProposal("", _dummyActions(), 0, 0, 0);
    }

    // -----------------------------------------------------------------------
    // execution / voting modes
    // -----------------------------------------------------------------------

    function test_WhenEarlyExecutionIsEnabled_AProposalCanExecuteBeforeTheEndDate() external {
        address[] memory receivers = new address[](3);
        receivers[0] = ALICE;
        receivers[1] = ALICE;
        receivers[2] = BOB;

        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withEarlyExecution().withNewToken(receivers).build();
        nft = GovernanceERC721(address(token_));

        dao.grant(address(plugin), address(this), plugin.EXECUTE_PROPOSAL_PERMISSION_ID());

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        vm.prank(ALICE);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        // 2 of 3 yes already (alice is present twice in receivers) => remaining 1 no cannot defeat 50% threshold.
        assertTrue(plugin.canExecute(proposalId), "early execution possible while still open");
    }

    // -----------------------------------------------------------------------
    // full lifecycle + minApproval
    // -----------------------------------------------------------------------

    function test_WhenAMajorityVotesYes_TheProposalExecutes() external {
        address[] memory receivers = new address[](3);
        receivers[0] = ALICE;
        receivers[1] = BOB;
        receivers[2] = CAROL;

        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withNewToken(receivers).build();
        nft = GovernanceERC721(address(token_));

        dao.grant(address(plugin), address(this), plugin.EXECUTE_PROPOSAL_PERMISSION_ID());

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        vm.prank(ALICE);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);
        vm.prank(BOB);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);
        vm.prank(CAROL);
        plugin.vote(proposalId, INFTVoting.VoteOption.No, false);

        vm.warp(block.timestamp + ONE_HOUR + 1);

        assertTrue(plugin.canExecute(proposalId), "2 yes / 1 no passes a 50% threshold");
        plugin.execute(proposalId);

        (, bool executed,,,,,) = plugin.getProposal(proposalId);
        assertTrue(executed);
    }

    function test_WhenMinApprovalIsNotMet_TheProposalDoesNotSucceed() external {
        address[] memory receivers = new address[](4);
        receivers[0] = ALICE;
        receivers[1] = BOB;
        receivers[2] = CAROL;
        receivers[3] = DAVID;

        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withMinApprovals(uint64(RATIO_BASE)).withNewToken(receivers).build(); // 100% approval
        nft = GovernanceERC721(address(token_));

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);
        vm.prank(BOB);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        vm.warp(block.timestamp + ONE_HOUR + 1);

        // 1 of 4 yes < 100% minApproval
        assertFalse(plugin.canExecute(proposalId), "min approval not reached");
    }

    // -----------------------------------------------------------------------
    // proposal creation gating
    // -----------------------------------------------------------------------

    function test_WhenMinProposerVotingPowerIsSet_ProposalCreationIsGatedByVotingPower() external {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withMinProposerVotingPower(1).withNewToken(_one(ALICE)).build();
        nft = GovernanceERC721(address(token_));

        // bob has no NFT => cannot create
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(INFTVoting.ProposalCreationForbidden.selector, BOB));
        plugin.createProposal("", _dummyActions(), 0, 0, 0);

        // alice holds an NFT => can create
        vm.prank(ALICE);
        plugin.createProposal("", _dummyActions(), 0, 0, 0);
    }

    function test_CanCreateProposal_ReturnsTrueForEveryoneWhenThresholdIsZero() external {
        _build(_one(ALICE));

        assertTrue(plugin.canCreateProposal(ALICE), "NFT holder can propose");
        assertTrue(plugin.canCreateProposal(BOB), "non-holder can also propose when threshold is 0");
    }

    function test_CanCreateProposal_ReturnsExpectedValuesWhenThresholdIsSet() external {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withMinProposerVotingPower(1).withNewToken(_one(ALICE)).build();
        nft = GovernanceERC721(address(token_));

        assertTrue(plugin.canCreateProposal(ALICE), "NFT holder meets the threshold");
        assertFalse(plugin.canCreateProposal(BOB), "non-holder does not meet the threshold");
    }
}
