// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHeaderProtocol} from "@headerprotocol/contracts/v1/interfaces/IHeaderProtocol.sol";
import {IHeader} from "@headerprotocol/contracts/v1/interfaces/IHeader.sol";
import {RLPReader} from "@headerprotocol/contracts/v1/utils/RLPReader.sol";

/// @title HeaderProtocol
/// @notice Implementation of the `IHeaderProtocol` interface to handle
///         requests, responses, and refunds for Ethereum block headers.
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

    /// @notice Emitted when a block header is successfully responded to
    /// @param responder The address of the responder
    /// @param blockNumber The block number of the responded header
    event BlockHeaderResponded(
        address indexed responder,
        uint256 indexed blockNumber
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
    // Implementation of IHeaderProtocol
    //--------------------------------------------------------------------------

    /**
     * @inheritdoc IHeaderProtocol
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
     * @inheritdoc IHeaderProtocol
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

        emit BlockHeaderResponded(msg.sender, blockNumber);
    }

    /**
     * @inheritdoc IHeaderProtocol
     */
    function refund(uint256 blockNumber) external nonReentrant {
        StoredHeader storage stored = headers[blockNumber];

        uint256 currentBlock = block.number;
        uint256 historicLimit = currentBlock > 256 ? currentBlock - 256 : 0;

        if (
            blockNumber < historicLimit &&
            stored.reward > 0 &&
            stored.header.length == 0
        ) {
            uint256 reward = stored.reward;
            stored.reward = 0;

            // slither-disable-next-line arbitrary-send-eth low-level-calls
            (bool sent, ) = payable(stored.requester).call{value: reward}("");
            if (!sent) revert FailedToSendEther();
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
