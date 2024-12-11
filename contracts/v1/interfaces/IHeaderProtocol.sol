// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHeader
/// @notice Interface for contracts that utilize the Header Protocol to receive verified block header data.
/// @dev The `HeaderProtocol` contract calls `responseBlockHeader` on this contract once the requested header is verified.
///      This callback should be as gas-efficient as possible, ideally ≤30,000 gas.
interface IHeader {
    /// @notice Called by the HeaderProtocol contract to provide a verified block header field.
    /// @param blockNumber The number of the requested block.
    /// @param headerIndex The index of the header field requested.
    /// @param headerData The requested header data (always 32 bytes).
    /// @dev Implementing contracts should handle this efficiently (e.g., store it or trigger necessary logic).
    /// @dev Reverts thrown here will result in the `ExternalCallFailed()` error in the protocol.
    function responseBlockHeader(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes32 headerData
    ) external;
}

/// @title IHeaderProtocol
/// @notice Interface for the updated Header Protocol.
/// @dev The protocol allows requesting and retrieving block header fields (e.g., `baseFeePerGas`, `mixHash`, etc.).
///      Paid requests store a reward in the same storage slot as the header encoding, minimizing gas usage.
///      The protocol no longer uses a separate `taskIndex`; requests are identified by `(blockNumber, headerIndex)`.
interface IHeaderProtocol {
    //--------------------------------------------------------------------------
    // Errors
    //--------------------------------------------------------------------------

    /// @notice Thrown if a reentrant call is detected.
    error ReentrantCall();

    /// @notice Thrown when an externally-owned account (EOA) tries to call a function restricted to contracts.
    error OnlyContracts();

    /// @notice Thrown if the `blockNumber` is invalid (e.g., in the past, beyond certain limits, or not acceptable by the protocol).
    error InvalidBlockNumber();

    /// @notice Thrown if the `headerIndex` exceeds the allowed range.
    error InvalidHeaderIndex();

    /// @notice Thrown if the reward (msg.value) exceeds the allowed maximum (e.g., 18 ETH as per the new implementation).
    error RewardExceedTheLimit();

    /// @notice Thrown if obtaining `blockhash` for the requested block fails (e.g., due to the 256-block limit and no commit).
    error FailedToObtainBlockHash();

    /// @notice Thrown if the provided block header data is empty.
    error BlockHeaderIsEmpty();

    /// @notice Thrown if the provided block header does not match the expected hash.
    error HeaderHashMismatch();

    /// @notice Thrown if the requested header field is empty (no data found in the RLP).
    error HeaderDataIsEmpty();

    /// @notice Thrown if the task (paid request) cannot be refunded (conditions for refund not met).
    error TaskIsNonRefundable();

    /// @notice Thrown if the callback call to the requesting contract fails.
    error ExternalCallFailed();

    /// @notice Thrown if sending Ether fails.
    error FailedToSendEther();

    /// @notice Thrown if Ether is sent directly to the protocol contract without using the designated functions.
    error DirectPaymentsNotSupported();

    /// @notice Thrown if a called function does not exist.
    error FunctionDoesNotExist();

    //--------------------------------------------------------------------------
    // Events
    //--------------------------------------------------------------------------

    /// @notice Emitted when a new block header request is created.
    /// @param contractAddress The contract requesting the header data.
    /// @param blockNumber The number of the block for which the header is requested.
    /// @param headerIndex The index of the header field requested.
    /// @param rewardAmount The fee (in wei) offered as a reward for fulfilling the request.
    ///                  If zero, this is a free request with no reward.
    event BlockHeaderRequested(
        address indexed contractAddress,
        uint256 indexed blockNumber,
        uint256 indexed headerIndex,
        uint256 rewardAmount
    );

    /// @notice Emitted when a block header request is successfully fulfilled.
    /// @param responder The address of the executor who provided the header.
    /// @param blockNumber The number of the block that was fulfilled.
    /// @param headerIndex The index of the header field retrieved.
    event BlockHeaderResponded(
        address indexed responder,
        uint256 indexed blockNumber,
        uint256 indexed headerIndex
    );

    /// @notice Emitted when a blockhash is successfully committed.
    /// @param blockNumber The block number for which the blockhash was committed.
    event BlockHeaderCommitted(uint256 indexed blockNumber);

    /// @notice Emitted when a refund is successfully made for a non-completable task.
    /// @param blockNumber The block number of the refunded request.
    /// @param headerIndex The header index of the refunded request.
    event BlockHeaderRefunded(
        uint256 indexed blockNumber,
        uint256 indexed headerIndex
    );

    //--------------------------------------------------------------------------
    // Functions
    //--------------------------------------------------------------------------

    /// @notice Retrieves a previously committed or still available blockhash for a given block number.
    /// @param blockNumber The block number for which to retrieve the hash.
    /// @return The blockhash if known or zero if not committed and older than 256 blocks.
    function getHash(uint256 blockNumber) external view returns (bytes32);

    /// @notice Retrieves a previously stored header field data.
    /// @param blockNumber The block number for which the header was requested.
    /// @param headerIndex The index of the requested header field.
    /// @return The stored header data as a `bytes32` value. If no header or task info is stored, returns zero.
    /// @dev If this returns a non-zero value, it means the header data is available and no further validation is required.
    function getHeader(
        uint256 blockNumber,
        uint256 headerIndex
    ) external view returns (bytes32);

    /// @notice Requests a block header field.
    /// @param blockNumber The block number for which the header is requested.
    /// @param headerIndex The index of the requested header field.
    /// @dev If `msg.value > 0`, a paid request is created. The reward is stored internally.
    ///      If a header is already known, the caller is immediately refunded and the callback is triggered.
    /// @dev If `msg.value == 0`, a free request is made. No reward is stored, and off-chain executors may fulfill it voluntarily.
    /// @dev Reverts if `blockNumber` or `headerIndex` are invalid, or if `msg.value` exceeds the limit.
    function request(uint256 blockNumber, uint256 headerIndex) external payable;

    /// @notice Provides a block header response for a given request identified by `(blockNumber, headerIndex)`.
    /// @param blockNumber The block number of the requested header.
    /// @param headerIndex The header index requested.
    /// @param blockHeader The RLP-encoded block header data being provided.
    /// @param contractAddress The contract to which the callback `responseBlockHeader` should be sent.
    /// @dev On first successful validation of a paid request, the executor receives the stored reward.
    /// @dev On subsequent calls (if the header is already known), no reward is paid, just the callback is triggered.
    /// @dev Reverts if the provided `blockHeader` is invalid or if external callback fails.
    function response(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes calldata blockHeader,
        address contractAddress
    ) external;

    /// @notice Commits the blockhash of a certain block to the contract's storage.
    /// @param blockNumber The block number for which to store the blockhash.
    /// @dev Useful if a header is requested far in the future, ensuring blockhash availability after 256 blocks.
    function commit(uint256 blockNumber) external;

    /// @notice Refunds the reward for a paid request if it is no longer completable.
    /// @param blockNumber The block number of the request.
    /// @param headerIndex The header index of the request.
    /// @dev Refund conditions:
    ///      - The request had a reward (paid task).
    ///      - The requested block is in the past.
    ///      - The header was never successfully provided.
    ///      - No blockhash is available even after commit attempts (deadline passed).
    /// @dev Reverts if the task is not refundable.
    function refund(uint256 blockNumber, uint256 headerIndex) external;
}
