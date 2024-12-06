// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHeader
/// @notice Interface for contracts that receive block headers
/// @dev Implement this interface in contracts that need to receive verified block headers from the HeaderProtocol.
interface IHeader {
    /**
     * @notice Called by HeaderProtocol to provide a verified block header
     * @dev This function should handle the trusted block header data. The implementer is responsible for
     *      verifying the authenticity of the caller if needed. Typically, only the known HeaderProtocol address
     *      should be allowed to call this.
     * @param blockNumber The block number for which the header is being provided
     * @param header The RLP-encoded block header data
     */
    function responseBlockHeader(
        uint256 blockNumber,
        bytes calldata header
    ) external;
}
