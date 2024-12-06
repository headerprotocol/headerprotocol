// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHeaderProtocol} from "@headerprotocol/contracts/v1/interfaces/IHeaderProtocol.sol";
import {IHeader} from "@headerprotocol/contracts/v1/interfaces/IHeader.sol";
import {RLPReader} from "@headerprotocol/contracts/v1/utils/RLPReader.sol";

/// @title HeaderProtocol
/// @notice Allows contracts to request and receive verified Ethereum block headers.
/// @dev Requesters post requests with optional Ether rewards. Responders verify and provide headers to earn rewards.
contract HeaderProtocol is IHeaderProtocol {
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;

    //--------------------------------------------------------------------------
    // Errors
    //--------------------------------------------------------------------------
    error ReentrantCall();
    error OnlyContracts();
    error InvalidBlockNumber();
    error OutOfRecentBlockRange();
    error FailedToObtainBlockHash();
    error HeaderIsEmpty();
    error HeaderHashMismatch();
    error FailedToSendEther();
    error DirectPaymentsNotSupported();
    error FunctionDoesNotExist();

    //--------------------------------------------------------------------------
    // Events
    //--------------------------------------------------------------------------
    /// @notice Emitted when a block header request is created
    /// @param requester The requesting contract address
    /// @param blockNumber The requested block number
    /// @param reward The Ether incentive offered
    event BlockHeaderRequested(
        address indexed requester,
        uint256 indexed blockNumber,
        uint256 reward
    );

    //--------------------------------------------------------------------------
    // Structs
    //--------------------------------------------------------------------------
    struct StoredHeader {
        address requester;
        bytes header;
        uint256 reward;
    }

    //--------------------------------------------------------------------------
    // State
    //--------------------------------------------------------------------------
    mapping(uint256 => StoredHeader) public headers;
    bool private _reentrancyGuard;

    //--------------------------------------------------------------------------
    // Modifiers
    //--------------------------------------------------------------------------
    modifier nonReentrant() {
        if (_reentrancyGuard) revert ReentrantCall();
        _reentrancyGuard = true;
        _;
        _reentrancyGuard = false;
    }

    modifier onlyContractCaller(address account) {
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

    /**
     * @notice Request a block header for a specific block number
     * @dev If `msg.value > 0`, that Ether is a reward for providing the header.
     * @param blockNumber The block number requested
     */
    function request(
        uint256 blockNumber
    ) external payable onlyContractCaller(msg.sender) {
        if (blockNumber == 0) revert InvalidBlockNumber();

        uint256 currentBlock = block.number;
        uint256 historicLimit = currentBlock > 256 ? currentBlock - 256 : 0;

        // If block is out of the recent 256 block range and no header stored, revert
        if (
            blockNumber <= historicLimit &&
            headers[blockNumber].header.length == 0
        ) {
            revert OutOfRecentBlockRange();
        }

        if (msg.value > 0) {
            headers[blockNumber] = StoredHeader(msg.sender, "", msg.value);
        }

        emit BlockHeaderRequested(msg.sender, blockNumber, msg.value);
    }

    /**
     * @notice Respond with a verified block header for a previously requested block
     * @dev Checks if header already exists. If not, validates the provided header against blockhash.
     * @param blockNumber The block number of the provided header
     * @param header The block header RLP data
     * @param requester The original requester
     */
    function response(
        uint256 blockNumber,
        bytes calldata header,
        address requester
    ) external nonReentrant {
        StoredHeader storage stored = headers[blockNumber];

        // If we already have a stored header, just return it
        if (stored.header.length > 0) {
            IHeader(requester).responseBlockHeader(blockNumber, stored.header);
            return;
        }

        if (blockNumber == 0) revert InvalidBlockNumber();

        uint256 currentBlock = block.number;
        uint256 historicLimit = currentBlock > 256 ? currentBlock - 256 : 0;

        // If block is too old or is a future block, revert as out of range
        if (blockNumber > currentBlock || blockNumber <= historicLimit) {
            revert OutOfRecentBlockRange();
        }

        bytes32 bh = blockhash(blockNumber);

        // Check for empty header before checking blockhash availability
        if (header.length == 0) revert HeaderIsEmpty();

        // If blockhash is zero, we cannot obtain block data
        if (bh == bytes32(0)) revert FailedToObtainBlockHash();

        RLPReader.RLPItem memory item = header.toRlpItem();
        if (bh != item.rlpBytesKeccak256()) revert HeaderHashMismatch();

        // Header verified successfully
        if (stored.reward > 0) {
            stored.header = header;
            // slither-disable-next-line arbitrary-send-eth low-level-calls
            (bool sent, ) = msg.sender.call{value: stored.reward}("");
            if (!sent) revert FailedToSendEther();
            IHeader(stored.requester).responseBlockHeader(blockNumber, header);
        } else {
            IHeader(requester).responseBlockHeader(blockNumber, header);
        }
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
