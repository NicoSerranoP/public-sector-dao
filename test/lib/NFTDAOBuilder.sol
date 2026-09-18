// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {TestBase} from "../lib/TestBase.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {NFTVoting} from "../../src/NFTVoting.sol";
import {GovernanceERC721} from "../../src/erc721/GovernanceERC721.sol";
import {INFTVoting} from "../../src/base/INFTVoting.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

contract NFTDAOBuilder is TestBase {
    address immutable DAO_BASE = address(new DAO());
    address immutable NFT_VOTING_PLUGIN_BASE = address(new NFTVoting());
    address private constant ANY_ADDR = address(type(uint160).max);

    // Parameters to override
    address daoOwner; // Used for testing purposes only

    INFTVoting.VotingMode votingMode = INFTVoting.VotingMode.Standard;
    uint32 supportThreshold = 500_000; // 50%
    uint32 minParticipation = 100_000; // 10%
    uint64 minDuration = 60 * 60; // 1h
    uint256 minApprovals = 1;
    uint256 minProposerVotingPower;

    IVotesUpgradeable token;
    address[] newTokenReceivers;
    address targetAddress;
    IPlugin.Operation targetOperation;
    bytes pluginMetadata;

    constructor() {
        // Set the caller as the initial daoOwner
        // It can grant and revoke permissions freely for testing purposes
        withDaoOwner(msg.sender);
    }

    // Override methods
    function withDaoOwner(address _newOwner) public returns (NFTDAOBuilder) {
        daoOwner = _newOwner;
        return this;
    }

    function withEarlyExecution() public returns (NFTDAOBuilder) {
        votingMode = INFTVoting.VotingMode.EarlyExecution;
        return this;
    }

    function withVoteReplacement() public returns (NFTDAOBuilder) {
        votingMode = INFTVoting.VotingMode.VoteReplacement;
        return this;
    }

    function withSupportThreshold(uint32 _newThreshold) public returns (NFTDAOBuilder) {
        supportThreshold = _newThreshold;
        return this;
    }

    function withMinParticipation(uint32 _newValue) public returns (NFTDAOBuilder) {
        minParticipation = _newValue;
        return this;
    }

    function withMinDuration(uint64 _newValue) public returns (NFTDAOBuilder) {
        minDuration = _newValue;
        return this;
    }

    function withMinApprovals(uint64 _newValue) public returns (NFTDAOBuilder) {
        minApprovals = _newValue;
        return this;
    }

    function withMinProposerVotingPower(uint256 _newValue) public returns (NFTDAOBuilder) {
        minProposerVotingPower = _newValue;
        return this;
    }

    // Use the given token
    function withToken(IVotesUpgradeable _newToken) public returns (NFTDAOBuilder) {
        token = _newToken;
        return this;
    }

    // Mint one NFT to each given holder
    function withNewToken(address[] memory _holders) public returns (NFTDAOBuilder) {
        for (uint256 i = 0; i < _holders.length; i++) {
            newTokenReceivers.push(_holders[i]);
        }
        return this;
    }

    // Mint `_nftsEach` NFTs to each given holder
    function withNewToken(address[] memory _holders, uint256 _nftsEach) public returns (NFTDAOBuilder) {
        for (uint256 i = 0; i < _holders.length; i++) {
            for (uint256 j = 0; j < _nftsEach; j++) {
                newTokenReceivers.push(_holders[i]);
            }
        }
        return this;
    }

    function withTargetConfig(address _target, IPlugin.Operation _operation) public returns (NFTDAOBuilder) {
        targetAddress = _target;
        targetOperation = _operation;
        return this;
    }

    function withPluginMetadata(bytes memory _newValue) public returns (NFTDAOBuilder) {
        pluginMetadata = _newValue;
        return this;
    }

    /// @dev Creates a DAO with the given orchestration settings.
    function build() public returns (DAO dao, NFTVoting plugin, IVotesUpgradeable token_) {
        // Deploy the DAO with `daoOwner` as ROOT
        dao = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(DAO_BASE), abi.encodeCall(DAO.initialize, ("", daoOwner, address(0x0), ""))
                ))
        );

        // Plugin params
        if (address(token) == address(0)) {
            if (newTokenReceivers.length == 0) {
                // Fallback: Mint a single NFT to `msg.sender`
                newTokenReceivers.push(msg.sender);
            }

            GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
                name: "MyNFT",
                symbol: "SYM",
                baseURI: "https://example.com/",
                receivers: newTokenReceivers
            });

            token_ = new GovernanceERC721(dao, settings);
        } else {
            token_ = token;
        }

        // Target the DAO by default
        if (targetAddress == address(0)) {
            targetAddress = address(dao);
        }
        IPlugin.TargetConfig memory targetConfig = IPlugin.TargetConfig(targetAddress, targetOperation);

        INFTVoting.VotingSettings memory votingSettings = INFTVoting.VotingSettings({
            votingMode: votingMode,
            supportThreshold: supportThreshold,
            minParticipation: minParticipation,
            minDuration: minDuration,
            maxBoundDate: 365 days,
            minProposerVotingPower: minProposerVotingPower,
            minApprovals: minApprovals
        });

        // Deploy the plugin
        plugin = NFTVoting(
            ProxyLib.deployUUPSProxy(
                address(NFT_VOTING_PLUGIN_BASE),
                abi.encodeCall(
                    NFTVoting.initialize, (dao, votingSettings, token_, targetConfig, pluginMetadata)
                )
            )
        );

        vm.startPrank(daoOwner);

        // Allow anyone to create proposals; `NFTVoting.createProposal` gates on voting power itself.
        dao.grant(address(plugin), ANY_ADDR, plugin.CREATE_PROPOSAL_PERMISSION_ID());

        // Allow the plugin to execute on the DAO
        dao.grant(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID());

        // Make the DAO ROOT on itself
        dao.grant(address(dao), address(dao), dao.ROOT_PERMISSION_ID());

        vm.stopPrank();

        // Labels
        vm.label(address(dao), "DAO");
        vm.label(address(plugin), "NFTVoting");
        vm.label(address(token_), "NFT");

        // Moving forward to ensure that snapshots are ready
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }
}
