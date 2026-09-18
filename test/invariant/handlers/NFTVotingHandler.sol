// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {NFTVoting} from "../../../src/NFTVoting.sol";
import {GovernanceERC721} from "../../../src/erc721/GovernanceERC721.sol";
import {INFTVoting} from "../../../src/base/INFTVoting.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

/// @notice Drives NFTVoting + GovernanceERC721 through bounded, randomized call sequences for Foundry
///     invariant fuzzing. Every mutating target function swallows expected reverts (closed proposal,
///     already voted, no voting power, etc.) via try/catch so the fuzzer keeps exploring instead of
///     stalling on the first legitimate rejection.
/// @dev Ghost state here (`proposalIds`, `mintCount`) is read by `NFTVotingInvariants.t.sol`'s
///     `invariant_*` functions. It is test-only bookkeeping, not part of the contracts under test.
///     Scope note: this handler deliberately does not exercise `updateVotingSettings`/`updateVotingToken`/
///     `burn`/`adminTransfer` — the invariants below target the create/vote/execute lifecycle, which is
///     where `audit-context/DOSSIER.md`'s fragility clusters concentrate. Extend with more target
///     functions if broader coverage is wanted later.
contract NFTVotingHandler is Test {
    uint256 internal constant MAX_TRACKED_PROPOSALS = 25;
    uint256 internal constant MAX_MINTS = 30;

    DAO public immutable dao;
    NFTVoting public immutable plugin;
    GovernanceERC721 public immutable nft;
    address public immutable admin;
    uint64 public immutable maxBoundDate;

    address[] internal actors;

    uint256[] public proposalIds;
    uint256 public mintCount;

    constructor(
        DAO _dao,
        NFTVoting _plugin,
        GovernanceERC721 _nft,
        address _admin,
        address[] memory _actors,
        uint64 _maxBoundDate
    ) {
        dao = _dao;
        plugin = _plugin;
        nft = _nft;
        admin = _admin;
        actors = _actors;
        maxBoundDate = _maxBoundDate;
    }

    function proposalCount() external view returns (uint256) {
        return proposalIds.length;
    }

    function _actor(uint256 _seed) internal view returns (address) {
        return actors[_seed % actors.length];
    }

    // --- Target functions that will be run N times in the fuzz lifecycle (need to be external so they appear in the ABI) ---

    function createProposal(uint256 _actorSeed, uint256 _startOffsetSeed, uint256 _durationSeed) external {
        if (proposalIds.length >= MAX_TRACKED_PROPOSALS) return;

        address caller = _actor(_actorSeed);
        if (!plugin.canCreateProposal(caller)) return;

        uint64 minDur = plugin.minDuration();
        uint64 startDate = uint64(block.timestamp) + uint64(bound(_startOffsetSeed, 0, maxBoundDate));
        uint64 endDate = startDate + uint64(bound(_durationSeed, minDur, maxBoundDate));

        vm.prank(caller);
        try plugin.createProposal("", new Action[](0), 0, startDate, endDate) returns (uint256 proposalId) {
            proposalIds.push(proposalId);
        } catch {}
    }

    function vote(uint256 _actorSeed, uint256 _proposalSeed, uint256 _optionSeed, bool _tryEarlyExecution) external {
        if (proposalIds.length == 0) return;

        address caller = _actor(_actorSeed);
        uint256 proposalId = proposalIds[_proposalSeed % proposalIds.length];
        // VoteOption: None=0, Abstain=1, Yes=2, No=3 — restrict to the three meaningful options.
        INFTVoting.VoteOption option = INFTVoting.VoteOption(uint8(bound(_optionSeed, 1, 3)));

        vm.prank(caller);
        try plugin.vote(proposalId, option, _tryEarlyExecution) {} catch {}
    }

    function execute(uint256 _actorSeed, uint256 _proposalSeed) external {
        if (proposalIds.length == 0) return;

        address caller = _actor(_actorSeed);
        uint256 proposalId = proposalIds[_proposalSeed % proposalIds.length];

        vm.prank(caller);
        try plugin.execute(proposalId) {} catch {}
    }

    function mint(uint256 _actorSeed) external {
        if (mintCount >= MAX_MINTS) return;

        address to = _actor(_actorSeed);
        vm.prank(admin);
        try nft.mint(to) {
            mintCount++;
        } catch {}
    }

    /// @notice needed to advance time in the fuzz lifecycle (e.g. createProposal - mint - warp - execute - warp - vote)
    /// @dev introduces time as a random variable in the fuzz process
    function warp(uint256 _secondsSeed) external {
        vm.warp(block.timestamp + bound(_secondsSeed, 1 hours, 30 days));
        vm.roll(block.number + 1);
    }
}
