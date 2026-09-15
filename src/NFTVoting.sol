// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/* solhint-disable max-line-length */

import {DAO, IDAO, Action} from "@aragon/osx/core/dao/DAO.sol";
import {IProposal} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/IProposal.sol";
import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";
import {_applyRatioCeiled} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";

import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC165Upgradeable.sol";
import {IERC6372Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";

import {
    ProposalUpgradeable
} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/ProposalUpgradeable.sol";
import {RATIO_BASE, RatioOutOfBounds} from "@aragon/osx-commons-contracts/src/utils/math/Ratio.sol";
import {PluginCloneable} from "@aragon/osx-commons-contracts/src/plugin/PluginCloneable.sol";
import {
    MetadataExtensionUpgradeable
} from "@aragon/osx-commons-contracts/src/utils/metadata/MetadataExtensionUpgradeable.sol";

import {INFTVoting} from "./base/INFTVoting.sol";

/// @title NFTVoting
/// @author NicoSerranoP (fork of Aragon X 2021-2025)
/// @dev  See the "How voting works" section in README.md
contract NFTVoting is INFTVoting, IMembership, MetadataExtensionUpgradeable, PluginCloneable, ProposalUpgradeable {
    using SafeCastUpgradeable for uint256;

    /// @notice The [ERC-165](https://eips.ethereum.org/EIPS/eip-165) interface ID of the contract.
    /// @dev use keccak string due to 2 createProposal functions declared in the contract
    bytes4 internal constant MAJORITY_VOTING_BASE_INTERFACE_ID = this.minDuration.selector
        ^ this.getVotingToken.selector ^ this.minProposerVotingPower.selector ^ this.votingMode.selector
        ^ this.totalVotingPower.selector ^ this.getProposal.selector ^ this.updateVotingSettings.selector
        ^ bytes4(keccak256("createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64,uint8,bool)"));

    /// @notice The ID of the permission required to call the `updateVotingSettings` function.
    bytes32 public constant UPDATE_VOTING_SETTINGS_PERMISSION_ID = keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");

    /// @notice The ID of the permission required to call the `createProposal` functions.
    bytes32 public constant CREATE_PROPOSAL_PERMISSION_ID = keccak256("CREATE_PROPOSAL_PERMISSION");

    /// @notice The ID of the permission required to call the `execute` function.
    bytes32 public constant EXECUTE_PROPOSAL_PERMISSION_ID = keccak256("EXECUTE_PROPOSAL_PERMISSION");

    /// @notice A mapping between proposal IDs and proposal information.
    // solhint-disable-next-line named-parameters-mapping
    mapping(uint256 => Proposal) internal proposals;

    /// @notice The struct storing the voting settings.
    VotingSettings private votingSettings;

    /// @notice An ERC721 NFT [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes)
    IVotesUpgradeable private votingToken;

    /// @notice Wether the token contract indexes past voting power by timestamp.
    bool public tokenIndexedByTimestamp;

    modifier onlyIfProposalExists(uint256 _proposalId) {
        if (!_proposalExists(_proposalId)) {
            revert NonexistentProposal(_proposalId);
        }
        _;
    }

    /// @notice Initializes the component.
    /// @dev This method is required to support [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822).
    /// @param _dao The IDAO interface of the associated DAO.
    /// @param _votingSettings The voting settings.
    /// @param _token The [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token to use for voting.
    ///     If the given token implements https://eips.ethereum.org/EIPS/eip-6372,
    ///     then `CLOCK_MODE()` or `clock()` will determine the clock type used by the plugin.
    ///     The token will be assumed to use a block number based clock otherwise.
    /// @param _targetConfig Configuration for the execution target, specifying the target address and operation type
    ///     (either `Call` or `DelegateCall`). Defined by `TargetConfig` in the `IPlugin` interface,
    ///     part of the `osx-commons-contracts` package, added in build 3.
    /// @param _pluginMetadata The plugin specific information encoded in bytes.
    ///     This can also be an ipfs cid encoded in bytes.
    function initialize(
        IDAO _dao,
        VotingSettings calldata _votingSettings,
        IVotesUpgradeable _token,
        TargetConfig calldata _targetConfig,
        bytes calldata _pluginMetadata
    ) external initializer {
        __PluginCloneable_init(_dao);
        _updateVotingSettings(_votingSettings);
        _updateVotingToken(_token);
        _setTargetConfig(_targetConfig);
        _setMetadata(_pluginMetadata);

        emit MembershipContractAnnounced({definingContract: address(_token)});
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(MetadataExtensionUpgradeable, PluginCloneable, ProposalUpgradeable)
        returns (bool)
    {
        return _interfaceId == type(IMembership).interfaceId || _interfaceId == type(INFTVoting).interfaceId
            || _interfaceId == MAJORITY_VOTING_BASE_INTERFACE_ID || super.supportsInterface(_interfaceId);
    }

    /// @notice getter function for the voting token.
    /// @dev public function also useful for registering interfaceId
    ///      and for distinguishing from majority voting interface.
    /// @return The token used for voting.
    function getVotingToken() public view returns (IVotesUpgradeable) {
        return votingToken;
    }

    /// @notice Returns the total voting power checkpointed for a specific timestamp or block number.
    /// @dev For an [ERC-721](https://eips.ethereum.org/EIPS/eip-721) `Votes` token this equals the number of
    ///     tokens that have been delegated (and are therefore authorized to vote) at `_timePoint`, since each
    ///     token counts as exactly one unit of voting power.
    /// @param _timePoint The block number or timestamp.
    /// @return The total voting power.
    function totalVotingPower(uint256 _timePoint) public view returns (uint256) {
        return votingToken.getPastTotalSupply(_timePoint);
    }

    function vote(uint256 _proposalId, VoteOption _voteOption, bool _tryEarlyExecution) public virtual {
        address account = _msgSender();

        if (!_canVote(_proposalId, account, _voteOption)) {
            revert VoteCastForbidden({proposalId: _proposalId, account: account, voteOption: _voteOption});
        }
        _vote(_proposalId, _voteOption, account, _tryEarlyExecution);
    }

    /// @notice Internal function to cast a vote. It assumes the queried proposal exists.
    /// @param _proposalId The ID of the proposal.
    /// @param _voteOption The chosen vote option to be casted on the proposal vote.
    /// @param _voter The address of the account that is voting on the `_proposalId`.
    /// @param _tryEarlyExecution If `true`,  early execution is tried after the vote cast.
    ///     The call does not revert if early execution is not possible.
    function _vote(uint256 _proposalId, VoteOption _voteOption, address _voter, bool _tryEarlyExecution)
        internal
        virtual
    {
        Proposal storage proposal_ = proposals[_proposalId];

        // This could re-enter, though we can assume the governance token is not malicious
        uint256 votingPower = votingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint);
        VoteOption state = proposal_.voters[_voter];

        // If voter had previously voted, decrease count
        if (state == VoteOption.Yes) {
            proposal_.tally.yes = proposal_.tally.yes - votingPower;
        } else if (state == VoteOption.No) {
            proposal_.tally.no = proposal_.tally.no - votingPower;
        } else if (state == VoteOption.Abstain) {
            proposal_.tally.abstain = proposal_.tally.abstain - votingPower;
        }

        // write the new vote or replace vote for the voter.
        if (_voteOption == VoteOption.Yes) {
            proposal_.tally.yes = proposal_.tally.yes + votingPower;
        } else if (_voteOption == VoteOption.No) {
            proposal_.tally.no = proposal_.tally.no + votingPower;
        } else if (_voteOption == VoteOption.Abstain) {
            proposal_.tally.abstain = proposal_.tally.abstain + votingPower;
        }

        proposal_.voters[_voter] = _voteOption;

        emit VoteCast({proposalId: _proposalId, voter: _voter, voteOption: _voteOption, votingPower: votingPower});

        if (!_tryEarlyExecution) {
            return;
        }

        if (
            _canExecute(_proposalId)
                && dao().hasPermission(address(this), _voter, EXECUTE_PROPOSAL_PERMISSION_ID, _msgData())
        ) {
            _execute(_proposalId);
        }
    }

    /// @inheritdoc IProposal
    /// @dev Requires the `EXECUTE_PROPOSAL_PERMISSION_ID` permission.
    function execute(uint256 _proposalId)
        public
        virtual
        override(IProposal)
        auth(EXECUTE_PROPOSAL_PERMISSION_ID)
    {
        if (!_canExecute(_proposalId)) {
            revert ProposalExecutionForbidden(_proposalId);
        }
        _execute(_proposalId);
    }

    /// @notice Internal function to execute a proposal. It assumes the queried proposal exists.
    /// @param _proposalId The ID of the proposal.
    function _execute(uint256 _proposalId) internal virtual {
        Proposal storage proposal_ = proposals[_proposalId];

        proposal_.executed = true;

        _execute(
            proposal_.targetConfig.target,
            bytes32(_proposalId),
            proposal_.actions,
            proposal_.allowFailureMap,
            proposal_.targetConfig.operation
        );

        emit ProposalExecuted(_proposalId);
    }

    function getVoteOption(uint256 _proposalId, address _voter) public view virtual returns (VoteOption) {
        return proposals[_proposalId].voters[_voter];
    }

    function canVote(uint256 _proposalId, address _account, VoteOption _voteOption)
        public
        view
        virtual
        onlyIfProposalExists(_proposalId)
        returns (bool)
    {
        return _canVote(_proposalId, _account, _voteOption);
    }

    /// @notice Internal function to check if a voter can vote. It assumes the queried proposal exists.
    /// @param _proposalId The ID of the proposal.
    /// @param _account The address of the voter to check.
    /// @param _voteOption Whether the voter abstains, supports or opposes the proposal.
    /// @return Returns `true` if the given voter can vote on a certain proposal and `false` otherwise.
    function _canVote(uint256 _proposalId, address _account, VoteOption _voteOption)
        internal
        view
        virtual
        returns (bool)
    {
        Proposal storage proposal_ = proposals[_proposalId];

        // The proposal vote hasn't started or has already ended.
        if (!_isProposalOpen(proposal_)) {
            return false;
        }

        // The voter votes `None` which is not allowed.
        if (_voteOption == VoteOption.None) {
            return false;
        }

        // The voter has no voting power.
        if (votingToken.getPastVotes(_account, proposal_.parameters.snapshotTimepoint) == 0) {
            return false;
        }

        // The voter has already voted but vote replacment is not allowed.
        if (
            proposal_.voters[_account] != VoteOption.None
                && proposal_.parameters.votingMode != VotingMode.VoteReplacement
        ) {
            return false;
        }

        return true;
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
            // If the proposal is still open and the voting mode is VoteReplacement,
            // success cannot be determined until the voting period ends.
            if (proposal_.parameters.votingMode == VotingMode.VoteReplacement) {
                return false;
            }

            // For Standard and EarlyExecution modes, check if the support threshold
            // has been reached early to determine success while proposal is still open.
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

        uint256 noVotesWorstCase =
            totalVotingPower(proposal_.parameters.snapshotTimepoint) - proposal_.tally.yes - proposal_.tally.abstain;

        return (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes
            > proposal_.parameters.supportThreshold * noVotesWorstCase;
    }

    function isMinParticipationReached(uint256 _proposalId) public view virtual returns (bool) {
        Proposal storage proposal_ = proposals[_proposalId];

        return proposal_.tally.yes + proposal_.tally.no + proposal_.tally.abstain >= proposal_.parameters.minVotingPower;
    }

    function isMinApprovalReached(uint256 _proposalId) public view virtual returns (bool) {
        return proposals[_proposalId].tally.yes >= proposals[_proposalId].minApprovalPower;
    }

    function minApproval() public view virtual returns (uint256) {
        return votingSettings.minApprovals;
    }

    function supportThreshold() public view virtual returns (uint32) {
        return votingSettings.supportThreshold;
    }

    function minParticipation() public view virtual returns (uint32) {
        return votingSettings.minParticipation;
    }

    /// @notice Returns the minimum duration parameter stored in the voting settings.
    /// @return The minimum duration parameter.
    function minDuration() public view virtual returns (uint64) {
        return votingSettings.minDuration;
    }

    /// @notice Returns the minimum voting power required to create a proposal stored in the voting settings.
    /// @return The minimum voting power required to create a proposal.
    function minProposerVotingPower() public view virtual returns (uint256) {
        return votingSettings.minProposerVotingPower;
    }

    /// @notice Returns whether `_account` currently meets the voting-power threshold required to
    ///     create a proposal.
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

    /// @notice Returns the vote mode stored in the voting settings.
    /// @return The vote mode parameter.
    function votingMode() public view virtual returns (VotingMode) {
        return votingSettings.votingMode;
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

    /// @notice Updates the voting settings.
    /// @dev Requires the `UPDATE_VOTING_SETTINGS_PERMISSION_ID` permission.
    /// @param _votingSettings The new voting settings.
    function updateVotingSettings(VotingSettings calldata _votingSettings)
        external
        virtual
        auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)
    {
        _updateVotingSettings(_votingSettings);
    }

    /// @notice Internal function to update the plugin-wide proposal settings.
    /// @param _votingSettings The voting settings to be validated and updated.
    function _updateVotingSettings(VotingSettings calldata _votingSettings) internal virtual {
        // Require the support threshold value to be in the interval [1, 10^6-1],
        // because `>` comparison is used in the support criterion and >100% could never be reached.
        if (_votingSettings.supportThreshold == 0 || _votingSettings.supportThreshold > RATIO_BASE - 1) {
            revert RatioOutOfBounds({limit: RATIO_BASE - 1, actual: _votingSettings.supportThreshold});
        }

        // Require the minimum participation value to be in the interval [1, 10^6],
        // because `>=` comparison is used in the participation criterion.
        if (_votingSettings.minParticipation == 0 || _votingSettings.minParticipation > RATIO_BASE) {
            revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minParticipation});
        }

        if (_votingSettings.minDuration < 60 minutes) {
            revert MinDurationOutOfBounds({limit: 60 minutes, actual: _votingSettings.minDuration});
        }

        if (_votingSettings.minDuration > 365 days) {
            revert MinDurationOutOfBounds({limit: 365 days, actual: _votingSettings.minDuration});
        }

        // Require the minimum approval value to be in the interval [1, 10^6],
        // because `>=` comparison is used in the participation criterion.
        if (_votingSettings.minApprovals == 0 || _votingSettings.minApprovals > RATIO_BASE) {
            revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minApprovals});
        }

        votingSettings = _votingSettings;

        emit VotingSettingsUpdated({
            votingMode: _votingSettings.votingMode,
            supportThreshold: _votingSettings.supportThreshold,
            minParticipation: _votingSettings.minParticipation,
            minDuration: _votingSettings.minDuration,
            minProposerVotingPower: _votingSettings.minProposerVotingPower,
            minApprovals: _votingSettings.minApprovals
        });
    }

    /// @notice Updates the voting token.
    /// @dev Requires the `UPDATE_VOTING_SETTINGS_PERMISSION_ID` permission.
    /// @param _token The new ERC-721 voting token.
    function updateVotingToken(IVotesUpgradeable _token)
        external
        virtual
        auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)
    {
        _updateVotingToken(_token);
    }

    /// @notice Internal function to update the voting token.
    /// @param _token The ERC-721 voting token to be validated and set.
    function _updateVotingToken(IVotesUpgradeable _token) internal virtual {
        require(
            IERC165Upgradeable(address(_token))
            .supportsInterface(type(IERC721Upgradeable).interfaceId),
            "token is not a ERC721"
        );

        require(
            IERC165Upgradeable(address(_token))
            .supportsInterface(type(IVotesUpgradeable).interfaceId),
            "token is not a Votes Upgradeable (required getVotes and getPastTotalSupply)"
        );

        votingToken = _token;

        _detectTokenClock();

        emit VotingTokenUpdated(address(_token));
    }

    /// @notice Creates a new majority voting proposal.
    /// @dev Requires the `CREATE_PROPOSAL_PERMISSION_ID` permission.
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
    /// @param _voteOption The chosen vote option to be casted on proposal creation.
    /// @param _tryEarlyExecution If `true`,  early execution is tried after the vote cast.
    ///     The call does not revert if early execution is not possible.
    /// @return proposalId The ID of the proposal.
    function createProposal(
        bytes calldata _metadata,
        Action[] calldata _actions,
        uint256 _allowFailureMap,
        uint64 _startDate,
        uint64 _endDate,
        VoteOption _voteOption,
        bool _tryEarlyExecution
    ) public virtual auth(CREATE_PROPOSAL_PERMISSION_ID) returns (uint256 proposalId) {
        if (!canCreateProposal(_msgSender())) {
            revert ProposalCreationForbidden(_msgSender());
        }

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

        proposalId = _createProposalId(keccak256(abi.encode(_actions, _metadata)));

        // Store proposal related information
        Proposal storage proposal_ = proposals[proposalId];

        if (proposal_.parameters.snapshotTimepoint != 0) {
            revert ProposalAlreadyExists(proposalId);
        }

        proposal_.parameters.startDate = _startDate;
        proposal_.parameters.endDate = _endDate;
        proposal_.parameters.snapshotTimepoint = snapshotTimepoint.toUint64();
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

        if (_voteOption != VoteOption.None) {
            vote(proposalId, _voteOption, _tryEarlyExecution);
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
        VoteOption _voteOption = VoteOption.None;
        bool tryEarlyExecution;

        if (_data.length != 0) {
            (allowFailureMap, _voteOption, tryEarlyExecution) = abi.decode(_data, (uint256, VoteOption, bool));
        }

        proposalId =
            createProposal(_metadata, _actions, allowFailureMap, _startDate, _endDate, _voteOption, tryEarlyExecution);
    }

    /// @inheritdoc IProposal
    function customProposalParamsABI() external pure override returns (string memory) {
        return "(uint256 allowFailureMap, uint8 voteOption, bool tryEarlyExecution)";
    }

    /// @inheritdoc IMembership
    function isMember(address _account) external view returns (bool) {
        // A member must have at least one token delegated to her/him or own at least one token at current time.
        return votingToken.getVotes(_account) > 0 || IERC721Upgradeable(address(votingToken)).balanceOf(_account) > 0;
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
        }
        // Since `minDuration` is limited to 1 year,
        // `startDate + minDuration` can only overflow if the `startDate` is after `type(uint64).max - minDuration`.
        // In this case, the proposal creation will revert and another date can be picked.
        uint64 earliestEndDate = startDate + votingSettings.minDuration;

        if (_end == 0) {
            endDate = earliestEndDate;
        } else {
            endDate = _end;

            if (endDate < earliestEndDate) {
                revert DateOutOfBounds({limit: earliestEndDate, actual: endDate});
            }
        }
    }

    /// @dev Helper function to identify the clock mode used by the given voting token.
    function _detectTokenClock() private {
        bool clockModeTimestamp;
        bool clockTimestamp;

        try IERC6372Upgradeable(address(votingToken)).CLOCK_MODE() returns (string memory clockMode) {
            clockModeTimestamp = keccak256(bytes(clockMode)) == keccak256(bytes("mode=timestamp"));
        } catch {}
        try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timePoint) {
            clockTimestamp = (timePoint == block.timestamp);
        } catch {}

        if (clockModeTimestamp != clockTimestamp) {
            revert TokenClockMismatch();
        } else if (clockModeTimestamp) {
            tokenIndexedByTimestamp = true;
        } else {
            // Assuming that the token indexes by block number
            tokenIndexedByTimestamp = false;
        }
    }
}
