// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title MockPlainERC721
/// @notice A bare [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token with no
///     [`Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes) support.
/// @dev Used to prove that `NFTVoting` rejects ERC-721 tokens that are not Votes-compatible.
///     DO NOT USE IN PRODUCTION!
contract MockPlainERC721 is Initializable, ERC721Upgradeable {
    constructor() initializer {
        __ERC721_init("Plain NFT", "PLAIN");
    }
}
