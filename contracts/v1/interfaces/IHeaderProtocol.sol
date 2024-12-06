// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHeaderProtocol
/// @notice Interface for a protocol that requests and provides EVM block headers
/// @dev External contracts call `request(blockNumber)` to request a block header and may optionally provide a reward.
///      Off-chain observers call `response(blockNumber, header, requester)` to provide the requested header.
///      The implementer of this interface should verify the provided header against the EVM's `blockhash` to ensure authenticity.
interface IHeaderProtocol {
    /**
     * @notice Requests a block header for a specified block number
     * @dev If Ether is sent with this call, it is used as a reward for whoever provides the valid header first.
     * @param blockNumber The block number for which the header is requested
     */
    function request(uint256 blockNumber) external payable;

    /**
     * @notice Provides a block header in response to a previously requested block
     * @dev The implementer should verify that the provided `header` matches the expected `blockhash(blockNumber)`.
     *      If it matches, the responder may receive the stored reward, and `responseBlockHeader` is called on the requester.
     * @param blockNumber The block number of the provided header
     * @param header The RLP-encoded block header data
     * @param requester The address of the contract that made the original request
     */
    function response(
        uint256 blockNumber,
        bytes calldata header,
        address requester
    ) external;
}
