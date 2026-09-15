// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBase} from "./lib/TestBase.sol";

import {NFTDAOBuilder} from "./lib/NFTDAOBuilder.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {NFTVoting} from "../src/NFTVoting.sol";
import {GovernanceERC721} from "../src/erc721/GovernanceERC721.sol";
import {MockGovernanceERC721} from "./mocks/MockGovernanceERC721.sol";
import {MockPlainERC721} from "./mocks/MockPlainERC721.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {INFTVoting} from "../src/base/INFTVoting.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {IProposal} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/IProposal.sol";
import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {RatioOutOfBounds} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";

contract NFTVotingTest is TestBase {
    uint64 constant ONE_HOUR = 3600;
    uint32 constant RATIO_BASE = 1_000_000;

    DAO dao;
    NFTVoting plugin;
    GovernanceERC721 nft;

    /// @dev Builds a DAO + NFTVoting where each entry in `_receivers` gets one NFT.
    function _build(address[] memory _receivers) internal {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withNewToken(_receivers).build();
        nft = GovernanceERC721(address(token_));
    }

    function _one(address _a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = _a;
    }

    function _dummyActions() internal pure returns (Action[] memory actions) {
        actions = new Action[](0);
    }

    // -----------------------------------------------------------------------
    // initialize
    // -----------------------------------------------------------------------

    function test_WhenCallingInitializeOnAnAlreadyInitializedPlugin() external {
        _build(_one(alice));

        vm.expectRevert("Initializable: contract is already initialized");
        plugin.initialize(
            dao,
            INFTVoting.VotingSettings({
                votingMode: INFTVoting.VotingMode.Standard,
                supportThreshold: 500_000,
                minParticipation: 100_000,
                minDuration: ONE_HOUR,
                minProposerVotingPower: 0,
                minApprovals: 1
            }),
            IVotesUpgradeable(address(nft)),
            IPlugin.TargetConfig(address(dao), IPlugin.Operation.Call),
            ""
        );
    }

    function test_WhenTheTokenIsNotAnERC721_InitializeReverts() external {
        NFTDAOBuilder builder = new NFTDAOBuilder();
        // A plain DAO implements ERC-165 but not the ERC-721 interface.
        builder.withToken(IVotesUpgradeable(address(new DAO())));

        vm.expectRevert("token is not a ERC721");
        builder.build();
    }

    function test_WhenInitialized_ItAnnouncesTheMembershipContractAndUsesBlockNumberClock() external {
        _build(_one(alice));

        assertEq(address(plugin.getVotingToken()), address(nft));
        assertFalse(plugin.tokenIndexedByTimestamp(), "ERC721Votes default clock is block number");
    }

    // -----------------------------------------------------------------------
    // ERC-165
    // -----------------------------------------------------------------------

    function test_WhenQueryingSupportsInterface() external {
        _build(_one(alice));

        assertTrue(plugin.supportsInterface(type(IERC165Upgradeable).interfaceId));
        assertTrue(plugin.supportsInterface(type(IMembership).interfaceId));
        assertTrue(plugin.supportsInterface(type(INFTVoting).interfaceId));
        assertFalse(plugin.supportsInterface(0xffffffff));
    }

    // -----------------------------------------------------------------------
    // isMember / delegation
    // -----------------------------------------------------------------------

    function test_WhenAnAccountHoldsAnNFT_ItIsAMember() external {
        _build(_one(alice));

        assertTrue(plugin.isMember(alice), "holder is a member");
        assertFalse(plugin.isMember(bob), "non-holder is not a member");
    }

    function test_WhenAnAccountHasVotesDelegatedToIt_ItIsAMember() external {
        _build(_one(alice));

        vm.prank(alice);
        nft.delegate(carol);

        assertTrue(plugin.isMember(alice), "alice still owns the NFT");
        assertTrue(plugin.isMember(carol), "carol has delegated votes");
    }

    function test_WhenDelegatingToAThirdParty_OnlyTheDelegateCanVote() external {
        _build(_one(alice));

        vm.prank(alice);
        nft.delegate(carol);

        // Move forward so the delegation is checkpointed before the snapshot.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);

        assertFalse(plugin.canVote(proposalId, alice, INFTVoting.VoteOption.Yes), "alice delegated away her power");
        assertTrue(plugin.canVote(proposalId, carol, INFTVoting.VoteOption.Yes), "carol holds the voting power");

        vm.prank(carol);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 1, "carol cast one vote");
    }

    // -----------------------------------------------------------------------
    // totalVotingPower / one NFT = one vote
    // -----------------------------------------------------------------------

    function test_WhenTallying_EachNFTCountsAsOneVote() external {
        address[] memory receivers = new address[](3);
        receivers[0] = alice;
        receivers[1] = alice;
        receivers[2] = bob;
        _build(receivers);

        vm.prank(alice);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);

        assertEq(plugin.totalVotingPower(block.number - 1), 3, "3 delegated NFTs");

        vm.prank(alice);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);
        vm.prank(bob);
        plugin.vote(proposalId, INFTVoting.VoteOption.No, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 2, "alice holds 2 NFTs");
        assertEq(tally.no, 1, "bob holds 1 NFT");
    }

    function test_WhenTheTotalSupplyIsZero_CreateProposalReverts() external {
        _build(new address[](0)); // NFTDAOBuilder falls back to minting 1 NFT to msg.sender

        // Move the single NFT out via burn is not available here; instead build with a token that has supply 0.
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "Empty",
            symbol: "MT",
            baseURI: "https://example.com/",
            receivers: new address[](0)
        });

        MockGovernanceERC721 emptyToken = new MockGovernanceERC721(IDAO(address(0)), settings);
        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(emptyToken))).build();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(INFTVoting.NoVotingPower.selector));
        plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);
    }

    // -----------------------------------------------------------------------
    // transfers
    // -----------------------------------------------------------------------

    function test_WhenTheHolderTransfersTheNFT_VotingPowerMovesAtTheNextSnapshot() external {
        _build(_one(alice));

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        // Checkpoint the transfer before creating a proposal.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.prank(bob);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);

        assertFalse(plugin.canVote(proposalId, alice, INFTVoting.VoteOption.Yes), "alice no longer holds the NFT");
        assertTrue(plugin.canVote(proposalId, bob, INFTVoting.VoteOption.Yes), "bob received the NFT");
    }

    function test_WhenTheAdminForceTransfersTheNFT_ItMovesWithoutHolderApproval() external {
        _build(_one(alice));

        // Grant the test contract the force-transfer permission: dao.grant(where, who, permission)
        dao.grant(address(nft), address(this), nft.TRANSFER_PERMISSION_ID());

        vm.expectEmit(true, true, true, true, address(nft));
        emit GovernanceERC721.AdminTransfer(alice, bob, 1);
        nft.adminTransfer(alice, bob, 1);

        assertEq(nft.ownerOf(1), bob, "NFT force-transferred to bob");
        assertEq(nft.balanceOf(alice), 0);
    }

    function test_WhenAForceTransferCallerLacksThePermission_ItReverts() external {
        _build(_one(alice));

        bytes memory expectedErr = abi.encodeWithSelector(
            DaoUnauthorized.selector, address(dao), address(nft), bob, nft.TRANSFER_PERMISSION_ID()
        );

        vm.prank(bob);
        vm.expectRevert(expectedErr);
        nft.adminTransfer(alice, bob, 1);
    }

    // -----------------------------------------------------------------------
    // burn
    // -----------------------------------------------------------------------

    function test_WhenAnNFTIsBurned_ItsVotingPowerIsRemoved() external {
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "Test NFT",
            symbol: "TNFT",
            baseURI: "https://example.com/",
            receivers: new address[](0)
        });

        MockGovernanceERC721 token_ = new MockGovernanceERC721(IDAO(address(0)), settings);

        token_.mintTo(alice);
        token_.mintTo(bob);

        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(token_))).build();

        assertEq(plugin.totalVotingPower(block.number - 1), 2, "two NFTs delegated");

        token_.burnToken(2); // burn bob's NFT

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(plugin.totalVotingPower(block.number - 1), 1, "burning removed one unit of voting power");
    }

    function test_WhenABurnCallerLacksThePermission_ItReverts() external {
        _build(_one(alice));

        bytes memory expectedErr =
            abi.encodeWithSelector(DaoUnauthorized.selector, address(dao), address(nft), bob, nft.BURN_PERMISSION_ID());

        vm.prank(bob);
        vm.expectRevert(expectedErr);
        nft.burn(1);
    }

    // -----------------------------------------------------------------------
    // update base URI
    // -----------------------------------------------------------------------
    function test_WhenTheAdminUpdatesTheBaseURI_ItSucceeds() external {
        _build(_one(alice));

        // Grant the test contract the update base URI permission: dao.grant(where, who, permission)
        dao.grant(address(nft), address(this), nft.UPDATE_BASE_URI_ID());

        string memory newBaseURI = "https://new-base-uri.com/";
        nft.setBaseURI(newBaseURI);

        assertEq(nft.baseURI(), newBaseURI);
    }

    function test_WhenANonAdminUpdatesTheBaseURI_ItReverts() external {
        _build(_one(alice));

        bytes memory expectedErr =
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(dao), address(nft), bob, nft.UPDATE_BASE_URI_ID()
        );

        vm.prank(bob);
        vm.expectRevert(expectedErr);
        nft.setBaseURI("https://new-base-uri.com/");
    }

    // -----------------------------------------------------------------------
    // voting modes
    // -----------------------------------------------------------------------

    function test_WhenEarlyExecutionIsEnabled_AProposalCanExecuteBeforeTheEndDate() external {
        address[] memory receivers = new address[](3);
        receivers[0] = alice;
        receivers[1] = alice;
        receivers[2] = bob;

        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withEarlyExecution().withNewToken(receivers).build();
        nft = GovernanceERC721(address(token_));

        dao.grant(address(plugin), address(this), plugin.EXECUTE_PROPOSAL_PERMISSION_ID());

        vm.prank(alice);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.Yes, false);

        // 2 of 3 yes already => remaining 1 no cannot defeat 50% threshold.
        assertTrue(plugin.canExecute(proposalId), "early execution possible while still open");
    }

    function test_WhenVoteReplacementIsEnabled_AVoterCanChangeTheirVote() external {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withVoteReplacement().withNewToken(_one(alice)).build();
        nft = GovernanceERC721(address(token_));

        vm.prank(alice);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.Yes, false);

        vm.prank(alice);
        plugin.vote(proposalId, INFTVoting.VoteOption.No, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 0, "yes cleared");
        assertEq(tally.no, 1, "vote replaced with no");
    }

    // -----------------------------------------------------------------------
    // full lifecycle + minApproval
    // -----------------------------------------------------------------------

    function test_WhenAMajorityVotesYes_TheProposalExecutes() external {
        address[] memory receivers = new address[](3);
        receivers[0] = alice;
        receivers[1] = bob;
        receivers[2] = carol;

        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withNewToken(receivers).build();
        nft = GovernanceERC721(address(token_));

        dao.grant(address(plugin), address(this), plugin.EXECUTE_PROPOSAL_PERMISSION_ID());

        vm.prank(alice);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.Yes, false);
        vm.prank(bob);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);
        vm.prank(carol);
        plugin.vote(proposalId, INFTVoting.VoteOption.No, false);

        vm.warp(block.timestamp + ONE_HOUR + 1);

        assertTrue(plugin.canExecute(proposalId), "2 yes / 1 no passes a 50% threshold");
        plugin.execute(proposalId);

        (, bool executed,,,,,) = plugin.getProposal(proposalId);
        assertTrue(executed);
    }

    function test_WhenMinApprovalIsNotMet_TheProposalDoesNotSucceed() external {
        address[] memory receivers = new address[](4);
        receivers[0] = alice;
        receivers[1] = bob;
        receivers[2] = carol;
        receivers[3] = david;

        IVotesUpgradeable token_;
        (dao, plugin, token_) =
            new NFTDAOBuilder().withMinApprovals(uint64(RATIO_BASE)).withNewToken(receivers).build(); // 100% approval
        nft = GovernanceERC721(address(token_));

        vm.prank(alice);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.Yes, false);
        vm.prank(bob);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        vm.warp(block.timestamp + ONE_HOUR + 1);

        // 2 of 4 yes < 100% minApproval
        assertFalse(plugin.canExecute(proposalId), "min approval not reached");
    }

    // -----------------------------------------------------------------------
    // settings
    // -----------------------------------------------------------------------

    function test_WhenAnUnauthorizedAccountUpdatesSettings_ItReverts() external {
        _build(_one(alice));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        bytes memory expectedErr = abi.encodeWithSelector(
            DaoUnauthorized.selector, address(dao), address(plugin), bob, plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        );

        vm.prank(bob);
        vm.expectRevert(expectedErr);
        plugin.updateVotingSettings(settings);
    }

    function test_WhenSupportThresholdIsOutOfBounds_ItReverts() external {
        _build(_one(alice));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: RATIO_BASE, // must be < RATIO_BASE
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, RATIO_BASE - 1, RATIO_BASE));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenSupportThresholdIsZero_ItReverts() external {
        _build(_one(alice));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 0,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, RATIO_BASE - 1, 0));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinParticipationIsZero_ItReverts() external {
        _build(_one(alice));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 0,
            minDuration: ONE_HOUR,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, RATIO_BASE, 0));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinApprovalIsZero_ItReverts() external {
        _build(_one(alice));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            minProposerVotingPower: 0,
            minApprovals: 0
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, RATIO_BASE, 0));
        plugin.updateVotingSettings(settings);
    }

    // -----------------------------------------------------------------------
    // voting token
    // -----------------------------------------------------------------------

    function test_WhenAnUnauthorizedAccountUpdatesTheVotingToken_ItReverts() external {
        _build(_one(alice));

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "New NFT",
            symbol: "NEW",
            baseURI: "https://example.com/",
            receivers: _one(alice)
        });
        GovernanceERC721 newToken = new GovernanceERC721(IDAO(address(dao)), settings);

        bytes memory expectedErr = abi.encodeWithSelector(
            DaoUnauthorized.selector, address(dao), address(plugin), bob, plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        );

        vm.prank(bob);
        vm.expectRevert(expectedErr);
        plugin.updateVotingToken(IVotesUpgradeable(address(newToken)));
    }

    function test_WhenTheNewVotingTokenIsNotAnERC721_ItReverts() external {
        _build(_one(alice));

        // A plain DAO implements ERC-165 but not the ERC-721 interface.
        IVotesUpgradeable notAnNft = IVotesUpgradeable(address(new DAO()));

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());

        vm.expectRevert("token is not a ERC721");
        plugin.updateVotingToken(notAnNft);
    }

    function test_WhenTheNewVotingTokenIsNotVotesUpgradeable_ItReverts() external {
        _build(_one(alice));

        // An ERC-721 without the Votes-Upgradeable interface.
        IVotesUpgradeable notVotesUpgradeable = IVotesUpgradeable(address(new MockPlainERC721()));

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());

        vm.expectRevert("token is not a Votes Upgradeable (required getVotes and getPastTotalSupply)");
        plugin.updateVotingToken(notVotesUpgradeable);
    }

    function test_WhenAnAuthorizedAccountUpdatesTheVotingToken_ItReplacesTheInitializedToken() external {
        _build(_one(alice));

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "New NFT",
            symbol: "NEW",
            baseURI: "https://example.com/",
            receivers: _one(bob)
        });
        GovernanceERC721 newToken = new GovernanceERC721(IDAO(address(dao)), settings);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());

        vm.expectEmit(true, true, true, true, address(plugin));
        emit INFTVoting.VotingTokenUpdated(address(newToken));
        plugin.updateVotingToken(IVotesUpgradeable(address(newToken)));

        assertEq(address(plugin.getVotingToken()), address(newToken), "voting token should be replaced");

        // The old token's voting power should no longer count.
        assertEq(plugin.totalVotingPower(block.number - 1), 1, "only the new token's supply should count");

        // A holder of the new (but not the old) token can now vote.
        vm.prank(bob);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);

        assertFalse(plugin.canVote(proposalId, alice, INFTVoting.VoteOption.Yes), "alice held only the old token");
        assertTrue(plugin.canVote(proposalId, bob, INFTVoting.VoteOption.Yes), "bob holds the new token");
    }

    function test_WhenMinProposerVotingPowerIsSet_ProposalCreationIsGatedByVotingPower() external {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withMinProposerVotingPower(1).withNewToken(_one(alice)).build();
        nft = GovernanceERC721(address(token_));

        // bob has no NFT => cannot create
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(INFTVoting.ProposalCreationForbidden.selector, bob));
        plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);

        // alice holds an NFT => can create
        vm.prank(alice);
        plugin.createProposal("", _dummyActions(), 0, 0, 0, INFTVoting.VoteOption.None, false);
    }

    function test_CanCreateProposal_ReturnsTrueForEveryoneWhenThresholdIsZero() external {
        _build(_one(alice));

        assertTrue(plugin.canCreateProposal(alice), "NFT holder can propose");
        assertTrue(plugin.canCreateProposal(bob), "non-holder can also propose when threshold is 0");
    }

    function test_CanCreateProposal_ReturnsExpectedValuesWhenThresholdIsSet() external {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withMinProposerVotingPower(1).withNewToken(_one(alice)).build();
        nft = GovernanceERC721(address(token_));

        assertTrue(plugin.canCreateProposal(alice), "NFT holder meets the threshold");
        assertFalse(plugin.canCreateProposal(bob), "non-holder does not meet the threshold");
    }
}
