// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DAO, IDAO} from "@aragon/osx/core/dao/DAO.sol";
import {DAOFactory} from "@aragon/osx/framework/dao/DAOFactory.sol";
import {PermissionManager} from "@aragon/osx/core/permission/PermissionManager.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {ProxyFactory} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyFactory.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {NFTVoting} from "../src/NFTVoting.sol";
import {INFTVoting} from "../src/base/INFTVoting.sol";
import {GovernanceERC721} from "../src/erc721/GovernanceERC721.sol";

/// @notice Bundles the parameters needed to deploy and wire up an `NFTVoting` plugin instance.
/// @dev When `existingToken == address(0)`, a new GovernanceERC721 is minted entirely to the
///     deploying account (`nftCount` NFTs). For a custom initial distribution, mint a token
///     yourself first and pass its address as `existingToken` instead.
struct InstallParams {
    INFTVoting.VotingSettings votingSettings;
    address existingToken;
    string tokenName;
    string tokenSymbol;
    string baseTokenURI;
    uint256 nftCount;
    IPlugin.TargetConfig targetConfig; // target == address(0) resolves to the DAO itself
    bytes pluginMetadata;
}

/**
 * Installs the NFTVoting plugin onto a DAO by deploying and initializing it directly
 * (no PluginSetupProcessor/PluginRepo involved) and wiring up the permissions
 *
 * Two ways to use it:
 * - Create a brand new DAO via Aragon's `DAOFactory` and install onto it (`createDaoAndInstall`).
 * - Install onto an already-deployed DAO (`installOnExistingDao`) — this requires the caller to
 *   already hold `EXECUTE_PERMISSION_ID` on that DAO (e.g. it was just created by this same script,
 *   or the DAO grants it to an admin/operator). Installing into an existing, fully decentralized DAO
 *   normally requires a governance proposal instead — out of scope here.
 */
contract InstallNFTVotingScript is Script {
    using stdJson for string;

    address private constant ANY_ADDR = address(type(uint160).max);

    address deployer;

    // Artifacts
    DAO public dao;
    NFTVoting public plugin;
    IVotesUpgradeable public token;

    modifier broadcast() {
        uint256 privKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(privKey);

        deployer = vm.addr(privKey);
        console2.log("General");
        console2.log("- Deploying from:   ", deployer);
        console2.log("- Chain ID:         ", block.chainid);
        console2.log("");

        _;

        vm.stopBroadcast();
    }

    function run() public broadcast {
        address existingDao = vm.envOr("EXISTING_DAO_ADDRESS", address(0));

        if (existingDao == address(0)) {
            _runCreateDaoAndInstall();
        } else {
            _runInstallOnExistingDao(existingDao);
        }

        printDeployment();

        if (!vm.envOr("SIMULATION", false)) {
            writeJsonArtifacts();
        }
    }

    function _runCreateDaoAndInstall() internal {
        DAOFactory daoFactory = DAOFactory(vm.envAddress("DAO_FACTORY_ADDRESS"));
        vm.label(address(daoFactory), "DaoFactory");

        (dao, plugin, token) = createDaoAndInstall(daoFactory, readDaoSettings(), readInstallParams());
    }

    function _runInstallOnExistingDao(address _existingDao) internal {
        dao = DAO(payable(_existingDao));
        (plugin, token) = installOnExistingDao(dao, readInstallParams());
    }

    function readDaoSettings() public view returns (DAOFactory.DAOSettings memory daoSettings) {
        daoSettings.trustedForwarder = address(0);
        daoSettings.daoURI = vm.envOr("DAO_URI", string(""));
        daoSettings.subdomain = vm.envOr("DAO_SUBDOMAIN", string(""));
        daoSettings.metadata = bytes(vm.envOr("DAO_METADATA_URI", string("")));
    }

    /// @notice Creates a new DAO via `DAOFactory` (with no plugins installed by the factory itself)
    ///     and directly deploys and wires up the `NFTVoting` plugin on it.
    function createDaoAndInstall(
        DAOFactory _daoFactory,
        DAOFactory.DAOSettings memory _daoSettings,
        InstallParams memory _params
    ) public returns (DAO dao_, NFTVoting plugin_, IVotesUpgradeable token_) {
        (dao_,) = _daoFactory.createDao(_daoSettings, new DAOFactory.PluginSettings[](0));
        (plugin_, token_) = installOnExistingDao(dao_, _params);
    }

    /// @notice Deploys and wires up the `NFTVoting` plugin on an already-deployed DAO.
    /// @dev The caller must already hold `EXECUTE_PERMISSION_ID` on `_dao`.
    function installOnExistingDao(DAO _dao, InstallParams memory _params)
        public
        returns (NFTVoting plugin_, IVotesUpgradeable token_)
    {
        bool mintedNewToken = _params.existingToken == address(0);
        token_ = _resolveToken(_dao, _params, mintedNewToken);
        plugin_ = _deployPlugin(_dao, _params, token_);

        Action[] memory actions = _buildPermissionActions(_dao, plugin_, token_, mintedNewToken);
        _dao.execute(bytes32(0), actions, 0);

        address installer = _resolveInstaller();
        require(
            !_dao.isGranted(address(_dao), installer, _dao.EXECUTE_PERMISSION_ID(), ""),
            "installer still has EXECUTE permission on DAO"
        );
    }

    function _resolveToken(DAO _dao, InstallParams memory _params, bool _mintedNewToken)
        internal
        returns (IVotesUpgradeable token_)
    {
        if (!_mintedNewToken) {
            return IVotesUpgradeable(_params.existingToken);
        }

        uint256 count = _params.nftCount == 0 ? 1 : _params.nftCount;
        address receiver = deployer == address(0) ? msg.sender : deployer;
        address[] memory receivers = new address[](count);

        for (uint256 i; i < count; ++i) {
            receivers[i] = receiver;
        }

        GovernanceERC721.TokenSettings memory settings = GovernanceERC721.TokenSettings({
            name: _params.tokenName, symbol: _params.tokenSymbol, baseURI: _params.baseTokenURI, receivers: receivers
        });
        token_ = new GovernanceERC721(IDAO(address(_dao)), settings);

        vm.label(address(token_), "Token");
    }

    /// @dev Deploys the plugin as a minimal proxy against a fresh implementation
    function _deployPlugin(DAO _dao, InstallParams memory _params, IVotesUpgradeable _token)
        internal
        returns (NFTVoting plugin_)
    {
        IPlugin.TargetConfig memory targetConfig = _params.targetConfig;
        require(
            targetConfig.operation == IPlugin.Operation.Call,
            "Only Call operation is enable for NFTVoting target configs"
        );

        if (targetConfig.target == address(0)) {
            targetConfig.target = address(_dao);
        }

        address nftVotingBase = address(new NFTVoting());
        ProxyFactory proxyFactory = new ProxyFactory(nftVotingBase);
        plugin_ = NFTVoting(
            proxyFactory.deployMinimalProxy(
                abi.encodeCall(
                    NFTVoting.initialize,
                    (IDAO(address(_dao)), _params.votingSettings, _token, targetConfig, _params.pluginMetadata)
                )
            )
        );
        vm.label(address(plugin_), "NFTVoting");
    }

    function _buildPermissionActions(DAO _dao, NFTVoting _plugin, IVotesUpgradeable _token, bool _mintedNewToken)
        internal
        view
        returns (Action[] memory actions)
    {
        uint256 baseLength = _mintedNewToken ? 10 : 6;
        actions = new Action[](baseLength + 1);

        actions[0] = _grantAction(_dao, address(_plugin), address(_dao), _plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        actions[1] = _grantAction(_dao, address(_dao), address(_plugin), _dao.EXECUTE_PERMISSION_ID());
        actions[2] = _grantAction(_dao, address(_plugin), ANY_ADDR, _plugin.CREATE_PROPOSAL_PERMISSION_ID());
        actions[3] = _grantAction(_dao, address(_plugin), address(_dao), _plugin.SET_TARGET_CONFIG_PERMISSION_ID());
        actions[4] = _grantAction(_dao, address(_plugin), address(_dao), _plugin.SET_METADATA_PERMISSION_ID());
        actions[5] = _grantAction(_dao, address(_plugin), ANY_ADDR, _plugin.EXECUTE_PROPOSAL_PERMISSION_ID());

        if (_mintedNewToken) {
            GovernanceERC721 nft = GovernanceERC721(address(_token));
            actions[6] = _grantAction(_dao, address(_token), address(_dao), nft.MINT_PERMISSION_ID());
            actions[7] = _grantAction(_dao, address(_token), address(_dao), nft.BURN_PERMISSION_ID());
            actions[8] = _grantAction(_dao, address(_token), address(_dao), nft.TRANSFER_PERMISSION_ID());
            actions[9] = _grantAction(_dao, address(_token), address(_dao), nft.UPDATE_BASE_URI_ID());
        }

        // Must be last: drop bootstrap authority used to run this installation batch.
        actions[baseLength] = _revokeAction(_dao, address(_dao), _resolveInstaller(), _dao.EXECUTE_PERMISSION_ID());
    }

    function _grantAction(DAO _dao, address _where, address _who, bytes32 _permissionId)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            to: address(_dao), value: 0, data: abi.encodeCall(PermissionManager.grant, (_where, _who, _permissionId))
        });
    }

    function _revokeAction(DAO _dao, address _where, address _who, bytes32 _permissionId)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            to: address(_dao), value: 0, data: abi.encodeCall(PermissionManager.revoke, (_where, _who, _permissionId))
        });
    }

    function _resolveInstaller() internal view returns (address) {
        // In forge broadcast mode, `deployer` is the EOA from DEPLOYER_KEY.
        // In Solidity tests, DAOFactory grants bootstrap EXECUTE to this script contract.
        return deployer == address(0) ? address(this) : deployer;
    }

    function readInstallParams() public view returns (InstallParams memory params) {
        _readTokenSettings(params);
        _readMiscSettings(params);
        _readVotingSettings(params);
    }

    function _readTokenSettings(InstallParams memory params) internal view {
        params.existingToken = vm.envOr("TOKEN_ADDRESS", address(0));
        params.tokenName = vm.envOr("TOKEN_NAME", string("Governance NFT"));
        params.tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("GOVNFT"));
        params.baseTokenURI = vm.envOr("BASE_TOKEN_URI", string(""));
        params.nftCount = vm.envOr("NFT_COUNT", uint256(1));
    }

    function _readMiscSettings(InstallParams memory params) internal view {
        params.targetConfig = IPlugin.TargetConfig({
            target: vm.envOr("TARGET_ADDRESS", address(0)),
            operation: IPlugin.Operation(vm.envOr("TARGET_OPERATION", uint256(0)))
        });
        params.pluginMetadata = bytes(vm.envOr("PLUGIN_METADATA_URI", string("")));
    }

    function _readVotingSettings(InstallParams memory params) internal view {
        params.votingSettings.votingMode = INFTVoting.VotingMode(vm.envOr("VOTING_MODE", uint256(0)));
        params.votingSettings.supportThreshold = uint32(vm.envOr("SUPPORT_THRESHOLD", uint256(500_000)));
        params.votingSettings.minParticipation = uint32(vm.envOr("MIN_PARTICIPATION", uint256(100_000)));
        params.votingSettings.minDuration = uint64(vm.envOr("MIN_DURATION", uint256(1 hours)));
        params.votingSettings.maxBoundDate = uint64(vm.envOr("MAX_BOUND_DATE", uint256(365 days)));
        params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(0));
        params.votingSettings.minApprovals = vm.envOr("MIN_APPROVALS", uint256(1));
    }

    function printDeployment() public view {
        console2.log("NFTVoting plugin installed:");
        console2.log("- DAO:                       ", address(dao));
        console2.log("- NFTVoting plugin:          ", address(plugin));
        console2.log("- Token:                     ", address(token));
        console2.log("");
    }

    function writeJsonArtifacts() internal {
        string memory artifacts = "output";
        artifacts.serialize("dao", address(dao));
        artifacts.serialize("plugin", address(plugin));
        artifacts = artifacts.serialize("token", address(token));

        string memory networkName = vm.envOr("NETWORK_NAME", string("unknown"));
        string memory filePath = string.concat(
            vm.projectRoot(), "/artifacts/install-nft-", networkName, "-", vm.toString(block.timestamp), ".json"
        );
        artifacts.write(filePath);

        console2.log("Deployment artifacts written to", filePath);
    }
}
