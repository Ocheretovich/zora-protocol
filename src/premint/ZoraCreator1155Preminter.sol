// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ICreatorRoyaltiesControl} from "../interfaces/ICreatorRoyaltiesControl.sol";
import {EIP712UpgradeableWithChainId} from "./EIP712UpgradeableWithChainId.sol";
import {ECDSAUpgradeable} from "@zoralabs/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import {IZoraCreator1155} from "../interfaces/IZoraCreator1155.sol";
import {IZoraCreator1155Factory} from "../interfaces/IZoraCreator1155Factory.sol";
import {ZoraCreator1155Impl} from "../nft/ZoraCreator1155Impl.sol";
import {ZoraCreator1155StorageV1} from "../nft/ZoraCreator1155StorageV1.sol";
import {SharedBaseConstants} from "../shared/SharedBaseConstants.sol";
import {ZoraCreatorFixedPriceSaleStrategy} from "../minters/fixed-price/ZoraCreatorFixedPriceSaleStrategy.sol";
import {IMinter1155} from "../interfaces/IMinter1155.sol";

/// @title Enables a creator to signal intent to create a Zora erc1155 contract or new token on that
/// contract by signing a transaction but not paying gas, and have a third party/collector pay the gas
/// by executing the transaction.  Incentivizes the third party to execute the transaction by offering
/// a reward in the form of minted tokens.
/// @author @oveddan
/// @notice
contract ZoraCreator1155Preminter is EIP712UpgradeableWithChainId {
    IZoraCreator1155Factory factory;
    IMinter1155 fixedPriceMinter;

    /// @notice copied from SharedBaseConstants
    uint256 constant CONTRACT_BASE_ID = 0;
    /// @notice This user role allows for any action to be performed
    /// @dev copied from ZoraCreator1155Impl
    uint256 constant PERMISSION_BIT_ADMIN = 2 ** 1;
    /// @notice This user role allows for only mint actions to be performed.
    /// @dev copied from ZoraCreator1155Impl
    uint256 constant PERMISSION_BIT_MINTER = 2 ** 2;

    /// @notice Contract creation parameters unique hash => created contract address
    mapping(uint256 => address) public contractAddresses;
    /// @dev hash of contract creation config + token uid -> if token has been created
    mapping(uint256 => bool) tokenCreated;

    error TokenAlreadyCreated(address creatorAddress, string contractURI, string contractName, uint256 tokenUid);

    function initialize(IZoraCreator1155Factory _factory, IMinter1155 _fixedPriceMinter) public initializer {
        __EIP712_init("Preminter", "0.0.1");
        factory = _factory;
        fixedPriceMinter = _fixedPriceMinter;
    }

    struct ContractCreationConfig {
        /// @notice Creator/admin of the created contract.  Must match the account that signed the message
        address contractAdmin;
        /// @notice Metadata URI for the created contract
        string contractURI;
        /// @notice Name of the created contract
        string contractName;
    }

    struct TokenCreationConfig {
        /// @notice Metadata URI for the created token
        string tokenURI;
        /// @notice Max supply of the created token
        uint256 maxSupply;
        /// @notice Max tokens that can be minted for an address, 0 if unlimited
        uint64 maxTokensPerAddress;
        /// @notice Price per token in eth wei. 0 for a free mint.
        uint96 pricePerToken;
        /// @notice The duration of the sale, starting from the first mint of this token. 0 for infinite
        uint64 saleDuration;
        /// @notice RoyaltyMintSchedule for created tokens. Every nth token will go to the royalty recipient.
        uint32 royaltyMintSchedule;
        /// @notice RoyaltyBPS for created tokens. The royalty amount in basis points for secondary sales.
        uint32 royaltyBPS;
        /// @notice RoyaltyRecipient for created tokens. The address that will receive the royalty payments.
        address royaltyRecipient;
        /// @notice Unique id of the token, used to ensure that multiple signatures can't be used to create the same intended token, in the case
        /// that a signature is updated for a token, and the old signature is executed, two tokens for the same original intended token could be created.
        /// Only one signature per token id, scoped to the contract hash can be executed.
        uint256 uid;
    }

    event Preminted(
        address indexed contractAddress,
        uint256 indexed tokenId,
        bool indexed createdNewContract,
        uint256 contractHashId,
        uint256 uid,
        ContractCreationConfig contractConfig,
        TokenCreationConfig tokenConfig,
        address minter,
        uint256 quantiyMinted
    );

    // same signature should work whether or not there is an existing contract
    // so it is unaware of order, it just takes the token uri and creates the next token with it
    // this could include creating the contract.
    // do we need a deadline? open q
    function premint(
        ContractCreationConfig calldata contractConfig,
        TokenCreationConfig calldata tokenConfig,
        bytes calldata signature,
        uint256 quantityToMint,
        string calldata mintComment
    ) public payable returns (address contractAddress, uint256 newTokenId) {
        // 1. Validate the signature, and mark it as used.
        // 2. Create an erc1155 contract with the given name and uri and the creator as the admin/owner
        // 3. Allow this contract to create new new tokens on the contract
        // 4. Mint a new token, and get the new token id
        // 5. Setup fixed price minting rules for the new token
        // 6. Make the creator an admin of that token (and remove this contracts admin rights)
        // 7. Mint x tokens, as configured, to the executor of this transaction.

        // get or create the contract with the given params
        (IZoraCreator1155 tokenContract, uint256 contractHash, bool isNewContract) = _getOrCreateContract(contractConfig);
        contractAddress = address(tokenContract);

        // validate the signature for the current chain id, and make sure it hasn't been used, marking
        // that it has been used
        _validateSignatureAndEnsureNotUsed(contractConfig, tokenConfig, signature);

        // setup the new token, and its sales config
        newTokenId = _setupNewTokenAndSale(tokenContract, contractConfig.contractAdmin, tokenConfig);

        emit Preminted(contractAddress, newTokenId, isNewContract, contractHash, tokenConfig.uid, contractConfig, tokenConfig, msg.sender, quantityToMint);

        // mint the initial x tokens for this new token id to the executor.
        address tokenRecipient = msg.sender;
        tokenContract.mint{value: msg.value}(fixedPriceMinter, newTokenId, quantityToMint, abi.encode(tokenRecipient, mintComment));
    }

    function _getOrCreateContract(
        ContractCreationConfig calldata contractConfig
    ) private returns (IZoraCreator1155 tokenContract, uint256 contractHash, bool isNewContract) {
        contractHash = contractDataHash(contractConfig);
        address contractAddress = contractAddresses[contractHash];
        // first we see if the address exists for the contract
        isNewContract = contractAddress == address(0);
        if (isNewContract) {
            // if address doesnt exist for hash, createi t
            tokenContract = _createContract(contractConfig);
            contractAddresses[contractHash] = address(tokenContract);
        } else {
            tokenContract = IZoraCreator1155(contractAddress);
        }
    }

    function _createContract(ContractCreationConfig calldata contractConfig) private returns (IZoraCreator1155 tokenContract) {
        // we need to build the setup actions, that must:
        // grant this contract ability to mint tokens - when a token is minted, this contract is
        // granted admin rights on that token
        bytes[] memory setupActions = new bytes[](1);
        setupActions[0] = abi.encodeWithSelector(IZoraCreator1155.addPermission.selector, CONTRACT_BASE_ID, address(this), PERMISSION_BIT_MINTER);

        // create the contract via the factory.
        address newContractAddresss = factory.createContract(
            contractConfig.contractURI,
            contractConfig.contractName,
            // default royalty config is empty, since we set it on a token level
            ICreatorRoyaltiesControl.RoyaltyConfiguration({royaltyBPS: 0, royaltyRecipient: address(0), royaltyMintSchedule: 0}),
            payable(contractConfig.contractAdmin),
            setupActions
        );
        tokenContract = IZoraCreator1155(newContractAddresss);
    }

    function _setupNewTokenAndSale(
        IZoraCreator1155 tokenContract,
        address contractAdmin,
        TokenCreationConfig calldata tokenConfig
    ) private returns (uint256 newTokenId) {
        // mint a new token, and get its token id
        // this contract has admin rights on that token

        newTokenId = tokenContract.setupNewToken(tokenConfig.tokenURI, tokenConfig.maxSupply);

        // now setup multicalls - to avoid cross contract calls
        // set up the sales strategy
        // first, grant the fixed price sale strategy minting capabilities on the token

        bytes[] memory setupTokenActions = new bytes[](5);

        // tokenContract.addPermission(newTokenId, address(fixedPriceMinter), PERMISSION_BIT_MINTER);
        // abi encoded version of above is:
        setupTokenActions[0] = abi.encodeWithSelector(IZoraCreator1155.addPermission.selector, newTokenId, address(fixedPriceMinter), PERMISSION_BIT_MINTER);

        // set the sales config on that token
        // normally called with:
        // tokenContract.callSale(
        //     newTokenId,
        //     fixedPriceMinter,
        //     abi.encodeWithSelector(
        //         ZoraCreatorFixedPriceSaleStrategy.setSale.selector,
        //         newTokenId,
        //         _buildNewSalesConfig(contractAdmin, tokenConfig.pricePerToken, tokenConfig.maxTokensPerAddress, tokenConfig.saleDuration)
        //     )
        // );
        setupTokenActions[1] = abi.encodeWithSelector(
            IZoraCreator1155.callSale.selector,
            newTokenId,
            fixedPriceMinter,
            abi.encodeWithSelector(
                ZoraCreatorFixedPriceSaleStrategy.setSale.selector,
                newTokenId,
                _buildNewSalesConfig(contractAdmin, tokenConfig.pricePerToken, tokenConfig.maxTokensPerAddress, tokenConfig.saleDuration)
            )
        );

        // set the royalty config on that token:
        // tokenContract.updateRoyaltiesForToken(
        //     newTokenId,
        //     ICreatorRoyaltiesControl.RoyaltyConfiguration({
        //         royaltyBPS: tokenConfig.royaltyBPS,
        //         royaltyRecipient: tokenConfig.royaltyRecipient,
        //         royaltyMintSchedule: tokenConfig.royaltyMintSchedule
        //     })
        // );
        setupTokenActions[2] = abi.encodeWithSelector(
            IZoraCreator1155.updateRoyaltiesForToken.selector,
            newTokenId,
            ICreatorRoyaltiesControl.RoyaltyConfiguration({
                royaltyBPS: tokenConfig.royaltyBPS,
                royaltyRecipient: tokenConfig.royaltyRecipient,
                royaltyMintSchedule: tokenConfig.royaltyMintSchedule
            })
        );

        // this contract is the admin of that token, and the creator isn't, so
        // make the creator the admin of that token, and remove this contracts admin rights on that token.

        // set the owner as admin:
        // tokenContract.addPermission(newTokenId, tokenContract.owner(), PERMISSION_BIT_ADMIN);
        setupTokenActions[3] = abi.encodeWithSelector(IZoraCreator1155.addPermission.selector, newTokenId, tokenContract.owner(), PERMISSION_BIT_ADMIN);

        // remove this contract as admin:
        // tokenContract.removePermission(newTokenId, address(this), PERMISSION_BIT_ADMIN);
        setupTokenActions[4] = abi.encodeWithSelector(IZoraCreator1155.removePermission.selector, newTokenId, address(this), PERMISSION_BIT_ADMIN);

        // now multicall using these
        ZoraCreator1155Impl(address(tokenContract)).multicall(setupTokenActions);
    }

    function recoverSigner(
        ContractCreationConfig calldata contractConfig,
        TokenCreationConfig calldata tokenConfig,
        bytes calldata signature
    ) public view returns (address signatory) {
        // first validate the signature - the creator must match the signer of the message
        bytes32 digest = premintHashData(
            contractConfig,
            tokenConfig,
            // here we pass the current chain id, ensuring that the message
            // only works for the current chain id
            block.chainid
        );

        signatory = ECDSAUpgradeable.recover(digest, signature);
    }

    function premintHashData(
        ContractCreationConfig calldata contractConfig,
        TokenCreationConfig calldata tokenConfig,
        uint256 chainId
    ) public view returns (bytes32) {
        bytes32 encoded = _hashContractAndToken(contractConfig, tokenConfig);

        // build the struct hash to be signed
        // here we pass the chain id, allowing the message to be signed for another chain
        return _hashTypedDataV4(encoded, chainId);
    }

    bytes32 constant CONTRACT_AND_TOKEN_DOMAIN =
        keccak256(
            "ContractAndToken(ContractCreationConfig contractConfig,TokenCreationConfig tokenConfig)ContractCreationConfig(address contractAdmin,string contractURI,string contractName)TokenCreationConfig(string tokenURI,uint256 maxSupply,uint64 maxTokensPerAddress,uint96 pricePerToken,uint64 saleDuration,uint32 royaltyMintSchedule,uint32 royaltyBPS,address royaltyRecipient,uint256 uid)"
        );

    function _hashContractAndToken(ContractCreationConfig calldata contractConfig, TokenCreationConfig calldata tokenConfig) private pure returns (bytes32) {
        return keccak256(abi.encode(CONTRACT_AND_TOKEN_DOMAIN, _hashContract(contractConfig), _hashToken(tokenConfig)));
    }

    bytes32 constant TOKEN_DOMAIN =
        keccak256(
            "TokenCreationConfig(string tokenURI,uint256 maxSupply,uint64 maxTokensPerAddress,uint96 pricePerToken,uint64 saleDuration,uint32 royaltyMintSchedule,uint32 royaltyBPS,address royaltyRecipient,uint256 uid)"
        );

    function _hashToken(TokenCreationConfig calldata tokenConfig) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    TOKEN_DOMAIN,
                    stringHash(tokenConfig.tokenURI),
                    tokenConfig.maxSupply,
                    tokenConfig.maxTokensPerAddress,
                    tokenConfig.pricePerToken,
                    tokenConfig.saleDuration,
                    tokenConfig.royaltyMintSchedule,
                    tokenConfig.royaltyBPS,
                    tokenConfig.royaltyRecipient,
                    tokenConfig.uid
                )
            );
    }

    bytes32 constant CONTRACT_DOMAIN = keccak256("ContractCreationConfig(address contractAdmin,string contractURI,string contractName)");

    function _hashContract(ContractCreationConfig calldata contractConfig) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(CONTRACT_DOMAIN, contractConfig.contractAdmin, stringHash(contractConfig.contractURI), stringHash(contractConfig.contractName))
            );
    }

    function tokenHasBeenCreated(ContractCreationConfig calldata contractConfig, uint256 tokenUid) public view returns (bool) {
        return tokenCreated[contractAndTokenHash(contractConfig, tokenUid)];
    }

    function contractAndTokenHash(ContractCreationConfig calldata contractConfig, uint256 tokenUid) public pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encode(contractConfig.contractAdmin, stringHash(contractConfig.contractURI), stringHash(contractConfig.contractName), tokenUid))
            );
    }

    function _validateSignatureAndEnsureNotUsed(
        ContractCreationConfig calldata contractConfig,
        TokenCreationConfig calldata tokenConfig,
        bytes calldata signature
    ) private returns (uint256 tokenHash) {
        // first validate the signature - the creator must match the signer of the message
        address signatory = recoverSigner(contractConfig, tokenConfig, signature);

        if (signatory != contractConfig.contractAdmin) {
            revert("Invalid signature");
        }

        // make sure that this signature hasn't been used
        // token hash includes the contract hash, so we can check uniqueness of contract + token pair
        tokenHash = contractAndTokenHash(contractConfig, tokenConfig.uid);
        if (tokenCreated[tokenHash]) {
            revert TokenAlreadyCreated(contractConfig.contractAdmin, contractConfig.contractURI, contractConfig.contractName, tokenConfig.uid);
        }
        tokenCreated[tokenHash] = true;

        return tokenHash;
    }

    /// Returns a unique hash for the contract data, useful to uniquely identify a contract based on creation params
    /// and determining what contract address has been created for this hash.  Also used to scope
    /// unique unique ids associated with signatures, the uid field on TokenCreationConfig
    function contractDataHash(ContractCreationConfig calldata contractConfig) public pure returns (uint256) {
        return uint256(_hashContract(contractConfig));
    }

    function stringHash(string calldata value) private pure returns (bytes32) {
        return keccak256(bytes(value));
    }

    function _buildNewSalesConfig(
        address creator,
        uint96 pricePerToken,
        uint64 maxTokensPerAddress,
        uint64 duration
    ) private view returns (ZoraCreatorFixedPriceSaleStrategy.SalesConfig memory) {
        uint64 saleStart = uint64(block.timestamp);
        uint64 saleEnd = duration == 0 ? type(uint64).max : saleStart + duration;

        return
            ZoraCreatorFixedPriceSaleStrategy.SalesConfig({
                pricePerToken: pricePerToken,
                saleStart: saleStart,
                saleEnd: saleEnd,
                maxTokensPerAddress: maxTokensPerAddress,
                fundsRecipient: creator
            });
    }
}
