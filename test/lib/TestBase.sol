// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IPluginSetup, PluginSetup} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {NFTVoting} from "../../src/NFTVoting.sol";
import {GovernanceERC721} from "../../src/erc721/GovernanceERC721.sol";
import {ALICE_ADDRESS, BOB_ADDRESS, CAROL_ADDRESS, DAVID_ADDRESS} from "../constants.sol";

contract TestBase is Test {
    // Convenience actors for testing
    address immutable alice = ALICE_ADDRESS;
    address immutable bob = BOB_ADDRESS;
    address immutable carol = CAROL_ADDRESS;
    address immutable david = DAVID_ADDRESS;
    address immutable randomAddress = vm.addr(1234567890);

    uint64 constant ONE_HOUR = 3600;
    uint32 constant RATIO_BASE = 1_000_000;

    constructor() {
        vm.roll(10);
        vm.warp(100_000);

        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(carol, "Carol");
        vm.label(david, "David");
        vm.label(randomAddress, "Random wallet");

        // Assume that we are testing on Sepolia (used to compute proposal ID's)
        vm.chainId(11155111);
    }

    /// @notice Returns the address and private key associated to the given name.
    /// @param name The name to get the address and private key for.
    /// @return addr The address associated with the name.
    /// @return pk The private key associated with the name.
    function makeWallet(string memory name) internal returns (address addr, uint256 pk) {
        pk = uint256(keccak256(abi.encodePacked(name)));
        addr = vm.addr(pk);
        vm.label(addr, name);
    }

    function _dummyActions() internal pure returns (Action[] memory actions) {
        actions = new Action[](0);
    }

    function _one(address _a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = _a;
    }
}
