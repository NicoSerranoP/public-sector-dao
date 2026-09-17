// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import {MockGovernanceERC721} from "./MockGovernanceERC721.sol";

/// @notice A well-behaved ERC-6372 blocknumber-mode token: `clock()` returns `block.number` and
///     `CLOCK_MODE()` reports the canonical `"mode=blocknumber"` string.
/// @dev DO NOT USE IN PRODUCTION!
contract MockBlockNumberClockToken is MockGovernanceERC721 {
    constructor(IDAO _dao, TokenSettings memory _settings) MockGovernanceERC721(_dao, _settings) {}

    function clock() public view virtual override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=blocknumber";
    }
}
