// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import {ALICE_ADDRESS, BOB_ADDRESS, CAROL_ADDRESS, DAVID_ADDRESS} from "../constants.sol";

contract TestBase is Test {
    // Convenience actors for testing
    address immutable ALICE = ALICE_ADDRESS;
    address immutable BOB = BOB_ADDRESS;
    address immutable CAROL = CAROL_ADDRESS;
    address immutable DAVID = DAVID_ADDRESS;
    address immutable RANDOM_ADDRESS = vm.addr(1234567890);

    uint64 constant ONE_HOUR = 3600;
    uint32 constant RATIO_BASE = 1_000_000;

    constructor() {
        vm.roll(10);
        vm.warp(100_000);

        vm.label(ALICE, "Alice");
        vm.label(BOB, "Bob");
        vm.label(CAROL, "Carol");
        vm.label(DAVID, "David");
        vm.label(RANDOM_ADDRESS, "Random wallet");

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

    function successfulActionOne() external pure returns (uint256) {
        return 1;
    }

    function successfulActionTwo() external pure returns (uint256) {
        return 2;
    }

    function _one(address _a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = _a;
    }
}
