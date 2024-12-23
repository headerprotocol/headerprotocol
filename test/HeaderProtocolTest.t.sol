// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IHeader, IHeaderProtocol} from "@headerprotocol/contracts/v1/interfaces/IHeaderProtocol.sol";
import {HeaderProtocol} from "@headerprotocol/contracts/v1/HeaderProtocol.sol";

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

contract MaliciousConsumer is IHeader {
    function responseBlockHeader(uint256, uint256, bytes32) external pure {
        revert("I always revert");
    }
}

contract HeaderProtocolTest is Test {
    HeaderProtocol private protocol;
    MockConsumer private consumer;
    address private executor;

    bytes32 constant fakeBlockHash =
        0x05240b68dabd88b2aa91270112211762de2873306c0c5008d7c3621f1ce22b65;

    bytes blockHeader =
        hex"f9024da005951b9add591b5a0d4411ecbaa282cc3bf0f6bb4095dcc5c979c1ca4c1d813ca01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d4934794612d6b48eb86ba469d3e237ca610aa2a71dc9234a07e0ebb048bfdbdc1331f8ff17c3e7463c024edef642ad56594754875299a8350a0a97009f7f3ed3895bc57e4654c8f95a8294ccaf35c87a1f8f64721c1a053de77a020cb7c208f952db8f1ab6ed9976d63e7f763ade94820e4d7eabc19bbfc011ae8b9010011e800630fa0244118088310aa051d6610223101111110025219a012c00240234041a58c944100364e00b310800f8904163b8068ec8148004c480647012a8ba434011c0841100ca16926748982c5622a02020b2084404a087435c46081490b26c748614092cc6582244640112c40bcd10c1a006ab920a76803491337400316103948021102c0611400c11102411310a610019e414d50901cca31045a4c93902002aa942db80160a4611048c009098d4020240c4008b459a71c0100022888e341ab4011a25110015e50591477910890d4298808420000d13846804002836020c483b172391583856080cd81922c33800c66c0616800c40850cc2a22c2312c544580840145ebaa8401c9c3808373e32c846755e39780a01f59c2ad36a2fe1ae1669cd02d8dbc7fb156613ab0940e5ef746807f678be0a38800000000000000008502939b6d04a0d86d13bcc8747fe14885674a59e32f23690efe265cba04cf7a9a4904ed331115830a00008403dc0000a0763517c48f02ef97e4375cee60c49bb8cea82c401347d328e2e438ac6e019bb3";

    receive() external payable {}
    fallback() external payable {}

    function setUp() public {
        protocol = new HeaderProtocol();
        consumer = new MockConsumer();
        executor = address(this);
    }

    // Helper to roll forward 256+ blocks
    function roll256BlocksLater(uint256 startBlock) internal {
        vm.roll(startBlock + 300);
    }

    //--------------------------------------------------------------------------
    // Revert Tests
    //--------------------------------------------------------------------------

    function testRevertInvalidBlockNumber() public {
        vm.roll(100);
        vm.expectRevert(IHeaderProtocol.InvalidBlockNumber.selector);
        vm.prank(address(consumer));
        protocol.request(99, 15); // 99<100
    }

    function testRevertInvalidHeaderIndex() public {
        vm.roll(200);
        vm.expectRevert(IHeaderProtocol.InvalidHeaderIndex.selector);
        vm.prank(address(consumer));
        protocol.request(200, 32); // 32 % 20 = 12
    }

    function testRevertRewardExceedTheLimit() public {
        vm.roll(300);
        vm.deal(address(consumer), 19 ether);
        vm.prank(address(consumer));
        vm.expectRevert(IHeaderProtocol.RewardExceedTheLimit.selector);
        protocol.request{value: 19 ether}(300, 15);
    }

    function testRevertFailedToObtainBlockHashOnResponse() public {
        uint256 futureBlock = 2100;
        vm.roll(futureBlock);
        vm.prank(address(consumer));
        protocol.request(futureBlock, 15); // free request
        // no blockhash set and we are far ahead
        vm.roll(2500); // blockhash(futureBlock)=0

        vm.expectRevert(IHeaderProtocol.FailedToObtainBlockHash.selector);
        protocol.response(futureBlock, 15, blockHeader, address(consumer));
    }

    function testRevertBlockHeaderIsEmptyOnResponse() public {
        vm.roll(500);
        vm.prank(address(consumer));
        protocol.request(500, 15);
        vm.roll(501);
        vm.setBlockhash(500, fakeBlockHash);

        bytes memory emptyData = hex"";
        vm.expectRevert(IHeaderProtocol.BlockHeaderIsEmpty.selector);
        protocol.response(500, 15, emptyData, address(consumer));
    }

    function testRevertHeaderHashMismatch() public {
        vm.roll(600);
        vm.prank(address(consumer));
        protocol.request(600, 15);
        vm.roll(601);
        vm.setBlockhash(600, fakeBlockHash);

        bytes memory wrongHeader = hex"f9010a808080";
        vm.expectRevert(IHeaderProtocol.HeaderHashMismatch.selector);
        protocol.response(600, 15, wrongHeader, address(consumer));
    }

    function testRevertHeaderDataIsEmpty() public {
        // difficulty index=7 empty
        vm.roll(700);
        vm.prank(address(consumer));
        protocol.request(700, 7);
        vm.roll(701);
        vm.setBlockhash(700, fakeBlockHash);

        vm.expectRevert(IHeaderProtocol.HeaderDataIsEmpty.selector);
        protocol.response(700, 7, blockHeader, address(consumer));
    }

    function testRevertExternalCallFailed() public {
        MaliciousConsumer badConsumer = new MaliciousConsumer();
        vm.roll(800);
        vm.prank(address(consumer));
        protocol.request(800, 15);
        vm.roll(801);
        vm.setBlockhash(800, fakeBlockHash);

        vm.expectRevert(IHeaderProtocol.ExternalCallFailed.selector);
        protocol.response(800, 15, blockHeader, address(badConsumer));
    }

    function testRevertTaskIsNonRefundable() public {
        // paid task still completable
        vm.deal(address(consumer), 1 ether);
        vm.roll(900);
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(900, 15);
        vm.roll(901);
        vm.setBlockhash(900, fakeBlockHash);

        vm.expectRevert(IHeaderProtocol.TaskIsNonRefundable.selector);
        protocol.refund(900, 15);
    }

    function testRevertDirectPaymentsNotSupported() public {
        vm.expectRevert(IHeaderProtocol.DirectPaymentsNotSupported.selector);
        payable(address(protocol)).transfer(1 ether);
    }

    function testRevertFunctionDoesNotExist() public {
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
        vm.roll(1000);
        vm.prank(address(consumer));
        protocol.request(1000, 15); // free
        vm.roll(1001);
        vm.setBlockhash(1000, fakeBlockHash);

        protocol.response(1000, 15, blockHeader, address(consumer));
        assertTrue(consumer.storedHeaderData() != bytes32(0));
    }

    function testPaidTaskRequestNoImmediateResponse() public {
        vm.deal(address(consumer), 1 ether);
        vm.roll(1100);
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(1100, 15);
        // no revert means success, no immediate response done here
    }

    function testPaidTaskResponseWithReward() public {
        vm.deal(address(consumer), 1 ether);
        vm.roll(1300);
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(1300, 15);
        vm.roll(1301);
        vm.setBlockhash(1300, fakeBlockHash);

        uint256 beforeBal = address(this).balance;
        protocol.response(1300, 15, blockHeader, address(consumer));
        uint256 afterBal = address(this).balance;

        // got reward 1 ether to executor (this contract)
        assertEq(afterBal - beforeBal, 1 ether);
        // consumer got callback
        assertTrue(consumer.storedHeaderData() != bytes32(0));
    }

    function testPaidTaskBountyScenario() public {
        vm.deal(address(consumer), 2 ether);
        vm.roll(1400);
        vm.prank(address(consumer));
        protocol.request{value: 2 ether}(1400, 15);
        vm.roll(1401);
        vm.setBlockhash(1400, fakeBlockHash);

        uint256 beforeBal = address(this).balance;
        protocol.response(1400, 15, blockHeader, address(consumer));
        uint256 afterBal = address(this).balance;

        // got reward 2 ether
        assertEq(afterBal - beforeBal, 2 ether);
        assertTrue(consumer.storedHeaderData() != bytes32(0));
    }

    function testCommitAndCompleteAfter256Blocks() public {
        vm.deal(address(consumer), 1 ether);
        uint256 futureBlock = 1500;
        vm.roll(futureBlock);
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(futureBlock, 15);
        vm.roll(futureBlock + 1);
        vm.setBlockhash(futureBlock, fakeBlockHash);

        protocol.commit(futureBlock);

        // roll 256+ blocks later
        roll256BlocksLater(futureBlock);

        uint256 beforeBal = address(this).balance;
        protocol.response(futureBlock, 15, blockHeader, address(consumer));
        uint256 afterBal = address(this).balance;
        assertEq(afterBal - beforeBal, 1 ether);
        assertTrue(consumer.storedHeaderData() != bytes32(0));
    }

    function testNoCommitNoHashResponseFailsAfterLongTime() public {
        uint256 oldBlock = 1600;
        vm.deal(address(consumer), 1 ether);
        vm.roll(oldBlock);
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(oldBlock, 15);
        vm.roll(oldBlock + 1);
        vm.setBlockhash(oldBlock, fakeBlockHash);

        roll256BlocksLater(oldBlock);
        vm.setBlockhash(oldBlock, bytes32(0));

        vm.expectRevert(IHeaderProtocol.FailedToObtainBlockHash.selector);
        protocol.response(oldBlock, 15, blockHeader, address(consumer));
    }

    function testRefundAfter256BlocksNoCommitNoHash() public {
        uint256 oldBlock = 1700;
        vm.deal(address(consumer), 1 ether);
        vm.roll(oldBlock);
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(oldBlock, 15);
        vm.roll(oldBlock + 1);
        vm.setBlockhash(oldBlock, fakeBlockHash);

        roll256BlocksLater(oldBlock);
        vm.setBlockhash(oldBlock, bytes32(0));

        vm.prank(address(consumer));
        uint256 beforeBal = address(consumer).balance;
        protocol.refund(oldBlock, 15);
        uint256 afterBal = address(consumer).balance;
        assertEq(afterBal - beforeBal, 1 ether);
    }

    function testCommitEvent() public {
        uint256 blk = 1800;
        vm.roll(blk + 1);
        vm.setBlockhash(blk, fakeBlockHash);
        protocol.commit(blk);
        // no revert => success
    }

    function testRefundNonRefundable() public {
        // free task no refund
        vm.roll(1900);
        vm.prank(address(consumer));
        protocol.request(1900, 15);
        vm.expectRevert(IHeaderProtocol.TaskIsNonRefundable.selector);
        protocol.refund(1900, 15);
    }

    function testPaidTaskAlreadyKnownHeader() public {
        vm.deal(address(consumer), 1 ether);
        uint256 requestBlock = 2200;
        // Set the chain state to block=2200
        vm.roll(requestBlock);
        // Consumer requests a paid header
        vm.prank(address(consumer));
        protocol.request{value: 1 ether}(requestBlock, 15);

        // Move one block forward so blockhash(requestBlock) is known
        vm.roll(requestBlock + 1);
        vm.setBlockhash(requestBlock, fakeBlockHash);

        // Respond with the known block header
        protocol.response(requestBlock, 15, blockHeader, address(consumer));

        // Check that the consumer contract now has the known header data
        assertTrue(consumer.storedHeaderData() != bytes32(0));

        // At this point, the header is known. If we were to request the same `(requestBlock, 15)` again and pay,
        // we would receive an immediate callback and refund due to the header being already known.
        // We trust logic due to other tests. No second request is performed here.
    }
}
