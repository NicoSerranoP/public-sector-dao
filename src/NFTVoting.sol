// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/* solhint-disable max-line-length */

import {IDAO} from "@aragon/osx/core/dao/DAO.sol";
import {IMembership} from "@aragon/osx-commons-contracts/src/plugin/extensions/membership/IMembership.sol";

import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {INFTVoting} from "./base/INFTVoting.sol";
import {Settings} from "./base/Settings.sol";
import {Votes} from "./base/Votes.sol";

/// @title NFTVoting
/// @author NicoSerranoP (fork of Aragon X 2021-2025)
/// @dev  See the "How voting works" section in README.md
/// @dev Assembles from Settings (voting settings & token), Proposal (creation & execution) and Votes (voting
contract NFTVoting is Votes {
    /// @notice The [ERC-165](https://eips.ethereum.org/EIPS/eip-165) interface ID of the contract.
    /// @dev Uses the exact local overload signature because 2 `createProposal` functions exist in this contract.
    bytes4 internal constant MAJORITY_VOTING_BASE_INTERFACE_ID = this.minDuration.selector
        ^ this.getVotingToken.selector ^ this.minProposerVotingPower.selector ^ this.votingMode.selector
        ^ this.totalVotingPower.selector ^ this.getProposal.selector ^ this.updateVotingSettings.selector
        ^ bytes4(keccak256("createProposal(bytes,(address,uint256,bytes)[],uint256,uint64,uint64)"));

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
    function supportsInterface(bytes4 _interfaceId) public view virtual override(Settings) returns (bool) {
        return _interfaceId == type(IMembership).interfaceId || _interfaceId == type(INFTVoting).interfaceId
            || _interfaceId == MAJORITY_VOTING_BASE_INTERFACE_ID || super.supportsInterface(_interfaceId);
    }
}
