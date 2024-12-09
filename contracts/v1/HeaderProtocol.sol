// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHeaderProtocol, IHeader} from "@headerprotocol/contracts/v1/interfaces/IHeaderProtocol.sol";
import {RLPReader} from "@headerprotocol/contracts/v1/utils/RLPReader.sol";
import {ReentrancyGuard} from "@headerprotocol/contracts/v1/utils/ReentrancyGuard.sol";
import {ExcessivelySafeCall} from "@headerprotocol/contracts/v1/utils/ExcessivelySafeCall.sol";

/// @title HeaderProtocol
/// @notice A protocol to request Ethereum block headers onchain, enabling tasks such as
///         obtaining `baseFeePerGas`, `mixHash` for randomness, or other header fields.
/// @dev    If tasks are paid, executors can claim fees by providing the correct header data.
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

    uint256 private _taskIndex;

    /// @notice Maps blockNumber => headerIndex => headerData (stored as bytes32)
    mapping(uint256 => mapping(uint256 => bytes32)) public headers;

    /// @notice Maps blockNumber => blockHash if committed or known
    mapping(uint256 => bytes32) public hashes;

    /// @notice Maps taskIndex => Task
    mapping(uint256 => Task) public tasks;

    //--------------------------------------------------------------------------
    // Modifiers
    //--------------------------------------------------------------------------

    /// @dev Checks if `account` is a contract by using `extcodesize`.
    ///      Note: This is not a perfect check. Contracts can self-destruct.
    modifier onlyContract(address account) {
        uint32 size;
        assembly {
            size := extcodesize(account)
        }
        if (size == 0) revert OnlyContracts();
        _;
    }

    //--------------------------------------------------------------------------
    // Public/External Functions
    //--------------------------------------------------------------------------

    /// @inheritdoc IHeaderProtocol
    function getTaskIndex() external view returns (uint256) {
        return _taskIndex;
    }

    /// @inheritdoc IHeaderProtocol
    function getTask(uint256 taskIndex) external view returns (Task memory) {
        return tasks[taskIndex];
    }

    /// @inheritdoc IHeaderProtocol
    function request(
        uint256 blockNumber,
        uint256 headerIndex
    ) external payable onlyContract(msg.sender) returns (uint256) {
        return _request(blockNumber, headerIndex);
    }

    /// @inheritdoc IHeaderProtocol
    function response(
        address contractAddress,
        uint256 blockNumber,
        uint256 headerIndex,
        bytes calldata blockHeader
    ) external nonReentrant {
        _response(blockNumber, headerIndex, blockHeader, contractAddress, 0);
    }

    /// @inheritdoc IHeaderProtocol
    function response(
        uint256 taskIndex,
        bytes calldata blockHeader
    ) external nonReentrant {
        Task memory task = tasks[taskIndex];
        uint256 blockNumber = uint256(task.blockNumber);
        uint256 headerIndex = uint256(task.headerIndex);
        uint256 feeAmount = uint256(task.feeAmount) * 1e6;
        address contractAddress = task.contractAddress;

        // If not stored yet, pay the executor
        bool isPaidTask = (feeAmount > 0 &&
            headers[blockNumber][headerIndex] == bytes32(0));

        _response(
            blockNumber,
            headerIndex,
            blockHeader,
            contractAddress,
            isPaidTask ? feeAmount : 0
        );
    }

    /// @inheritdoc IHeaderProtocol
    function commit(uint256 blockNumber) external {
        bytes32 bh = blockhash(blockNumber);
        if (hashes[blockNumber] == bytes32(0) && bh != bytes32(0)) {
            hashes[blockNumber] = bh;
        }
    }

    /// @inheritdoc IHeaderProtocol
    function refund(uint256 taskIndex) external nonReentrant {
        if (!isRefundable(taskIndex)) revert TaskIsNonRefundable();

        Task storage task = tasks[taskIndex];
        uint256 refundAmount = uint256(task.feeAmount) * 1e6;
        task.feeAmount = 0;
        _call(task.contractAddress, refundAmount);
    }

    /// @inheritdoc IHeaderProtocol
    function isRefundable(uint256 taskIndex) public view returns (bool) {
        Task storage task = tasks[taskIndex];
        uint256 blockNumber = uint256(task.blockNumber);
        uint256 headerIndex = uint256(task.headerIndex);
        uint256 feeAmount = uint256(task.feeAmount) * 1e6;

        bytes32 bh = (hashes[blockNumber] != bytes32(0))
            ? hashes[blockNumber]
            : blockhash(blockNumber);

        // Refund conditions:
        // - Task is paid (feeAmount > 0)
        // - The requested blockNumber is already in the past (blockNumber < current block)
        // - Header not completed (headers[blockNumber][headerIndex] == 0)
        // - No blockhash available (bh == 0) meaning we cannot complete it anymore
        //   due to blockhash retention limit passed (more than 256 blocks later)
        if (
            feeAmount > 0 &&
            blockNumber < block.number &&
            headers[blockNumber][headerIndex] == bytes32(0) &&
            bh == bytes32(0)
        ) {
            return true;
        }

        return false;
    }

    //--------------------------------------------------------------------------
    // Internal Functions
    //--------------------------------------------------------------------------

    function _request(
        uint256 blockNumber,
        uint256 headerIndex
    ) internal returns (uint256 taskIndex) {
        uint256 bn = block.number >= 256 ? block.number - 256 : 0;
        if (blockNumber < bn || blockNumber > type(uint40).max) {
            revert InvalidBlockNumber();
        }
        if (headerIndex > type(uint8).max) revert InvalidHeaderIndex();
        if (msg.value >= 100 ether) revert RewardExceeds100ETH();

        if (msg.value > 0) {
            taskIndex = ++_taskIndex;
            tasks[taskIndex] = Task({
                contractAddress: msg.sender,
                feeAmount: uint48(msg.value / 1e6),
                blockNumber: uint40(blockNumber),
                headerIndex: uint8(headerIndex)
            });
        }

        emit BlockHeaderRequested(
            msg.sender,
            blockNumber,
            headerIndex,
            msg.value
        );
    }

    function _response(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes memory blockHeader,
        address contractAddress,
        uint256 feeAmount
    ) internal {
        bool success;

        // If we already have a stored header, just forward it without validation cost
        if (headers[blockNumber][headerIndex] != bytes32(0)) {
            bytes32 storedHeader = headers[blockNumber][headerIndex];
            // slither-disable-next-line unused-return
            (success, ) = contractAddress.excessivelySafeCall(
                30_000,
                0,
                0,
                abi.encodeWithSelector(
                    IHeader(contractAddress).responseBlockHeader.selector,
                    blockNumber,
                    headerIndex,
                    storedHeader
                )
            );
            if (!success) revert ExternalCallFailed();
            // Data already known, no event emission or payment
            return;
        }

        bytes32 bh = hashes[blockNumber] != bytes32(0)
            ? hashes[blockNumber]
            : blockhash(blockNumber);

        if (bh == bytes32(0)) revert FailedToObtainBlockHash();
        if (blockHeader.length == 0) revert BlockHeaderIsEmpty();

        RLPReader.RLPItem memory item = blockHeader.toRlpItem();
        if (bh != item.rlpBytesKeccak256()) revert HeaderHashMismatch();
        RLPReader.Iterator memory iterator = item.iterator();

        for (uint256 i = 0; i < headerIndex; i++) {
            // slither-disable-next-line unused-return
            iterator.next();
        }

        bytes memory result = iterator.next().toBytes();
        if (result.length == 0) revert HeaderDataIsEmpty();

        bytes32 headerData;
        assembly {
            headerData := mload(add(result, 32))
        }

        if (feeAmount > 0) {
            headers[blockNumber][headerIndex] = headerData;
            _call(msg.sender, feeAmount);
        }

        // slither-disable-next-line unused-return
        (success, ) = contractAddress.excessivelySafeCall(
            30_000,
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

        emit BlockHeaderResponded(msg.sender, blockNumber, headerIndex);
    }

    function _call(address to, uint256 value) internal {
        // slither-disable-next-line arbitrary-send-eth low-level-calls
        (bool sent, ) = payable(to).call{value: value}("");
        if (!sent) revert FailedToSendEther();
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
