// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HeaderProtocol} from "@headerprotocol/contracts/v1/HeaderProtocol.sol";
import {IHeaderProtocol, IHeader} from "@headerprotocol/contracts/v1/interfaces/IHeaderProtocol.sol";

interface IHeaderProtocolExposed is IHeaderProtocol {
    function headers(
        uint256 blockNumber,
        uint256 headerIndex
    ) external view returns (bytes32);
    function hashes(uint256 blockNumber) external view returns (bytes32);
    function tasks(uint256 taskIndex) external view returns (Task memory);
}

contract MockConsumer is IHeader {
    bytes32 public storedHeaderData;

    receive() external payable {}

    function responseBlockHeader(
        uint256,
        uint256,
        bytes32 headerData
    ) external {
        storedHeaderData = headerData;
    }
}

contract ContractCaller is IHeader {
    bytes32 public storedHeaderData;
    uint256 public storedBlockNumber;
    uint256 public storedHeaderIndex;

    IHeaderProtocol private protocol;

    constructor(address _protocol) {
        protocol = IHeaderProtocol(_protocol);
    }

    receive() external payable {}

    function requestHeader(
        uint256 blockNumber,
        uint256 headerIndex
    ) external payable returns (uint256) {
        storedBlockNumber = blockNumber;
        storedHeaderIndex = headerIndex;
        return protocol.request{value: msg.value}(blockNumber, headerIndex);
    }

    function responseBlockHeader(
        uint256 blockNumber,
        uint256 headerIndex,
        bytes32 headerData
    ) external {
        if (
            blockNumber == storedBlockNumber && headerIndex == storedHeaderIndex
        ) {
            storedHeaderData = headerData;
        }
    }
}

contract MaliciousConsumer is IHeader {
    function responseBlockHeader(uint256, uint256, bytes32) external pure {
        revert("I always revert");
    }
}

contract NonPayableContract {
    // no payable fallback or receive
}

contract RevertingReceiver {
    IHeaderProtocol private protocol;

    constructor(address _protocol) {
        protocol = IHeaderProtocol(_protocol);
    }

    // revert on receive
    receive() external payable {
        revert("no receive");
    }

    function createPaidTask(
        uint256 blockNumber,
        uint256 headerIndex,
        uint256 val
    ) external payable returns (uint256) {
        return protocol.request{value: val}(blockNumber, headerIndex);
    }
}

contract HeaderProtocolTest is Test {
    HeaderProtocol private protocol;
    MockConsumer private consumer;
    ContractCaller private contractCaller;

    // Provided test data
    uint256 testBlockNumber = 21359530;
    uint256 headerIndex = 15; // baseFeePerGas index
    bytes32 fakeBlockHash =
        0x05240b68dabd88b2aa91270112211762de2873306c0c5008d7c3621f1ce22b65;

    // Provided RLP encoded block header from the given Python script
    bytes blockHeader =
        hex"f9024da005951b9add591b5a0d4411ecbaa282cc3bf0f6bb4095dcc5c979c1ca4c1d813ca01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d4934794612d6b48eb86ba469d3e237ca610aa2a71dc9234a07e0ebb048bfdbdc1331f8ff17c3e7463c024edef642ad56594754875299a8350a0a97009f7f3ed3895bc57e4654c8f95a8294ccaf35c87a1f8f64721c1a053de77a020cb7c208f952db8f1ab6ed9976d63e7f763ade94820e4d7eabc19bbfc011ae8b9010011e800630fa0244118088310aa051d6610223101111110025219a012c00240234041a58c944100364e00b310800f8904163b8068ec8148004c480647012a8ba434011c0841100ca16926748982c5622a02020b2084404a087435c46081490b26c748614092cc6582244640112c40bcd10c1a006ab920a76803491337400316103948021102c0611400c11102411310a610019e414d50901cca31045a4c93902002aa942db80160a4611048c009098d4020240c4008b459a71c0100022888e341ab4011a25110015e50591477910890d4298808420000d13846804002836020c483b172391583856080cd81922c33800c66c0616800c40850cc2a22c2312c544580840145ebaa8401c9c3808373e32c846755e39780a01f59c2ad36a2fe1ae1669cd02d8dbc7fb156613ab0940e5ef746807f678be0a38800000000000000008502939b6d04a0d86d13bcc8747fe14885674a59e32f23690efe265cba04cf7a9a4904ed331115830a00008403dc0000a0763517c48f02ef97e4375cee60c49bb8cea82c401347d328e2e438ac6e019bb3";

    receive() external payable {}

    function setUp() public {
        protocol = new HeaderProtocol();
        consumer = new MockConsumer();
        contractCaller = new ContractCaller(address(protocol));

        vm.deal(address(contractCaller), 200 ether);

        // Set the chain state
        vm.roll(testBlockNumber);
        vm.setBlockhash(testBlockNumber, fakeBlockHash);
        // Now blockhash(testBlockNumber) == fakeBlockHash only after we move forward a block
    }

    //--------------------------------------------------------------------------
    // Helper
    //--------------------------------------------------------------------------
    function moveOneBlockPast(uint256 blockNum) internal {
        // Make sure we can retrieve blockhash(blockNum)
        vm.roll(blockNum + 1);
    }

    function roll256BlocksLater(uint256 startBlock) internal {
        vm.roll(startBlock + 300);
    }

    //--------------------------------------------------------------------------
    // Error checks
    //--------------------------------------------------------------------------

    function testRevertOnlyContractsWhenRequestFromEOA() public {
        address eoa = address(0x1234);
        vm.deal(eoa, 10 ether);
        vm.startPrank(eoa);
        vm.expectRevert(IHeaderProtocol.OnlyContracts.selector);
        protocol.request{value: 1 ether}(testBlockNumber, headerIndex);
        vm.stopPrank();
    }

    function testRevertInvalidBlockNumberFuture() public {
        uint256 tooBig = type(uint40).max;
        tooBig = tooBig + 1;
        vm.expectRevert(IHeaderProtocol.InvalidBlockNumber.selector);
        contractCaller.requestHeader(tooBig, headerIndex);
    }

    function testRevertInvalidBlockNumberPastTooOld() public {
        if (testBlockNumber > 256) {
            uint256 oldBlock = testBlockNumber - 257;
            vm.expectRevert(IHeaderProtocol.InvalidBlockNumber.selector);
            contractCaller.requestHeader(oldBlock, headerIndex);
        } else {
            // If testBlockNumber <=256, skip this test scenario
            // no revert expected
            assertTrue(true);
        }
    }

    function testRevertInvalidHeaderIndex() public {
        vm.expectRevert(IHeaderProtocol.InvalidHeaderIndex.selector);
        contractCaller.requestHeader(testBlockNumber, 999999);
    }

    function testRevertRewardExceeds100ETH() public {
        vm.expectRevert(IHeaderProtocol.RewardExceeds100ETH.selector);
        contractCaller.requestHeader{value: 101 ether}(
            testBlockNumber,
            headerIndex
        );
    }

    function testRevertFailedToObtainBlockHashOnResponse() public {
        // Request a free task for a future block with no blockhash
        uint256 unknownBlock = testBlockNumber + 10;
        contractCaller.requestHeader(unknownBlock, headerIndex);

        vm.expectRevert(IHeaderProtocol.FailedToObtainBlockHash.selector);
        // no move forward, blockhash unknownBlock is zero
        protocol.response(
            address(consumer),
            unknownBlock,
            headerIndex,
            blockHeader
        );
    }

    function testRevertBlockHeaderIsEmptyOnResponse() public {
        contractCaller.requestHeader(testBlockNumber, headerIndex);
        moveOneBlockPast(testBlockNumber); // Now blockhash(testBlockNumber) known
        bytes memory emptyHeader = hex"";
        vm.expectRevert(IHeaderProtocol.BlockHeaderIsEmpty.selector);
        protocol.response(
            address(consumer),
            testBlockNumber,
            headerIndex,
            emptyHeader
        );
    }

    function testRevertHeaderHashMismatch() public {
        contractCaller.requestHeader(testBlockNumber, headerIndex);
        moveOneBlockPast(testBlockNumber);
        bytes memory wrongHeader = hex"f9010a808080";
        vm.expectRevert(IHeaderProtocol.HeaderHashMismatch.selector);
        protocol.response(
            address(consumer),
            testBlockNumber,
            headerIndex,
            wrongHeader
        );
    }

    function testRevertHeaderDataIsEmpty() public {
        // extraData is at index 12 and it's empty in the provided header (HexBytes("0x"),  # extraData)
        uint256 emptyIndex = 12;
        contractCaller.requestHeader(testBlockNumber, emptyIndex);
        moveOneBlockPast(testBlockNumber);
        vm.expectRevert(IHeaderProtocol.HeaderDataIsEmpty.selector);
        protocol.response(
            address(consumer),
            testBlockNumber,
            emptyIndex,
            blockHeader
        );
    }

    function testRevertExternalCallFailed() public {
        MaliciousConsumer badConsumer = new MaliciousConsumer();
        contractCaller.requestHeader(testBlockNumber, headerIndex);
        moveOneBlockPast(testBlockNumber);
        vm.expectRevert(IHeaderProtocol.ExternalCallFailed.selector);
        protocol.response(
            address(badConsumer),
            testBlockNumber,
            headerIndex,
            blockHeader
        );
    }

    function testRevertTaskIsNonRefundable() public {
        uint256 taskIndex = contractCaller.requestHeader{value: 1 ether}(
            testBlockNumber,
            headerIndex
        );
        // Still completable, blockhash known
        vm.expectRevert(IHeaderProtocol.TaskIsNonRefundable.selector);
        protocol.refund(taskIndex);
    }

    function testRevertDirectPaymentsNotSupported() public {
        vm.expectRevert(IHeaderProtocol.DirectPaymentsNotSupported.selector);
        payable(address(protocol)).transfer(1 ether);
    }

    function testRevertFunctionDoesNotExistFallback() public {
        vm.expectRevert(IHeaderProtocol.FunctionDoesNotExist.selector);
        (bool success, ) = address(protocol).call(
            abi.encodeWithSignature("nonExistentFunction()")
        );
        success;
    }

    //--------------------------------------------------------------------------
    // Success scenarios
    //--------------------------------------------------------------------------

    function testFreeTaskRequestAndResponse() public {
        uint256 taskIndex = contractCaller.requestHeader(
            testBlockNumber,
            headerIndex
        );
        assertEq(taskIndex, 0);
        moveOneBlockPast(testBlockNumber);
        protocol.response(
            address(consumer),
            testBlockNumber,
            headerIndex,
            blockHeader
        );

        assertTrue(consumer.storedHeaderData() != bytes32(0));
    }

    function testPaidTaskRequestAndResponse() public {
        uint256 taskIndex = contractCaller.requestHeader{value: 1 ether}(
            testBlockNumber,
            headerIndex
        );
        assertTrue(taskIndex > 0);

        moveOneBlockPast(testBlockNumber);

        // Executor is this contract, must receive Ether
        uint256 beforeBalance = address(this).balance;
        protocol.response(taskIndex, blockHeader);
        uint256 afterBalance = address(this).balance;

        // got paid 1 ether
        assertEq(afterBalance - beforeBalance, 1 ether);

        assertEq(contractCaller.storedBlockNumber(), testBlockNumber);
        assertEq(contractCaller.storedHeaderIndex(), headerIndex);
        assertTrue(contractCaller.storedHeaderData() != bytes32(0));

        bytes32 storedHeader = IHeaderProtocolExposed(address(protocol))
            .headers(testBlockNumber, headerIndex);
        assertTrue(storedHeader != bytes32(0));
    }

    function testPaidTaskAlreadyStoredHeader() public {
        // First paid task
        uint256 firstTaskIndex = contractCaller.requestHeader{value: 1 ether}(
            testBlockNumber,
            headerIndex
        );
        moveOneBlockPast(testBlockNumber);
        protocol.response(firstTaskIndex, blockHeader);

        // Another task for same block/headerIndex
        uint256 secondTaskIndex = contractCaller.requestHeader{value: 1 ether}(
            testBlockNumber,
            headerIndex
        );

        // Move another block
        vm.roll(block.number + 1);
        uint256 executorBefore = address(this).balance;
        protocol.response(secondTaskIndex, blockHeader);
        uint256 executorAfter = address(this).balance;
        assertEq(executorAfter, executorBefore); // no extra payment

        assertEq(contractCaller.storedBlockNumber(), testBlockNumber);
        assertEq(contractCaller.storedHeaderIndex(), headerIndex);
    }

    function testCommitAndCompleteAfter256Blocks() public {
        uint256 futureBlock = testBlockNumber + 300;
        uint256 taskIndex = contractCaller.requestHeader{value: 1 ether}(
            futureBlock,
            headerIndex
        );

        // Advance to futureBlock
        vm.roll(futureBlock);
        vm.setBlockhash(futureBlock, fakeBlockHash);
        moveOneBlockPast(futureBlock);

        // commit blockhash
        protocol.commit(futureBlock);
        assertEq(
            IHeaderProtocolExposed(address(protocol)).hashes(futureBlock),
            fakeBlockHash
        );

        // Roll another 300 blocks
        roll256BlocksLater(futureBlock);

        // now respond
        uint256 beforeBal = address(this).balance;
        protocol.response(taskIndex, blockHeader);
        uint256 afterBal = address(this).balance;
        assertEq(afterBal - beforeBal, 1 ether);

        assertEq(contractCaller.storedBlockNumber(), futureBlock);
        assertEq(contractCaller.storedHeaderIndex(), headerIndex);
        assertTrue(contractCaller.storedHeaderData() != bytes32(0));
    }

    function testRefundAfter256BlocksNoCommitNoHash() public {
        vm.deal(address(consumer), 10 ether);
        vm.startPrank(address(consumer));
        uint256 oldBlock = testBlockNumber - 1;
        vm.roll(oldBlock);
        vm.setBlockhash(oldBlock, bytes32("somehash"));
        moveOneBlockPast(oldBlock);

        // now request from consumer
        uint256 taskIndex = protocol.request{value: 1 ether}(
            oldBlock,
            headerIndex
        );
        vm.stopPrank();

        // roll far ahead
        roll256BlocksLater(oldBlock);
        // set blockhash(oldBlock)=0 (no commit)
        vm.setBlockhash(oldBlock, bytes32(0));

        bool refundable = protocol.isRefundable(taskIndex);
        assertTrue(refundable);

        uint256 consumerBalBefore = address(consumer).balance;
        protocol.refund(taskIndex);
        uint256 consumerBalAfter = address(consumer).balance;
        // consumer requested, consumer receives refund
        assertEq(consumerBalAfter - consumerBalBefore, 1 ether);
    }
}
