// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHeaderProtocol
/// @notice Interface for the Header Protocol, allowing requests and responses for Ethereum block headers.
/// @dev header: [parentHash, sha3Uncles, miner, stateRoot, transactionsRoot, receiptsRoot, logsBloom,
///      difficulty, number, gasLimit, gasUsed, timestamp, extraData, mixHash, nonce,
///      baseFeePerGas, withdrawalsRoot, blobGasUsed, excessBlobGas, parentBeaconBlockRoot]
interface IHeaderProtocol {
    //--------------------------------------------------------------------------
    // Errors
    //--------------------------------------------------------------------------

    error ReentrantCall();
    error OnlyContracts();
    error InvalidBlockNumber();
    error InvalidHeaderIndex();
    error RewardExceeds100ETH();
    error FailedToObtainBlockHash();
    error BlockHeaderIsEmpty();
    error HeaderHashMismatch();
    error HeaderDataIsEmpty();
    error TaskIsNonRefundable();
    error ExternalCallFailed();
    error FailedToSendEther();
    error DirectPaymentsNotSupported();
    error FunctionDoesNotExist();

    //--------------------------------------------------------------------------
    // Events
    //--------------------------------------------------------------------------

    /// @notice Emitted when a new block header request is created.
    /// @param contractAddress The contract requesting the header data.
    /// @param blockNumber The number of the block for which the header is requested.
    /// @param headerIndex The index of the header field requested.
    /// @param feeAmount The fee (in wei) offered as a reward for fulfilling the request. If zero, the request is free.
    event BlockHeaderRequested(
        address indexed contractAddress,
        uint256 indexed blockNumber,
        uint256 indexed headerIndex,
        uint256 feeAmount
    );

    /// @notice Emitted when a block header request is successfully responded to.
    /// @param responder The address of the executor who provided the header.
    /// @param blockNumber The number of the block that was responded to.
    /// @param headerIndex The index of the header field that was retrieved.
    event BlockHeaderResponded(
        address indexed responder,
        uint256 indexed blockNumber,
        uint256 indexed headerIndex
    );

    //--------------------------------------------------------------------------
    // Structs
    //--------------------------------------------------------------------------

    /// @notice Structure holding request task details.
    /// @dev `feeAmount` is the amount of Ether locked as a reward.
    ///      `contractAddress` is the contract that will receive the header data callback.
    ///      `blockNumber` is the requested block number.
    ///      `headerIndex` indicates which header field is requested.
    struct Task {
        address contractAddress;
        uint48 feeAmount;
        uint40 blockNumber;
        uint8 headerIndex;
    }

    //--------------------------------------------------------------------------
    // Functions
    //--------------------------------------------------------------------------

    /// @notice Retrieves the current task index counter.
    /// @return The current task index which increments every time a new paid task is created.
    function getTaskIndex() external view returns (uint256);

    /// @notice Retrieves information about a specific task by its index.
    /// @param taskIndex The index of the task.
    /// @return A Task structure containing details of the specified task.
    function getTask(uint256 taskIndex) external view returns (Task memory);

    /// @notice Requests a block header.
    /// @dev If `msg.value > 0`, a paid task is created and stored in the contract. The returned `taskIndex` can be used to request a refund if not completed.
    ///      If `msg.value == 0`, this is a free task, no state is stored and `taskIndex` will be 0.
    /// @param blockNumber The block number for which the header is requested.
    /// @param headerIndex The index of the requested header field.
    /// @return taskIndex The index of the created task if paid, otherwise 0.
    function request(
        uint256 blockNumber,
        uint256 headerIndex
    ) external payable returns (uint256 taskIndex);

    /// @notice Provides a block header response to a free (unpaid) request.
    /// @dev Calls `responseBlockHeader` on the requesting contract, if the header is valid.
    ///      This variant is used when no stored taskIndex is involved.
    /// @param contractAddress The contract that requested the header.
    /// @param blockNumber The block number of the requested header.
    /// @param headerIndex The requested header index.
    /// @param blockHeader The RLP-encoded block header data.
    function response(
        address contractAddress,
        uint256 blockNumber,
        uint256 headerIndex,
        bytes calldata blockHeader
    ) external;

    /// @notice Provides a block header response to a paid request identified by `taskIndex`.
    /// @dev If this is the first time the header is being responded to, the executor receives the fee.
    ///      Otherwise, the header might already be stored, and no payment is made.
    /// @param taskIndex The index of the paid task.
    /// @param blockHeader The RLP-encoded block header data.
    function response(uint256 taskIndex, bytes calldata blockHeader) external;

    /// @notice Commits the `blockhash` of a certain block to the contract's storage.
    /// @dev This allows retrieving blockhashes after the 256-block limit has passed.
    ///      Useful if a header is requested far in the future, ensuring blockhash availability later.
    /// @param blockNumber The block number for which to store the blockhash.
    function commit(uint256 blockNumber) external;

    /// @notice Refunds the fee for a task if it is no longer completable.
    /// @dev Only possible if:
    ///      - The block is sufficiently in the past that blockhash is no longer available.
    ///      - The task has not been completed.
    /// @param taskIndex The index of the task to refund.
    function refund(uint256 taskIndex) external;

    /// @notice Checks if a task is refundable.
    /// @dev Returns true if the task conditions make it impossible to complete (blockhash not available and no commit was done).
    /// @param taskIndex The index of the task.
    /// @return result True if refundable, false otherwise.
    function isRefundable(
        uint256 taskIndex
    ) external view returns (bool result);
}

/// @title IHeader
/// @notice Interface that must be implemented by contracts using the HeaderProtocol.
/// @dev The HeaderProtocol will call `responseBlockHeader` once the requested header is verified.
interface IHeader {
    /// @notice Called by the HeaderProtocol contract to provide verified block header data.
    /// @param blockNumber The block number of the requested header.
    /// @param headerIndex The index of the header field requested.
    /// @param headerData The requested header data, always 32 bytes.
    /// @dev This function should not consume more than 22,000 gas. Store or process `headerData` efficiently.
    /// @dev Implementing contracts can interpret `headerData` as `uint256`, `bytes32`, or any required format.
    function responseBlockHeader(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes32 headerData
    ) external;
}
