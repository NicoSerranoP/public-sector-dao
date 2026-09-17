// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {TestBase} from "./TestBase.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {DAOFactory} from "@aragon/osx/framework/dao/DAOFactory.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {PermissionManager} from "@aragon/osx/core/permission/PermissionManager.sol";

contract ForkTestBase is TestBase {
    // Default for OSx v1.4 on Sepolia
    DAOFactory internal immutable DAO_FACTORY =
        DAOFactory(vm.envOr("DAO_FACTORY_ADDRESS", address(0xB815791c233807D39b7430127975244B36C19C8e)));

    constructor() {
        vm.roll(10);
        vm.warp(100_000);

        vm.label(address(DAO_FACTORY), "DaoFactory");
        vm.createSelectFork(vm.envString("RPC_URL"));
    }

    /// @dev Creates a DAO with the given orchestration settings.
    /// @dev The setup is done on block/timestamp 0. Tests should be block/timestamp >= 1
    function build() public returns (DAO dao) {
        DAOFactory.DAOSettings memory daoSettings =
            DAOFactory.DAOSettings({trustedForwarder: address(0), daoURI: "http://host/", subdomain: "", metadata: ""});
        // No plugins, the sender (aka anyone) can execute
        DAOFactory.PluginSettings[] memory installSettings = new DAOFactory.PluginSettings[](0);
        DAOFactory.InstalledPlugin[] memory installedPlugins;

        (dao, installedPlugins) = DAO_FACTORY.createDao(daoSettings, installSettings);

        // Set this test contract as the owner
        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            to: address(dao),
            value: 0,
            data: abi.encodeCall(PermissionManager.grant, (address(dao), address(this), dao.ROOT_PERMISSION_ID()))
        });
        dao.execute(bytes32(0), actions, 0);

        vm.label(address(dao), "DAO");
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }
}
