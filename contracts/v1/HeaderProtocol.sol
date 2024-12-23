// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHeaderProtocol, IHeader} from "./interfaces/IHeaderProtocol.sol";
import {RLPReader} from "./utils/RLPReader.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {ExcessivelySafeCall} from "./utils/ExcessivelySafeCall.sol";

/// @title HeaderProtocol
/// @notice A protocol to request Ethereum block headers onchain, enabling tasks such as
///         obtaining `baseFeePerGas`, `mixHash` for randomness, or other header fields.
/// @dev    If tasks are paid, executors can claim rewards by providing the correct header data.
///         If tasks are free, they only emit events for off-chain executors to fulfill.
/// @author aaurelions
contract HeaderProtocol is IHeaderProtocol, ReentrancyGuard {
    using ExcessivelySafeCall for address;
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for RLPReader.Iterator;
    using RLPReader for bytes;

    constructor() {}

    //--------------------------------------------------------------------------
    // State
    //--------------------------------------------------------------------------

    bytes4 private constant MARKER = bytes4("TASK");
    uint256 private constant MAX_REWARD = 18 ether;
    uint256 private constant MAX_INDEX = 20;
    uint256 private constant MAX_GAS_LIMIT = 30_000;
    bytes32 private constant B0 = bytes32(0);
    address private constant A0 = address(0);

    /// @notice Maps blockNumber => headerIndex => encoded task info is then upd to headerData
    mapping(uint256 => mapping(uint256 => bytes32)) private headers;

    /// @notice Maps blockNumber => blockHash if committed or known
    mapping(uint256 => bytes32) private hashes;

    //--------------------------------------------------------------------------
    // Modifiers
    //--------------------------------------------------------------------------

    modifier onlyContract(address account) {
        if (!_isContract(account)) revert OnlyContracts();
        _;
    }

    //--------------------------------------------------------------------------
    // External Functions
    //--------------------------------------------------------------------------

    /// @inheritdoc IHeaderProtocol
    function getHash(uint256 blockNumber) external view returns (bytes32) {
        return hashes[blockNumber];
    }

    /// @inheritdoc IHeaderProtocol
    function getHeader(
        uint256 blockNumber,
        uint256 headerIndex
    ) external view returns (bytes32) {
        return _getHeader(blockNumber, headerIndex);
    }

    /// @inheritdoc IHeaderProtocol
    function request(
        uint256 blockNumber,
        uint256 headerIndex
    ) external payable onlyContract(msg.sender) {
        _request(blockNumber, headerIndex);
    }

    /// @inheritdoc IHeaderProtocol
    function response(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes calldata blockHeader,
        address contractAddress
    ) external nonReentrant {
        _response(blockNumber, headerIndex, blockHeader, contractAddress);
    }

    /// @inheritdoc IHeaderProtocol
    function commit(uint256 blockNumber) external {
        _commit(blockNumber);
    }

    /// @inheritdoc IHeaderProtocol
    function refund(
        uint256 blockNumber,
        uint256 headerIndex
    ) external nonReentrant {
        _refund(blockNumber, headerIndex);
    }

    //--------------------------------------------------------------------------
    // Internal Functions
    //--------------------------------------------------------------------------

    function _getHeader(
        uint256 blockNumber,
        uint256 headerIndex
    ) internal view returns (bytes32) {
        bytes32 storedHeader = headers[blockNumber][headerIndex];
        return _isHeader(storedHeader) ? storedHeader : B0;
    }

    function _request(uint256 blockNumber, uint256 headerIndex) internal {
        if (blockNumber < block.number) revert InvalidBlockNumber();
        if (headerIndex % MAX_INDEX == 6 || headerIndex % MAX_INDEX == 12) {
            revert InvalidHeaderIndex();
        }
        if (msg.value >= MAX_REWARD) revert RewardExceedTheLimit();

        bytes32 storedHeader = _getHeader(blockNumber, headerIndex);

        if (storedHeader != B0) {
            // Refund because the task has already been completed.
            if (msg.value > 0) _send(msg.sender, msg.value);
            _call(blockNumber, headerIndex, msg.sender, storedHeader);
            return;
        }

        uint256 currentIndex = headerIndex;

        while (true) {
            storedHeader = headers[blockNumber][currentIndex];
            if (storedHeader == B0) {
                break;
            }
            currentIndex += MAX_INDEX;
        }

        if (msg.value > 0) {
            headers[blockNumber][currentIndex] = _encodeTask(
                msg.sender,
                msg.value
            );
        }

        emit BlockHeaderRequested(
            msg.sender,
            blockNumber,
            currentIndex,
            msg.value
        );
    }

    function _response(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes memory blockHeader,
        address contractAddress
    ) internal {
        bytes32 storedHeader = headers[blockNumber][headerIndex];

        if (_isHeader(storedHeader)) {
            _call(blockNumber, headerIndex, contractAddress, storedHeader);
            emit BlockHeaderResponded(
                contractAddress,
                blockNumber,
                headerIndex,
                msg.sender
            );
            return;
        }

        bytes32 _bh = hashes[blockNumber] != B0
            ? hashes[blockNumber]
            : blockhash(blockNumber);

        if (_bh == B0) revert FailedToObtainBlockHash();
        if (blockHeader.length == 0) revert BlockHeaderIsEmpty();

        RLPReader.RLPItem memory item = blockHeader.toRlpItem();
        if (_bh != item.rlpBytesKeccak256()) revert HeaderHashMismatch();
        RLPReader.Iterator memory iterator = item.iterator();

        for (uint256 i = 0; i < (headerIndex % MAX_INDEX); i++) {
            // slither-disable-next-line unused-return
            iterator.next();
        }

        bytes memory result = iterator.next().toBytes();
        if (result.length == 0) revert HeaderDataIsEmpty();

        bytes32 computedHeader;
        assembly {
            computedHeader := mload(add(result, 32))
        }

        (address _contractAddress, uint256 _rewardAmount) = _decodeTask(
            storedHeader
        );

        if (_rewardAmount > 0) {
            /// Preventing potential vulnerability if the blockchain generates `mixHash`, `transactionsRoot`
            /// and other header information for computedHeader that:
            /// - Has the structure: `bytes4("HEAD") + bytes8(rewardAmount) + bytes20(contractAddress)`;
            /// - The reward `rewardAmount` must be greater than 0;
            /// - The address `contractAddress` must be a smart contract.
            headers[blockNumber][headerIndex] = _isHeader(computedHeader)
                ? computedHeader
                : B0;
            _send(msg.sender, _rewardAmount);
            _call(blockNumber, headerIndex, _contractAddress, computedHeader); // send paid task
        } else {
            _call(blockNumber, headerIndex, contractAddress, computedHeader); // send free task
        }

        emit BlockHeaderResponded(
            _rewardAmount > 0 ? _contractAddress : contractAddress,
            blockNumber,
            headerIndex,
            msg.sender
        );
    }

    function _commit(uint256 blockNumber) internal {
        bytes32 bh = blockhash(blockNumber);

        if (hashes[blockNumber] == B0 && bh != B0) {
            hashes[blockNumber] = bh;
        }

        emit BlockHeaderCommitted(blockNumber);
    }

    function _refund(uint256 blockNumber, uint256 headerIndex) internal {
        (address contractAddress, uint256 rewardAmount) = _decodeTask(
            headers[blockNumber][headerIndex]
        );

        bytes32 bh = (hashes[blockNumber] != B0)
            ? hashes[blockNumber]
            : blockhash(blockNumber);

        // Refund conditions:
        // - Task is paid (rewardAmount > 0);
        // - Task have request smart contract;
        // - The requested blockNumber is already in the past
        //   (blockNumber < current block), to avoid hardcoding 256 blocks;
        // - No blockhash available (bh == 0) meaning we cannot complete it anymore
        //   due to blockhash retention limit passed (more than 256 blocks later).
        if (
            rewardAmount > 0 &&
            contractAddress != A0 &&
            blockNumber < block.number &&
            bh == B0
        ) {
            headers[blockNumber][headerIndex] = B0;
            _send(contractAddress, rewardAmount);
        } else {
            revert TaskIsNonRefundable();
        }

        emit BlockHeaderRefunded(blockNumber, headerIndex);
    }

    function _encodeTask(
        address contractAddress,
        uint256 rewardAmount
    ) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(uint256(uint32(MARKER)) << 224) |
                    (uint256(rewardAmount) << 160) |
                    uint256(uint160(contractAddress))
            );
    }

    function _decodeTask(
        bytes32 headerData
    ) internal view returns (address, uint256) {
        if (headerData == B0) return (A0, 0);

        uint256 value = uint256(headerData);
        bytes4 _marker = bytes4(uint32(value >> 224));
        uint256 _rewardAmount = uint256(uint64(value >> 160));
        address _contractAddress = address(uint160(value));

        uint256 rewardAmount = 0;
        address contractAddress = A0;

        if (
            _marker == MARKER &&
            _isContract(_contractAddress) &&
            _rewardAmount > 0
        ) {
            contractAddress = _contractAddress;
            rewardAmount = _rewardAmount;
        }

        return (contractAddress, rewardAmount);
    }

    function _call(
        uint256 blockNumber,
        uint256 headerIndex,
        address contractAddress,
        bytes32 headerData
    ) internal {
        // slither-disable-next-line unused-return
        (bool success, ) = contractAddress.excessivelySafeCall(
            MAX_GAS_LIMIT,
            0,
            0,
            abi.encodeWithSelector(
                IHeader(contractAddress).responseBlockHeader.selector,
                blockNumber,
                headerIndex,
                headerData
            )
        );
        if (!success) revert ExternalCallFailed();
    }

    function _send(address to, uint256 value) internal {
        // slither-disable-next-line arbitrary-send-eth low-level-calls
        (bool sent, ) = payable(to).call{value: value}("");
        if (!sent) revert FailedToSendEther();
    }

    /// @dev Checks if `account` is a contract by using `extcodesize`.
    ///      Note: This is not a perfect check. Contracts can self-destruct.
    function _isContract(address account) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function _isHeader(bytes32 headerData) internal view returns (bool) {
        (address contractAddress, uint256 rewardAmount) = _decodeTask(
            headerData
        );
        return headerData != B0 && contractAddress == A0 && rewardAmount == 0;
    }

    //--------------------------------------------------------------------------
    // Ether Handling
    //--------------------------------------------------------------------------

    receive() external payable {
        revert DirectPaymentsNotSupported();
    }

    fallback() external payable {
        revert FunctionDoesNotExist();
    }
}
