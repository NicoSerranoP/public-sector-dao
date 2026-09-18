// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {DaoUnauthorized} from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC5267Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC5267Upgradeable.sol";

import {NFTVoting} from "../src/NFTVoting.sol";
import {GovernanceERC721} from "../src/erc721/GovernanceERC721.sol";
import {NFTDAOBuilder} from "./lib/NFTDAOBuilder.sol";
import {TestBase} from "./lib/TestBase.sol";
import {MockGovernanceERC721} from "./mocks/MockGovernanceERC721.sol";

contract GovernanceERC721Test is TestBase {
    DAO dao;
    NFTVoting plugin;
    GovernanceERC721 nft;

    /// @dev Builds a DAO + NFTVoting where each entry in `_receivers` gets one NFT.
    function _build(address[] memory _receivers) internal {
        IVotesUpgradeable token_;
        (dao, plugin, token_) = new NFTDAOBuilder().withNewToken(_receivers).build();
        nft = GovernanceERC721(address(token_));
    }

    // -----------------------------------------------------------------------
    // voting token: admin transfer / burn / base URI
    // -----------------------------------------------------------------------

    function test_WhenTheAdminForceTransfersTheNFT_ItMovesWithoutHolderApproval() external {
        _build(_one(ALICE));

        // Grant the test contract the force-transfer permission: dao.grant(where, who, permission)
        dao.grant(address(nft), address(this), nft.TRANSFER_PERMISSION_ID());

        vm.expectEmit(true, true, true, true, address(nft));
        emit GovernanceERC721.AdminTransfer(ALICE, BOB, 1);
        nft.adminTransfer(ALICE, BOB, 1);

        assertEq(nft.ownerOf(1), BOB, "NFT force-transferred to bob");
        assertEq(nft.balanceOf(ALICE), 0);
    }

    function test_WhenAForceTransferCallerLacksThePermission_ItReverts() external {
        _build(_one(ALICE));

        bytes memory expectedErr = abi.encodeWithSelector(
            DaoUnauthorized.selector, address(dao), address(nft), BOB, nft.TRANSFER_PERMISSION_ID()
        );

        vm.prank(BOB);
        vm.expectRevert(expectedErr);
        nft.adminTransfer(ALICE, BOB, 1);
    }

    function test_WhenAnNFTIsBurned_ItsVotingPowerIsRemoved() external {
        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: "Test NFT", symbol: "TNFT", baseURI: "https://example.com/", receivers: new address[](0)
        });

        MockGovernanceERC721 token_ = new MockGovernanceERC721(IDAO(address(0)), settings);

        token_.mintTo(ALICE);
        token_.mintTo(BOB);

        (dao, plugin,) = new NFTDAOBuilder().withToken(IVotesUpgradeable(address(token_))).build();

        assertEq(plugin.totalVotingPower(block.number - 1), 2, "two NFTs delegated");

        token_.burnToken(2); // burn bob's NFT

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(plugin.totalVotingPower(block.number - 1), 1, "burning removed one unit of voting power");
    }

    function test_WhenABurnCallerLacksThePermission_ItReverts() external {
        _build(_one(ALICE));

        bytes memory expectedErr =
            abi.encodeWithSelector(DaoUnauthorized.selector, address(dao), address(nft), BOB, nft.BURN_PERMISSION_ID());

        vm.prank(BOB);
        vm.expectRevert(expectedErr);
        nft.burn(1);
    }

    function test_WhenTheAdminUpdatesTheBaseURI_ItSucceeds() external {
        _build(_one(ALICE));

        // Grant the test contract the update base URI permission: dao.grant(where, who, permission)
        dao.grant(address(nft), address(this), nft.UPDATE_BASE_URI_ID());

        string memory newBaseURI = "https://new-base-uri.com/";
        nft.setBaseURI(newBaseURI);

        assertEq(nft.baseURI(), newBaseURI);
    }

    function test_WhenANonAdminUpdatesTheBaseURI_ItReverts() external {
        _build(_one(ALICE));

        bytes memory expectedErr =
            abi.encodeWithSelector(DaoUnauthorized.selector, address(dao), address(nft), BOB, nft.UPDATE_BASE_URI_ID());

        vm.prank(BOB);
        vm.expectRevert(expectedErr);
        nft.setBaseURI("https://new-base-uri.com/");
    }

    function test_WhenQueryingSupportsInterface_ItIncludesEIP5267() external {
        _build(_one(ALICE));

        assertTrue(nft.supportsInterface(type(IERC5267Upgradeable).interfaceId));
    }
}
