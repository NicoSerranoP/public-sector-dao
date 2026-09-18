// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

contract MockFailingAction {
    function alwaysRevert() external pure {
        revert("MockFailingAction: always reverts");
    }
}
