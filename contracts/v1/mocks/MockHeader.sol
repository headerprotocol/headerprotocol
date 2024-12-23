// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHeaderProtocol, IHeader} from "../interfaces/IHeaderProtocol.sol";

contract MockHeader is IHeader {
    IHeaderProtocol private protocol;

    // blockNumber => headerIndex => headerData
    mapping(uint256 => mapping(uint256 => bytes32)) public headers;

    constructor(address _protocol) {
        protocol = IHeaderProtocol(_protocol);
    }

    function mockRequest(
        uint256 blockNumber,
        uint256 headerIndex
    ) external payable {
        protocol.request{value: msg.value}(blockNumber, headerIndex);
    }

    function mockCommit(uint256 blockNumber) external {
        protocol.commit(blockNumber);
    }

    function mockRefund(uint256 blockNumber, uint256 headerIndex) external {
        protocol.refund(blockNumber, headerIndex);
    }

    // required implementation of IHeader
    function responseBlockHeader(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes32 headerData
    ) external {
        require(msg.sender == address(protocol), "Only Header Protocol");
        headers[blockNumber][headerIndex] = headerData; // 30,000 gas limit, only save
    }

    receive() external payable {} // accept refunds
}
