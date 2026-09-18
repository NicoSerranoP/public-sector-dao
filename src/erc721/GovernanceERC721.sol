// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/* solhint-disable max-line-length */
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {
    IERC721MetadataUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721VotesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC6372Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";

import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

/* solhint-enable max-line-length */

/// @title GovernanceERC721
/// @author NicoSerranoP (fork of Aragon X)
/// @notice An [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes)
///     compatible [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token, used for voting and managed by a DAO.
///     Each token counts as exactly one unit of voting power. Tokens can be transferred by their holder
///     (`transferFrom` / `safeTransferFrom`) or force-transferred by whoever holds the
///     `TRANSFER_PERMISSION_ID` permission (typically the managing DAO).
/// @dev Voting power is only counted once a token has been delegated. To keep every minted token effective
///     without extra user action, the contract self-delegates any receiver that has no delegate yet
///     (on mint and on transfer). Holders can override this at any time by calling `delegate`.
/// @custom:security-contact sirt@aragon.org
contract GovernanceERC721 is Initializable, ERC165Upgradeable, ERC721VotesUpgradeable, DaoAuthorizableUpgradeable {
    /// @notice The permission identifier to mint new tokens.
    bytes32 public constant MINT_PERMISSION_ID = keccak256("MINT_PERMISSION");

    /// @notice The permission identifier to burn existing tokens.
    bytes32 public constant BURN_PERMISSION_ID = keccak256("BURN_PERMISSION");

    /// @notice The permission identifier to force-transfer a token regardless of holder approval.
    bytes32 public constant TRANSFER_PERMISSION_ID = keccak256("TRANSFER_PERMISSION");

    /// @notice The permission identifier to update the base URI for token metadata.
    bytes32 public constant UPDATE_BASE_URI_ID = keccak256("UPDATE_BASE_URI");

    /// @notice The identifier that will be assigned to the next minted token. First token id is 1.
    uint256 private nextTokenId;

    /// @notice The single URI where the metadata for each token is stored. Can be updated
    string private baseTokenURI;

    /// @notice The initialization settings of the token.
    /// @param name The token name.
    /// @param symbol The token symbol.
    /// @param baseURI The URI holding the metadata of the token.
    /// @param receivers of the tokens on initialization. List address `n` times to grant it `n` tokens/votes.
    struct TokenSettings {
        string name;
        string symbol;
        string baseURI;
        address[] receivers;
    }

    /// @notice Emitted when a token is force-transferred through `adminTransfer`.
    /// @param from The previous holder of the token.
    /// @param to The new holder of the token.
    /// @param tokenId The identifier of the transferred token.
    event AdminTransfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @notice Calls the initialize function.
    /// @dev This contract is meant to be deployed with `new` only, never used as a minimal-proxy /
    ///     ERC-1967 implementation. `_disableInitializers()` locks this specific deployment's storage
    ///     against any further `initialize` call once the constructor's own call has run.
    /// @param _dao The managing DAO.
    /// @param _settings Token settings for initialization
    constructor(IDAO _dao, TokenSettings memory _settings) {
        initialize(_dao, _settings);
        _disableInitializers();
    }

    /// @notice Initializes the contract and mints one token per entry in `_settings.receivers`.
    /// @param _dao The managing DAO.
    /// @param _settings Token settings for initialization
    function initialize(IDAO _dao, TokenSettings memory _settings) public initializer {
        __ERC721_init(_settings.name, _settings.symbol);
        // `ERC721Votes` relies on `EIP712` for `delegateBySig`, so it must be initialized explicitly.
        __EIP712_init(_settings.name, "1");
        __DaoAuthorizableUpgradeable_init(_dao);

        baseTokenURI = _settings.baseURI;

        for (uint256 i; i < _settings.receivers.length;) {
            _mintTo(_settings.receivers[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(ERC165Upgradeable, ERC721Upgradeable)
        returns (bool)
    {
        return _interfaceId == type(IERC721Upgradeable).interfaceId
            || _interfaceId == type(IERC721MetadataUpgradeable).interfaceId
            || _interfaceId == type(IVotesUpgradeable).interfaceId
            || _interfaceId == type(IERC6372Upgradeable).interfaceId || super.supportsInterface(_interfaceId);
    }

    /// @notice Mints a single [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token for a receiving address.
    /// @param _to The receiving address.
    /// @dev Requires the `MINT_PERMISSION_ID` permission.
    function mint(address _to) external virtual auth(MINT_PERMISSION_ID) returns (uint256 tokenId) {
        return _mintTo(_to);
    }

    /// @notice Burns an existing token, permanently removing its voting power.
    /// @dev Requires the `BURN_PERMISSION_ID` permission.
    /// @param _tokenId The identifier of the token to burn.
    function burn(uint256 _tokenId) external virtual auth(BURN_PERMISSION_ID) {
        _burn(_tokenId);
    }

    /// @notice Force-transfers a token from its current holder to `_to`, bypassing holder approval.
    /// @dev Requires the `TRANSFER_PERMISSION_ID` permission. Holders transfer their own tokens with the
    ///     standard `transferFrom` / `safeTransferFrom` functions instead.
    /// @param _from The current holder of the token.
    /// @param _to The address receiving the token.
    /// @param _tokenId The identifier of the token to transfer.
    function adminTransfer(address _from, address _to, uint256 _tokenId) external virtual auth(TRANSFER_PERMISSION_ID) {
        _transfer(_from, _to, _tokenId);
        emit AdminTransfer({from: _from, to: _to, tokenId: _tokenId});
    }

    /// @notice Mints the next sequential token id to `_to`.
    /// @param _to The address receiving the token.
    /// @return tokenId The identifier of the freshly minted token.
    function _mintTo(address _to) internal virtual returns (uint256 tokenId) {
        unchecked {
            tokenId = ++nextTokenId;
        }
        _mint(_to, tokenId);
    }

    /// @inheritdoc ERC721VotesUpgradeable
    /// @dev Moves the voting units and, if the receiver has no delegate yet, self-delegates so the token
    ///     immediately counts. See https://forum.openzeppelin.com/t/self-delegation-in-erc20votes/17501/12
    function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
        internal
        virtual
        override(ERC721VotesUpgradeable)
    {
        super._afterTokenTransfer(from, to, firstTokenId, batchSize);

        // Automatically turn on delegation on mint/transfer if not delegating to anyone yet.
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /// @notice Returns the base URI for the token metadata.
    /// @return Returns the single base URI
    // forge-lint: disable-next-line(mixed-case-function)
    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }

    /// @notice Public getter of base URI for the token metadata.
    /// @return Returns the single base URI
    function baseURI() external view returns (string memory) {
        return _baseURI();
    }

    /// @notice Updates the base URI for the token metadata.
    /// @param _baseTokenURI The new base URI to set.
    function setBaseURI(
        // forge-lint: disable-next-line(mixed-case-variable)
        string memory _baseTokenURI
    )
        external
        virtual
        auth(UPDATE_BASE_URI_ID)
    {
        baseTokenURI = _baseTokenURI;
    }
}
