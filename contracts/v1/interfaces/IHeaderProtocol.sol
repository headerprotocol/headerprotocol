// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHeaderProtocol
/// @notice Interface for a protocol that requests and provides EVM block headers
/// @dev Contracts can call `request(blockNumber)` to request a block header with optional rewards.
///      Responders can provide verified headers through `response(blockNumber, header, requester)`.
///      Refunds for unfulfilled requests can be claimed by the requester using `refund(blockNumber)`.
interface IHeaderProtocol {
    /**
     * @notice Requests a block header for a specified block number.
     * @dev
     * - The caller must be a contract (`extcodesize > 0`).
     * - The block number must be valid and, if older than the recent 256 blocks,
     *   a stored header must exist to prevent reverting.
     * - Ether sent with this function is stored as a reward for responders.
     * @param blockNumber The block number for which the header is requested.
     * @custom:requirements
     * - The `blockNumber` must be > 0.
     * - If `blockNumber` is older than the last 256 blocks, a stored header must exist.
     * - Caller must be a contract.
     * @custom:security
     * - Prevents non-contract calls via a check using `extcodesize`.
     * - Emits the `BlockHeaderRequested` event.
     */
    function request(uint256 blockNumber) external payable;

    /**
     * @notice Provides a block header in response to a previously requested block.
     * @dev
     * - The function verifies the provided header against the EVM’s `blockhash`
     *   for authenticity.
     * - If valid, the responder is rewarded with Ether and the header is stored.
     * - The requester's contract is notified via `responseBlockHeader`.
     * @param blockNumber The block number of the provided header.
     * @param header The RLP-encoded block header data.
     * @param requester The address of the contract that made the original request.
     * @custom:requirements
     * - `blockNumber` must be within the range of [current block - 256, current block].
     * - `header` must match the `blockhash(blockNumber)` for authenticity.
     * - The header must not already exist for the block number.
     * @custom:security
     * - Ensures the integrity of the provided header by validating it against
     *   `blockhash(blockNumber)`.
     * - Prevents reentrancy through the `nonReentrant` modifier.
     * - Emits the `BlockHeaderResponded` event.
     */
    function response(
        uint256 blockNumber,
        bytes calldata header,
        address requester
    ) external;

    /**
     * @notice Allows the original requester to reclaim their reward if no valid response
     *         was provided and the block number is outside the recent 256-block range.
     * @dev
     * - This function checks that:
     *   - The block is older than the historic limit (256 blocks back).
     *   - No header has been stored for the block.
     *   - A reward exists for the request.
     * - Refunds are sent back to the requester, and state is updated to prevent
     *   reentrancy or double-spending.
     * @param blockNumber The block number of the expired request.
     * @custom:requirements
     * - `blockNumber` must be older than the last 256 blocks.
     * - A reward must exist for the block request.
     * - No header must have been stored for the block.
     * @custom:security
     * - Uses a `nonReentrant` modifier to prevent reentrancy attacks.
     * - Updates state before transferring Ether to avoid reentrancy vulnerabilities.
     */
    function refund(uint256 blockNumber) external;
}
