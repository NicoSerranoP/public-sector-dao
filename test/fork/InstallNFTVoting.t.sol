// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DAO, IDAO} from "@aragon/osx/core/dao/DAO.sol";
import {DAOFactory} from "@aragon/osx/framework/dao/DAOFactory.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {ForkTestBase} from "../lib/ForkTestBase.sol";

import {InstallNFTVotingScript, InstallParams} from "../../script/InstallNFTVoting.s.sol";
import {NFTVoting} from "../../src/NFTVoting.sol";
import {INFTVoting} from "../../src/base/INFTVoting.sol";
import {GovernanceERC721} from "../../src/erc721/GovernanceERC721.sol";

/// @dev Exercises InstallNFTVotingScript against a real OSx deployment (DAOFactory) on a fork,
///     covering both the new-DAO and existing-DAO install paths plus a full proposal lifecycle.
contract InstallNFTVotingTest is ForkTestBase {
    InstallNFTVotingScript internal script;

    function setUp() public {
        script = new InstallNFTVotingScript();
    }

    function test_WhenCreatingANewDaoWithANewToken() external {
        (DAO dao, NFTVoting plugin, IVotesUpgradeable token) =
            script.createDaoAndInstall(DAO_FACTORY, _daoSettings(), _defaultParams());

        assertTrue(
            dao.isGranted(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID(), ""), "Plugin should be installed"
        );
        assertTrue(
            plugin.canCreateProposal(address(0x1234)),
            "Anyone should be able to create proposals (minProposerVotingPower == 0)"
        );
        assertNotEq(address(token), address(0), "A new token should have been minted");
        assertTrue(plugin.isMember(address(this)), "Deployer should hold the newly minted NFT");
        assertFalse(
            dao.isGranted(address(dao), address(script), dao.EXECUTE_PERMISSION_ID(), ""),
            "Installer should not retain EXECUTE permission"
        );

        // The DAO should be able to mint, burn and force-transfer vote NFTs.
        GovernanceERC721 nft = GovernanceERC721(address(token));
        assertTrue(dao.isGranted(address(nft), address(dao), nft.MINT_PERMISSION_ID(), ""));
        assertTrue(dao.isGranted(address(nft), address(dao), nft.BURN_PERMISSION_ID(), ""));
        assertTrue(dao.isGranted(address(nft), address(dao), nft.TRANSFER_PERMISSION_ID(), ""));
        assertTrue(dao.isGranted(address(nft), address(dao), nft.UPDATE_BASE_URI_ID(), ""));
    }

    function test_WhenCreatingANewDaoWithAnExistingToken() external {
        address[] memory receivers = new address[](3);
        receivers[0] = ALICE;
        receivers[1] = ALICE;
        receivers[2] = BOB;

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "Existing NFT", symbol: "EXIST", baseURI: "https://example.com/", receivers: receivers
        });

        GovernanceERC721 existingToken = new GovernanceERC721(IDAO(address(0)), settings);

        InstallParams memory params = _defaultParams();
        params.existingToken = address(existingToken);

        (DAO dao, NFTVoting plugin, IVotesUpgradeable token) =
            script.createDaoAndInstall(DAO_FACTORY, _daoSettings(), params);

        assertTrue(
            dao.isGranted(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID(), ""), "Plugin should be installed"
        );
        assertFalse(
            dao.isGranted(address(dao), address(script), dao.EXECUTE_PERMISSION_ID(), ""),
            "Installer should not retain EXECUTE permission"
        );
        assertEq(address(token), address(existingToken), "The plugin should use the provided token");
        assertTrue(plugin.isMember(ALICE), "Alice should be a member");
        assertTrue(plugin.isMember(BOB), "Bob should be a member");
        assertFalse(plugin.isMember(CAROL), "Carol should not be a member");
    }

    function test_WhenInstallingOnAnExistingDao() external {
        DAO dao = build();
        dao.grant(address(dao), address(script), dao.EXECUTE_PERMISSION_ID());

        (NFTVoting plugin, IVotesUpgradeable token) = script.installOnExistingDao(dao, _defaultParams());

        assertTrue(
            dao.isGranted(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID(), ""), "Plugin should be installed"
        );
        assertFalse(
            dao.isGranted(address(dao), address(script), dao.EXECUTE_PERMISSION_ID(), ""),
            "Installer should not retain EXECUTE permission"
        );
        assertNotEq(address(token), address(0));
    }

    /// @dev Full create -> vote -> execute cycle through a freshly installed plugin.
    function test_FullProposalLifecycle() external {
        InstallParams memory params = _defaultParams();
        params.nftCount = 3;

        (DAO dao, NFTVoting plugin,) = script.createDaoAndInstall(DAO_FACTORY, _daoSettings(), params);

        // Move past the mint's checkpoint so the proposal's voting-power snapshot sees it.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertTrue(plugin.isMember(address(this)), "Deployer should hold voting power");
        assertEq(plugin.totalVotingPower(block.number - 1), 3, "Three NFTs should be delegated");

        Action[] memory actions = new Action[](1);
        actions[0] = Action({to: address(dao), value: 0, data: abi.encodeCall(DAO.setMetadata, (bytes("e2e-test")))});

        uint256 proposalId = plugin.createProposal("", actions, 0, 0, 0);
        plugin.vote(proposalId, INFTVoting.VoteOption.Yes, false);

        (bool openBefore, bool executedBefore,,,,,) = plugin.getProposal(proposalId);
        assertTrue(openBefore, "Proposal should be open right after creation");
        assertFalse(executedBefore, "Proposal should not be executed yet");

        vm.warp(block.timestamp + 1 hours + 1);

        assertTrue(plugin.canExecute(proposalId), "Proposal should be executable after reaching quorum and ending");

        vm.prank(address(this));
        plugin.execute(proposalId);

        (, bool executedAfter,,,,,) = plugin.getProposal(proposalId);
        assertTrue(executedAfter, "Proposal should have executed");
    }

    function _daoSettings() internal pure returns (DAOFactory.DAOSettings memory) {
        return
            DAOFactory.DAOSettings({trustedForwarder: address(0), daoURI: "http://host/", subdomain: "", metadata: ""});
    }

    function _defaultParams() internal pure returns (InstallParams memory params) {
        params.votingSettings = INFTVoting.VotingSettings({
            votingMode: INFTVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: 1 hours,
            maxBoundDate: 365 days,
            minProposerVotingPower: 0,
            minApprovals: 1
        });

        params.tokenName = "Test NFT";
        params.tokenSymbol = "TNFT";
        params.nftCount = 1;
        params.targetConfig = IPlugin.TargetConfig({target: address(0), operation: IPlugin.Operation.Call});
    }
}
