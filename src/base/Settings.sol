// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/* solhint-disable max-line-length */

import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
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

import {INFTVoting} from "./INFTVoting.sol";

/// @title Settings
/// @author NicoSerranoP (fork of Aragon X 2021-2025)
/// @notice Holds the voting settings and the voting token, and the logic to update them.
abstract contract Settings is INFTVoting, MetadataExtensionUpgradeable, PluginCloneable, ProposalUpgradeable {
    /// @notice The ID of the permission required to call the `updateVotingSettings` and
    ///     `updateVotingToken` functions.
    bytes32 public constant UPDATE_VOTING_SETTINGS_PERMISSION_ID = keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");

    /// @notice The struct storing the voting settings.
    VotingSettings internal votingSettings;

    /// @notice An ERC721 NFT [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes)
    IVotesUpgradeable internal votingToken;

    /// @notice Wether the token contract indexes past voting power by timestamp.
    bool public tokenIndexedByTimestamp;

    /// @notice Resolves the `supportsInterface` ambiguity created by inheriting from multiple base
    ///     contracts that each declare it. Left `virtual` so `NFTVoting` can extend it with the
    ///     plugin's own interface IDs.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(MetadataExtensionUpgradeable, PluginCloneable, ProposalUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(_interfaceId);
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

    /// @notice Returns the vote mode stored in the voting settings.
    /// @return The vote mode parameter.
    function votingMode() public view virtual returns (VotingMode) {
        return votingSettings.votingMode;
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

    function minApproval() public view virtual returns (uint256) {
        return votingSettings.minApprovals;
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
    function updateVotingToken(IVotesUpgradeable _token) external virtual auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID) {
        _updateVotingToken(_token);
    }

    /// @notice Internal function to update the voting token.
    /// @param _token The ERC-721 voting token to be validated and set.
    function _updateVotingToken(IVotesUpgradeable _token) internal virtual {
        require(
            IERC165Upgradeable(address(_token)).supportsInterface(type(IERC721Upgradeable).interfaceId),
            "token is not a ERC721"
        );

        require(
            IERC165Upgradeable(address(_token)).supportsInterface(type(IVotesUpgradeable).interfaceId),
            "token is not a Votes Upgradeable (required getVotes and getPastTotalSupply)"
        );

        votingToken = _token;

        _detectTokenClock();

        emit VotingTokenUpdated(address(_token));
    }

    /// @dev Helper function to identify the clock mode used by the given voting token.
    /// @dev `clock()`'s return value determines how the token indexes its checkpoints
    function _detectTokenClock() private {
        try IERC6372Upgradeable(address(votingToken)).clock() returns (uint48 timePoint) {
            tokenIndexedByTimestamp = (timePoint == block.timestamp);
        } catch {
            // Assuming that the token indexes by block number (the ERC-6372 default)
            tokenIndexedByTimestamp = false;
        }
    }
}
