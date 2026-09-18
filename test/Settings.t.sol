// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestBase} from "./lib/TestBase.sol";

import {NFTDAOBuilder} from "./lib/NFTDAOBuilder.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {NFTVoting} from "../src/NFTVoting.sol";
import {GovernanceERC721} from "../src/erc721/GovernanceERC721.sol";
import {MockPlainERC721} from "./mocks/MockPlainERC721.sol";
import {MockTimestampClockToken} from "./mocks/MockTimestampClockToken.sol";
import {MockBlockNumberClockToken} from "./mocks/MockBlockNumberClockToken.sol";
import {INFTVoting} from "../src/base/INFTVoting.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {RatioOutOfBounds} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";

contract SettingsTest is TestBase {
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
    // initialize
    // -----------------------------------------------------------------------

    function test_WhenCallingInitializeOnAnAlreadyInitializedPlugin() external {
        _build(_one(ALICE));

        vm.expectRevert("Initializable: contract is already initialized");
        plugin.initialize(
            dao,
            INFTVoting.VotingSettings({
                votingMode: INFTVoting.VotingMode.Standard,
                supportThreshold: 500_000,
                minParticipation: 100_000,
                minDuration: ONE_HOUR,
                maxBoundDate: 365 days,
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
        _build(_one(ALICE));

        assertEq(address(plugin.getVotingToken()), address(nft));
        assertFalse(plugin.tokenIndexedByTimestamp(), "ERC721Votes default clock is block number");
    }

    function test_WhenMinProposerVotingPowerExceedsTotalSupplyAtGenesis_InitializeReverts() external {
        // Only 1 NFT is minted, so requesting 2 as the proposer threshold must be rejected
        NFTDAOBuilder builder = new NFTDAOBuilder();
        builder.withNewToken(_one(ALICE)).withMinProposerVotingPower(2);

        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, 1, 2));
        builder.build();
    }

    function test_WhenMinProposerVotingPowerIsLessThanTotalSupplyAtGenesis_InitializeSucceeds() external {
        // Only 1 NFT is minted, so requesting 0 as the proposer threshold must be accepted
        NFTDAOBuilder builder = new NFTDAOBuilder();
        builder.withNewToken(_one(ALICE)).withMinProposerVotingPower(0);

        (dao, plugin,) = builder.build();

        assertEq(plugin.minProposerVotingPower(), 0);
    }

    function test_WhenMinProposerVotingPowerEqualsTotalSupplyAtGenesis_InitializeSucceeds() external {
        NFTDAOBuilder builder = new NFTDAOBuilder();
        builder.withNewToken(_one(ALICE)).withMinProposerVotingPower(1);

        (dao, plugin,) = builder.build();

        assertEq(plugin.minProposerVotingPower(), 1);
    }

    // -----------------------------------------------------------------------
    // ERC-165
    // -----------------------------------------------------------------------

    function test_WhenQueryingSupportsInterface() external {
        _build(_one(ALICE));

        assertTrue(plugin.supportsInterface(type(IERC165Upgradeable).interfaceId));
        assertTrue(plugin.supportsInterface(type(IMembership).interfaceId));
        assertTrue(plugin.supportsInterface(type(INFTVoting).interfaceId));
        assertFalse(plugin.supportsInterface(0xffffffff));
    }

    // -----------------------------------------------------------------------
    // voting settings
    // -----------------------------------------------------------------------

    function test_WhenAnUnauthorizedAccountUpdatesSettings_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        bytes memory expectedErr = abi.encodeWithSelector(
            DaoUnauthorized.selector, address(dao), address(plugin), BOB, plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        );

        vm.prank(BOB);
        vm.expectRevert(expectedErr);
        plugin.updateVotingSettings(settings);
    }

    function test_WhenSupportThresholdIsOutOfBounds_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: RATIO_BASE, // must be < RATIO_BASE
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, RATIO_BASE - 1, RATIO_BASE));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenSupportThresholdIsZero_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 0,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, RATIO_BASE - 1, 0));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinParticipationIsZero_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 0,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, 900_000, 0));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinParticipationIsAboveSafeBound_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 900_001,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, 900_000, 900_001));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinApprovalIsZero_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 0
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, 900_000, 0));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinApprovalIsAboveSafeBound_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 900_001
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, 900_000, 900_001));
        plugin.updateVotingSettings(settings);
    }

    function test_WhenMinProposerVotingPowerExceedsCurrentSupply_ItReverts() external {
        _build(_one(ALICE));

        INFTVoting.VotingSettings memory settings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: ONE_HOUR,
            maxBoundDate: 365 days,
            minProposerVotingPower: 2,
            minApprovals: 1
        });

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        vm.expectRevert(abi.encodeWithSelector(RatioOutOfBounds.selector, 1, 2));
        plugin.updateVotingSettings(settings);
    }

    // -----------------------------------------------------------------------
    // voting token updates
    // -----------------------------------------------------------------------

    function test_WhenAnUnauthorizedAccountUpdatesTheVotingToken_ItReverts() external {
        _build(_one(ALICE));

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "New NFT", symbol: "NEW", baseURI: "https://example.com/", receivers: _one(ALICE)
        });
        GovernanceERC721 newToken = new GovernanceERC721(IDAO(address(dao)), settings);

        bytes memory expectedErr = abi.encodeWithSelector(
            DaoUnauthorized.selector, address(dao), address(plugin), BOB, plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        );

        vm.prank(BOB);
        vm.expectRevert(expectedErr);
        plugin.updateVotingToken(IVotesUpgradeable(address(newToken)));
    }

    function test_WhenTheNewVotingTokenIsNotAnERC721_ItReverts() external {
        _build(_one(ALICE));

        // A plain DAO implements ERC-165 but not the ERC-721 interface.
        IVotesUpgradeable notAnNft = IVotesUpgradeable(address(new DAO()));

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());

        vm.expectRevert("token is not a ERC721");
        plugin.updateVotingToken(notAnNft);
    }

    function test_WhenTheNewVotingTokenIsNotVotesUpgradeable_ItReverts() external {
        _build(_one(ALICE));

        // An ERC-721 without the Votes-Upgradeable interface.
        IVotesUpgradeable notVotesUpgradeable = IVotesUpgradeable(address(new MockPlainERC721()));

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());

        vm.expectRevert("token is not a Votes Upgradeable (required getVotes and getPastTotalSupply)");
        plugin.updateVotingToken(notVotesUpgradeable);
    }

    function test_WhenAnAuthorizedAccountUpdatesTheVotingToken_ItReplacesTheExistingToken() external {
        _build(_one(ALICE));

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "New NFT", symbol: "NEW", baseURI: "https://example.com/", receivers: _one(BOB)
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
        vm.prank(BOB);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        assertFalse(plugin.canVote(proposalId, ALICE, INFTVoting.VoteOption.Yes), "alice held only the old token");
        assertTrue(plugin.canVote(proposalId, BOB, INFTVoting.VoteOption.Yes), "bob holds the new token");
    }

    function test_WhenTheVotingTokenIsUpdatedWhileAProposalIsOpen_TheProposalKeepsUsingTheOriginalToken() external {
        _build(_one(ALICE));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        (bool open,, INFTVoting.ProposalParameters memory parameters,,,,) = plugin.getProposal(proposalId);
        assertTrue(open, "proposal should be open");
        assertEq(parameters.votingToken, address(nft), "proposal should snapshot the original token");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "New NFT", symbol: "NEW", baseURI: "https://example.com/", receivers: _one(BOB)
        });
        GovernanceERC721 newToken = new GovernanceERC721(IDAO(address(dao)), settings);

        dao.grant(address(plugin), address(this), plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        plugin.updateVotingToken(IVotesUpgradeable(address(newToken)));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(address(plugin.getVotingToken()), address(newToken), "global token should be updated");
        assertTrue(
            plugin.canVote(proposalId, ALICE, INFTVoting.VoteOption.Yes),
            "alice should keep her voting rights in the old proposal"
        );
        assertFalse(
            plugin.canVote(proposalId, BOB, INFTVoting.VoteOption.Yes),
            "bob should not have voting rights in the old proposal"
        );

        vm.prank(ALICE);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        vm.warp(block.timestamp + ONE_HOUR + 1);

        assertTrue(plugin.canExecute(proposalId), "proposal should remain executable after the token update");
        vm.prank(ALICE);
        plugin.execute(proposalId);
    }

    // -----------------------------------------------------------------------
    // clock detection (adversarial)
    // -----------------------------------------------------------------------
    //

    function test_WhenTheTokenHasACanonicalTimestampClock_ItIsDetectedAsTimestampIndexed() external {
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "NFT with CLOCK=blocknumber", symbol: "NEW", baseURI: "https://example.com/", receivers: _one(ALICE)
        });

        MockTimestampClockToken token_ = new MockTimestampClockToken(IDAO(address(0)), settings);

        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(token_))).build();

        assertTrue(plugin.tokenIndexedByTimestamp(), "clock() returns block.timestamp");
    }

    function test_WhenTheTokenHasBlockNumberClock_ItIsDetectedAsBlockNumberIndexed() external {
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "NFT with CLOCK=timestamp", symbol: "NEW", baseURI: "https://example.com/", receivers: _one(ALICE)
        });

        MockBlockNumberClockToken token_ = new MockBlockNumberClockToken(IDAO(address(0)), settings);

        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(token_))).build();

        assertFalse(plugin.tokenIndexedByTimestamp(), "clock() returns block.number");
    }

    /// @dev End-to-end proof that a detected timestamp-indexed token is not just flagged correctly,
    ///     but that snapshots, `createProposal` and `canVote` all behave correctly when driven by
    ///     `vm.warp` instead of `vm.roll`
    function test_WhenTheVotingTokenIsTimestampIndexed_TheFullProposalLifecycleUsesTimestamps() external {
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "NFT with .clock()", symbol: "NEW", baseURI: "https://example.com/", receivers: _one(ALICE)
        });

        MockTimestampClockToken token_ = new MockTimestampClockToken(IDAO(address(0)), settings);

        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(token_))).build();
        assertTrue(plugin.tokenIndexedByTimestamp());

        // Advance only the timestamp (not the block number) to checkpoint the snapshot.
        vm.warp(block.timestamp + 1);

        vm.prank(ALICE);
        uint256 proposalId = plugin.createProposal("", _dummyActions(), 0, 0, 0);

        assertTrue(
            plugin.canVote(proposalId, ALICE, INFTVoting.VoteOption.Yes), "alice's timestamp-indexed vote counts"
        );

        vm.prank(ALICE);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        (,,, INFTVoting.Tally memory tally,,,) = plugin.getProposal(proposalId);
        assertEq(tally.yes, 1, "vote correctly tallied under timestamp indexing");
    }

    function test_WhenTargetConfigUsesDelegateCall_ItReverts() external {
        _build(_one(ALICE));

        dao.grant(address(plugin), address(this), plugin.SET_TARGET_CONFIG_PERMISSION_ID());

        IPlugin.TargetConfig memory targetConfig =
            IPlugin.TargetConfig({target: address(dao), operation: IPlugin.Operation.DelegateCall});

        vm.expectRevert();
        plugin.setTargetConfig(targetConfig);
    }
}
