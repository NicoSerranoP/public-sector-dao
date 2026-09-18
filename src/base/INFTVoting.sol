// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";

/// @title INFTVoting
/// @author NicoSerranoP (fork of Aragon X 2022-2025)
/// @notice The interface of majority voting plugin.
interface INFTVoting {
    /// @notice The different voting modes available.
    /// @param Standard In standard mode, early execution and vote replacement are disabled.
    /// @param EarlyExecution In early execution mode, a proposal can be executed
    ///     early before the end date if the vote outcome cannot mathematically change by more voters voting.
    /// @param VoteReplacement In vote replacement mode, voters can change their vote
    ///     multiple times and only the latest vote option is tallied.
    enum VotingMode {
        Standard,
        EarlyExecution,
        VoteReplacement
    }

    /// @notice Vote options that a voter can chose from.
    /// @param None The default option state of a voter indicating the absence from the vote.
    ///     This option neither influences support nor participation.
    /// @param Abstain This option does not influence the support but counts towards participation.
    /// @param Yes This option increases the support and counts towards participation.
    /// @param No This option decreases the support and counts towards participation.
    enum VoteOption {
        None,
        Abstain,
        Yes,
        No
    }

    /// @notice A container for the majority voting settings that will be applied as parameters on proposal creation.
    /// @param votingMode A parameter to select the vote mode.
    ///     In standard mode (0), early execution and vote replacement are disabled.
    ///     In early execution mode (1), a proposal can be executed early before the end date
    ///     if the vote outcome cannot mathematically change by more voters voting.
    ///     In vote replacement mode (2), voters can change their vote multiple times
    ///     and only the latest vote option is tallied.
    /// @param supportThreshold The support threshold value.
    ///     Its value has to be in the interval [0, 10^6) defined by `RATIO_BASE = 10**6 = 1,000,000 = 100%`.
    /// @param minParticipation The minimum participation value.
    ///     Its value has to be in the interval [1, 900_000] where 1,000,000 = 100%.
    /// @param minDuration The minimum duration of the proposal vote in seconds.
    /// @param maxBoundDate The maximum allowed offset in seconds for proposal start/end dates.
    /// @param minProposerVotingPower The minimum voting power required to create a proposal.
    /// @param minApprovals The minimum ratio of yes votes needed for a proposal to succeed.
    ///     Its value has to be in the interval [1, 900_000] where 1,000,000 = 100%.
    struct VotingSettings {
        VotingMode votingMode;
        uint32 supportThreshold;
        uint32 minParticipation;
        uint64 minDuration;
        uint64 maxBoundDate;
        uint256 minProposerVotingPower;
        uint256 minApprovals;
    }

    /// @notice A container for proposal-related information.
    /// @param executed Whether the proposal is executed or not.
    /// @param parameters The proposal parameters at the time of the proposal creation.
    /// @param tally The vote tally of the proposal.
    /// @param voters The votes casted by the voters.
    /// @param actions The actions to be executed when the proposal passes.
    /// @param allowFailureMap A bitmap allowing the proposal to succeed, even if individual actions might revert.
    ///     If the bit at index `i` is 1, the proposal succeeds even if the `i`th action reverts.
    ///     A failure map value of 0 requires every action to not revert.
    /// @param minApprovalPower The minimum amount of yes votes power needed for the proposal advance.
    /// @param targetConfig Configuration for the execution target, specifying the target address and operation type
    ///     (either `Call` or `DelegateCall`). Defined by `TargetConfig` in the `IPlugin` interface,
    ///     part of the `osx-commons-contracts` package, added in build 3.
    struct Proposal {
        bool executed;
        ProposalParameters parameters;
        Tally tally;
        mapping(address => VoteOption) voters;
        Action[] actions;
        uint256 allowFailureMap;
        uint256 minApprovalPower;
        IPlugin.TargetConfig targetConfig; // added in v1.3
    }

    /// @notice A container for the proposal parameters at the time of proposal creation.
    /// @param votingMode A parameter to select the vote mode.
    /// @param supportThreshold The support threshold value.
    ///     The value has to be in the interval [0, 10^6) defined by `RATIO_BASE = 10**6 = 1,000,000 = 100%`.
    /// @param startDate The start date of the proposal vote.
    /// @param endDate The end date of the proposal vote.
    /// @param snapshotTimepoint The number of the block prior to the proposal creation.
    /// @param votingToken The voting token used to evaluate the proposal.
    /// @param minVotingPower The minimum voting power needed for a proposal to reach minimum participation.
    struct ProposalParameters {
        VotingMode votingMode;
        uint32 supportThreshold;
        uint64 startDate;
        uint64 endDate;
        uint64 snapshotTimepoint;
        address votingToken;
        uint256 minVotingPower;
    }

    /// @notice A container for the proposal vote tally.
    /// @param abstain The number of abstain votes casted.
    /// @param yes The number of yes votes casted.
    /// @param no The number of no votes casted.
    struct Tally {
        uint256 abstain;
        uint256 yes;
        uint256 no;
    }

    /// @notice Emitted when a vote is cast by a voter.
    /// @param proposalId The ID of the proposal.
    /// @param voter The voter casting the vote.
    /// @param voteOption The casted vote option.
    /// @param votingPower The voting power behind this vote.
    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteOption voteOption, uint256 votingPower);

    /// @notice Emitted when the voting settings are updated.
    /// @param votingMode A parameter to select the vote mode.
    /// @param supportThreshold The support threshold value.
    /// @param minParticipation The minimum participation value.
    /// @param minDuration The minimum duration of the proposal vote in seconds.
    /// @param maxBoundDate The maximum allowed offset in seconds for proposal start/end dates.
    /// @param minProposerVotingPower The minimum voting power required to create a proposal.
    /// @param minApprovals The minimum ratio of yes votes needed for a proposal to succeed.
    event VotingSettingsUpdated(
        VotingMode votingMode,
        uint32 supportThreshold,
        uint32 minParticipation,
        uint64 minDuration,
        uint64 maxBoundDate,
        uint256 minProposerVotingPower,
        uint256 minApprovals
    );

    /// @notice Emitted when the voting token is updated.
    /// @param votingToken The new ERC-721 voting token.
    event VotingTokenUpdated(address votingToken);

    /// @notice Emitted when a proposal is executed, exposing which allowed-to-fail actions failed.
    /// @param proposalId The ID of the proposal.
    /// @param resultFailureMap Bitmap of failed actions returned by the executor.
    event ProposalExecutionResult(uint256 indexed proposalId, uint256 resultFailureMap);

    /// @notice Thrown if a date is out of bounds.
    /// @param limit The limit value.
    /// @param actual The actual value.
    error DateOutOfBounds(uint64 limit, uint64 actual);

    /// @notice Thrown if the minimal duration value is out of bounds (less than one hour or greater than 1 year).
    /// @param limit The limit value.
    /// @param actual The actual value.
    error MinDurationOutOfBounds(uint64 limit, uint64 actual);

    /// @notice Thrown when a proposal doesn't exist.
    /// @param proposalId The ID of the proposal which doesn't exist.
    error NonexistentProposal(uint256 proposalId);

    /// @notice Thrown if an account is not allowed to cast a vote. This can be because the vote
    /// - has not started,
    /// - has ended,
    /// - was executed, or
    /// - the account doesn't have voting powers.
    /// @param proposalId The ID of the proposal.
    /// @param account The address of the _account.
    /// @param voteOption The chosen vote option.
    error VoteCastForbidden(uint256 proposalId, address account, VoteOption voteOption);

    /// @notice Thrown if the proposal execution is forbidden.
    /// @param proposalId The ID of the proposal.
    error ProposalExecutionForbidden(uint256 proposalId);

    /// @notice Thrown if the proposal with same actions and metadata already exists.
    /// @param proposalId The id of the proposal.
    error ProposalAlreadyExists(uint256 proposalId);

    /// @notice Thrown if the voting power is zero
    error NoVotingPower();

    /// @notice Thrown if the account is not allowed to create a proposal, either because there is
    ///     no voting power in the DAO at all, or because the account doesn't individually meet
    ///     `minProposerVotingPower`.
    /// @param account The address that attempted to create the proposal.
    error ProposalCreationForbidden(address account);

    /// @notice Thrown if no voting token is set.
    error NoVotingToken();
}
