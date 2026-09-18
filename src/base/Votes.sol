// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {Proposal} from "./Proposal.sol";

/// @title  Votes
/// @author NicoSerranoP (fork of Aragon X 2021-2025)
/// @notice Holds vote-casting and vote-eligibility logic.
abstract contract Votes is Proposal, IMembership {
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
        IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);

        // This could re-enter, though we can assume the governance token is not malicious
        uint256 votingPower = proposalVotingToken.getPastVotes(_voter, proposal_.parameters.snapshotTimepoint);
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
        IVotesUpgradeable proposalVotingToken = IVotesUpgradeable(proposal_.parameters.votingToken);

        // The proposal vote hasn't started or has already ended.
        if (!_isProposalOpen(proposal_)) {
            return false;
        }

        // The voter votes `None` which is not allowed.
        if (_voteOption == VoteOption.None) {
            return false;
        }

        // The voter has no voting power.
        if (proposalVotingToken.getPastVotes(_account, proposal_.parameters.snapshotTimepoint) == 0) {
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

    /// @inheritdoc IMembership
    function isMember(address _account) external view returns (bool) {
        // A member must have at least one token delegated to her/him or own at least one token at current time.
        return votingToken.getVotes(_account) > 0 || IERC721Upgradeable(address(votingToken)).balanceOf(_account) > 0;
    }
}
