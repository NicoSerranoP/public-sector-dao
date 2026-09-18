// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/* solhint-disable max-line-length */

import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IProposal} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/IProposal.sol";
import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";
import {RATIO_BASE, _applyRatioCeiled} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";

import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {Settings} from "./Settings.sol";

/// @title Proposal
/// @author NicoSerranoP (fork of Aragon X 2021-2025)
/// @notice Holds proposal creation, execution and success-evaluation logic.
abstract contract Proposal is Settings {
    using SafeCastUpgradeable for uint256;

    /// @notice The ID of the permission required to call the `execute` function.
    bytes32 public constant EXECUTE_PROPOSAL_PERMISSION_ID = keccak256("EXECUTE_PROPOSAL_PERMISSION");

    /// @notice A mapping between proposal IDs and proposal information.
    // solhint-disable-next-line named-parameters-mapping
    mapping(uint256 => Proposal) internal proposals;

    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyIfProposalExists(uint256 _proposalId) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }
        _;
    }

    /// @inheritdoc IProposal
    /// @dev Requires the proposal to be executable and the caller to hold voting power in the snapshotted token.
    function execute(uint256 _proposalId) public virtual override(IProposal) {
        Proposal storage proposal_ = proposals[_proposalId];
        IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);

        if (
            !_canExecute(_proposalId)
                || proposalVotingToken.getPastVotes(_msgSender(), proposal_.parameters.snapshotTimepoint) == 0
        ) {
            revert ProposalExecutionForbidden(_proposalId);
        }

        _execute(_proposalId);
    }

    /// @notice Internal function to execute a proposal. It assumes the queried proposal exists.
    /// @param _proposalId The ID of the proposal.
    function _execute(uint256 _proposalId) internal virtual {
        Proposal storage proposal_ = proposals[_proposalId];

        proposal_.executed = true;

        (, uint256 resultFailureMap) = _execute(
            proposal_.targetConfig.target,
            bytes32(_proposalId),
            proposal_.actions,
            proposal_.allowFailureMap,
            proposal_.targetConfig.operation
        );

        emit ProposalExecutionResult(_proposalId, resultFailureMap);
        emit ProposalExecuted(_proposalId);
    }

    function canExecute(uint256 _proposalId)
        public
        view
        virtual
        override(IProposal)
        onlyIfProposalExists(_proposalId)
        returns (bool)
    {
        return _canExecute(_proposalId);
    }

    /// @notice Internal function to check if a proposal can be executed. It assumes the queried proposal exists.
    /// @dev Threshold and minimal values are compared with `>` and `>=` comparators, respectively.
    /// @param _proposalId The ID of the proposal.
    /// @return True if the proposal can be executed, false otherwise.
    function _canExecute(uint256 _proposalId) internal view virtual returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];

        // Verify that the vote has not been executed already.
        if (proposal_.executed) {
            return false;
        }

        bool isProposalOpen = _isProposalOpen(proposal_);

        // For Standard and VoteReplacement modes, enforce waiting until end date
        if (proposal_.parameters.votingMode != VotingMode.EarlyExecution && isProposalOpen) {
            return false;
        }

        return _hasSucceeded(_proposalId, isProposalOpen);
    }

    /// @inheritdoc IProposal
    function hasSucceeded(uint256 _proposalId) public view virtual onlyIfProposalExists(_proposalId) returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];
        bool isProposalOpen = _isProposalOpen(proposal_);

        return _hasSucceeded(_proposalId, isProposalOpen);
    }

    /// @notice An internal function that checks if the proposal succeeded or not.
    /// @param _proposalId The ID of the proposal.
    /// @param _isOpen Weather the proposal is open or not.
    /// @return Returns `true` if the proposal succeeded depending on the thresholds and voting modes.
    function _hasSucceeded(uint256 _proposalId, bool _isOpen) internal view virtual returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];

        if (_isOpen) {
            // Success while still open is only meaningful for EarlyExecution mode, since that's the
            // only mode `_canExecute` allows to execute before `endDate`. Standard and VoteReplacement
            // proposals can still receive opposing votes, so success can't be determined until closed.
            if (proposal_.parameters.votingMode != VotingMode.EarlyExecution) {
                return false;
            }

            if (!isSupportThresholdReachedEarly(_proposalId)) {
                return false;
            }
        } else {
            // When the proposal is closed, check if the support threshold
            // has been reached based on final voting results.
            if (!isSupportThresholdReached(_proposalId)) {
                return false;
            }
        }

        if (!isMinParticipationReached(_proposalId)) {
            return false;
        }

        if (!isMinApprovalReached(_proposalId)) {
            return false;
        }

        return true;
    }

    function isSupportThresholdReached(uint256 _proposalId) public view virtual returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];

        return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
            > proposal_.parameters.supportThreshold * proposal_.tally.no;
    }

    function isSupportThresholdReachedEarly(uint256 _proposalId) public view virtual returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];
        IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);

        uint256 noVotesWorstCase = proposalVotingToken.getPastTotalSupply(proposal_.parameters.snapshotTimepoint)
            - proposal_.tally.yes - proposal_.tally.abstain;

        return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
            > proposal_.parameters.supportThreshold * noVotesWorstCase;
    }

    function isMinParticipationReached(uint256 _proposalId) public view virtual returns (bool) {
        if (!_proposalExists(_proposalId)) {
            return false;
        }

        Proposal storage proposal_ = proposals[_proposalId];

        return proposal_.tally.yes + proposal_.tally.no + proposal_.tally.abstain >= proposal_.parameters.minVotingPower;
    }

    function isMinApprovalReached(uint256 _proposalId) public view virtual returns (bool) {
        if (!_proposalExists(_proposalId)) {
            return false;
        }

        return proposals[_proposalId].tally.yes >= proposals[_proposalId].minApprovalPower;
    }

    /// @notice Returns whether `_account` currently meets the voting-power threshold required to
    ///     create a proposal: needs more or equal voting power than the minimal proposer voting power
    /// @param _account The address to check.
    /// @return Whether `_account` can call `createProposal`.
    function canCreateProposal(address _account) public view virtual returns (bool) {
        uint256 snapshotTimepoint;
        unchecked {
            // The time point must be already mined (block) or in the past (timestamp) to
            // protect against backrunning transactions causing census changes.
            if (tokenIndexedByTimestamp) {
                snapshotTimepoint = block.timestamp - 1;
            } else {
                snapshotTimepoint = block.number - 1;
            }
        }

        uint256 minProposerVotingPower_ = minProposerVotingPower();
        if (minProposerVotingPower_ == 0) {
            return true;
        }

        return votingToken.getPastVotes(_account, snapshotTimepoint) >= minProposerVotingPower_;
    }

    /// @notice Returns all information for a proposal by its ID.
    /// @param _proposalId The ID of the proposal.
    /// @return open Whether the proposal is open or not.
    /// @return executed Whether the proposal is executed or not.
    /// @return parameters The parameters of the proposal.
    /// @return tally The current tally of the proposal.
    /// @return actions The actions to be executed to the `target` contract address.
    /// @return allowFailureMap The bit map representations of which actions are allowed to revert so tx still succeeds.
    /// @return targetConfig Execution configuration, applied to the proposal when it was created. Added in build 3.
    function getProposal(uint256 _proposalId)
        public
        view
        virtual
        returns (
            bool open,
            bool executed,
            ProposalParameters memory parameters,
            Tally memory tally,
            Action[] memory actions,
            uint256 allowFailureMap,
            TargetConfig memory targetConfig
        )
    {
        Proposal storage proposal_ = proposals[_proposalId];

        open = _isProposalOpen(proposal_);
        executed = proposal_.executed;
        parameters = proposal_.parameters;
        tally = proposal_.tally;
        actions = proposal_.actions;
        allowFailureMap = proposal_.allowFailureMap;
        targetConfig = proposal_.targetConfig;
    }

    /// @notice Internal function to check if a proposal is still open.
    /// @param proposal_ The proposal struct.
    /// @return True if the proposal is open, false otherwise.
    function _isProposalOpen(Proposal storage proposal_) internal view virtual returns (bool) {
        uint64 currentTime = block.timestamp.toUint64();

        return proposal_.parameters.startDate <= currentTime && currentTime < proposal_.parameters.endDate
            && !proposal_.executed;
    }

    /// @notice Creates a new majority voting proposal.
    /// @dev Check canCreateProposal() to determine if sender can do it
    /// @param _metadata The metadata of the proposal.
    /// @param _actions The actions that will be executed after the proposal passes.
    /// @param _allowFailureMap Allows proposal to succeed even if an action reverts.
    ///     Uses bitmap representation.
    ///     If the bit at index `x` is 1, the tx succeeds even if the action at `x` failed.
    ///     Passing 0 will be treated as atomic execution.
    /// @param _startDate The start date of the proposal vote.
    ///     If 0, the current timestamp is used and the vote starts immediately.
    /// @param _endDate The end date of the proposal vote.
    ///     If 0, `_startDate + minDuration` is used.
    /// @return proposalId The ID of the proposal.
    function createProposal(
        bytes calldata _metadata,
        Action[] calldata _actions,
        uint256 _allowFailureMap,
        uint64 _startDate,
        uint64 _endDate
    ) public virtual returns (uint256 proposalId) {
        if (!canCreateProposal(_msgSender())) {
            revert ProposalCreationForbidden(_msgSender());
        }

        require(_actions.length <= 256, "Too many actions (256+) in the proposal");

        uint256 snapshotTimepoint;
        unchecked {
            // The time point must be already mined (block) or in the past (timestamp) to
            // protect against backrunning transactions causing census changes.
            if (tokenIndexedByTimestamp) {
                snapshotTimepoint = block.timestamp - 1;
            } else {
                snapshotTimepoint = block.number - 1;
            }
        }

        uint256 totalVotingPower_ = totalVotingPower(snapshotTimepoint);

        if (totalVotingPower_ == 0) {
            revert NoVotingPower();
        }

        (_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);

        proposalId = _createProposalId(keccak256(abi.encode(_msgSender(), _actions, _metadata)));

        if (_proposalExists(proposalId)) {
            revert ProposalAlreadyExists(proposalId);
        }

        // Store proposal related information
        Proposal storage proposal_ = proposals[proposalId];

        proposal_.parameters.startDate = _startDate;
        proposal_.parameters.endDate = _endDate;
        proposal_.parameters.snapshotTimepoint = snapshotTimepoint.toUint64();
        proposal_.parameters.votingToken = address(votingToken);
        proposal_.parameters.votingMode = votingMode();
        proposal_.parameters.supportThreshold = supportThreshold();
        proposal_.parameters.minVotingPower = _applyRatioCeiled(totalVotingPower_, minParticipation());

        proposal_.minApprovalPower = _applyRatioCeiled(totalVotingPower_, minApproval());

        proposal_.targetConfig = getTargetConfig();

        // Reduce costs
        if (_allowFailureMap != 0) {
            proposal_.allowFailureMap = _allowFailureMap;
        }

        for (uint256 i; i < _actions.length;) {
            proposal_.actions.push(_actions[i]);
            unchecked {
                ++i;
            }
        }

        _emitProposalCreatedEvent(_metadata, _actions, _allowFailureMap, proposalId, _startDate, _endDate);
    }

    /// @dev Helper function to avoid stack too deep in non via-ir compilation mode.
    function _emitProposalCreatedEvent(
        bytes calldata _metadata,
        Action[] calldata _actions,
        uint256 _allowFailureMap,
        uint256 proposalId,
        uint64 _startDate,
        uint64 _endDate
    ) private {
        emit ProposalCreated(proposalId, _msgSender(), _startDate, _endDate, _metadata, _actions, _allowFailureMap);
    }

    /// @inheritdoc IProposal
    function createProposal(
        bytes calldata _metadata,
        Action[] calldata _actions,
        uint64 _startDate,
        uint64 _endDate,
        bytes memory _data
    ) external virtual override returns (uint256 proposalId) {
        // Note that this calls public function for permission check.
        uint256 allowFailureMap;

        if (_data.length != 0) {
            (allowFailureMap) = abi.decode(_data, (uint256));
        }

        proposalId = createProposal(_metadata, _actions, allowFailureMap, _startDate, _endDate);
    }

    /// @inheritdoc IProposal
    // forge-lint: disable-next-line(mixed-case-function)
    function customProposalParamsABI() external pure override returns (string memory) {
        return "(uint256 allowFailureMap)";
    }

    /// @notice Checks if proposal exists or not.
    /// @param _proposalId The ID of the proposal.
    /// @return Returns `true` if proposal exists, otherwise false.
    function _proposalExists(uint256 _proposalId) private view returns (bool) {
        return proposals[_proposalId].parameters.snapshotTimepoint != 0;
    }

    /// @notice Validates and returns the proposal dates.
    /// @param _start The start date of the proposal.
    ///     If 0, the current timestamp is used and the vote starts immediately.
    /// @param _end The end date of the proposal. If 0, `_start + minDuration` is used.
    /// @return startDate The validated start date of the proposal.
    /// @return endDate The validated end date of the proposal.
    function _validateProposalDates(uint64 _start, uint64 _end)
        internal
        view
        virtual
        returns (uint64 startDate, uint64 endDate)
    {
        uint64 currentTimestamp = block.timestamp.toUint64();

        if (_start == 0) {
            startDate = currentTimestamp;
        } else {
            startDate = _start;

            if (startDate < currentTimestamp) {
                revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
            }

            if (startDate > currentTimestamp + votingSettings.maxBoundDate) {
                revert DateOutOfBounds({limit: currentTimestamp + votingSettings.maxBoundDate, actual: startDate});
            }
        }

        // Since `minDuration` is limited to 1 year,
        // `startDate + minDuration` can only overflow if the `startDate` is after `type(uint64).max - minDuration`.
        // In this case with Solidity 0.8+ overflow checks, the proposal creation will revert and another date can be picked.
        uint64 earliestEndDate = startDate + votingSettings.minDuration;

        if (_end == 0) {
            endDate = earliestEndDate;
        } else {
            endDate = _end;

            if (endDate < earliestEndDate) {
                revert DateOutOfBounds({limit: earliestEndDate, actual: endDate});
            }

            // Mirrors the configurable ceiling already enforced on `minDuration` in `Settings`
            uint64 latestEndDate = startDate + votingSettings.maxBoundDate;

            if (endDate > latestEndDate) {
                revert DateOutOfBounds({limit: latestEndDate, actual: endDate});
            }
        }
    }
}
