// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HeaderProtocol} from "@headerprotocol/contracts/v1/HeaderProtocol.sol";
import {IHeader} from "@headerprotocol/contracts/v1/interfaces/IHeader.sol";

contract MockRequester is IHeader {
    bytes public lastReceivedHeader;
    uint256 public lastReceivedBlock;

    function responseBlockHeader(
        uint256 blockNumber,
        bytes calldata header
    ) external {
        lastReceivedBlock = blockNumber;
        lastReceivedHeader = header;
    }
}

contract MockRequesterReentrant is IHeader {
    HeaderProtocol public protocol;
    uint256 public attemptReentrancyBlock;
    bytes public lastReceivedHeader;
    uint256 public lastReceivedBlock;

    constructor(HeaderProtocol _protocol, uint256 _reentrancyBlock) {
        protocol = _protocol;
        attemptReentrancyBlock = _reentrancyBlock;
    }

    function responseBlockHeader(
        uint256 blockNumber,
        bytes calldata header
    ) external {
        lastReceivedBlock = blockNumber;
        lastReceivedHeader = header;
        // Attempt reentrancy if matches desired block
        if (blockNumber == attemptReentrancyBlock) {
            // This should trigger ReentrantCall if not properly guarded
            protocol.response(blockNumber, header, address(this));
        }
    }
}

contract MockResponderRevertsOnReceive {
    // If this contract tries to receive Ether, it reverts
    receive() external payable {
        revert("No receive");
    }
    fallback() external payable {
        revert("No fallback");
    }
}

contract HeaderProtocolTest is Test {
    HeaderProtocol internal headerProtocol;
    MockRequester internal requester;
    MockResponderRevertsOnReceive internal revertOnReceive;
    address internal eoa;
    bytes internal dummyHeader;

    function setUp() external {
        headerProtocol = new HeaderProtocol();
        requester = new MockRequester();
        revertOnReceive = new MockResponderRevertsOnReceive();
        eoa = address(0x123);
        dummyHeader = hex"1234";
    }

    // Utility: Compute storage keys for headers mapping
    function getHeadersBaseSlot(
        uint256 blockNumber
    ) internal pure returns (bytes32) {
        // headers is the first state var, slot = 0
        // key = keccak256(abi.encode(blockNumber, uint256(0)))
        return keccak256(abi.encode(blockNumber, uint256(0)));
    }

    function storeHeader(
        uint256 blockNumber,
        address _requester,
        uint256 _reward,
        bytes memory _header
    ) internal {
        bytes32 base = getHeadersBaseSlot(blockNumber);

        // StoredHeader layout:
        // slot(base): requester (address) and part of struct packing if any
        // slot(base+1): reward (uint256)
        // header bytes:
        // header slot = keccak256(base) for dynamic array
        bytes32 headerSlot = keccak256(abi.encode(base));

        // Store requester
        vm.store(
            address(headerProtocol),
            base,
            bytes32(uint256(uint160(_requester)))
        );

        // Store reward
        vm.store(
            address(headerProtocol),
            bytes32(uint256(base) + 1),
            bytes32(_reward)
        );

        // Store header length
        uint256 len = _header.length;
        vm.store(address(headerProtocol), headerSlot, bytes32(len));

        // Store header content
        if (len > 0) {
            bytes32 contentSlot = bytes32(uint256(headerSlot) + 1);
            // For short headers <= 32 bytes, we can store in one slot
            bytes32 data;
            assembly {
                data := mload(add(_header, 32))
            }
            // Mask data to length
            uint256 mask = (len < 32) ? (256 ** (32 - len) - 1) : 0;
            if (mask != 0) {
                data = (data & ~bytes32(mask));
            }
            vm.store(address(headerProtocol), contentSlot, data);
        }
    }

    // Test reverts and edge cases in request()
    function test_Request_FromEOA_ShouldRevert() external {
        vm.prank(eoa);
        vm.expectRevert(HeaderProtocol.OnlyContracts.selector);
        headerProtocol.request(100);
    }

    function test_Request_InvalidBlockNumber() external {
        vm.expectRevert(HeaderProtocol.InvalidBlockNumber.selector);
        headerProtocol.request(0);
    }

    function test_Request_OlderThan256Blocks_NoPreStoredHeader_ShouldRevert()
        external
    {
        vm.roll(block.number + 300);
        // old block definitely out of range
        vm.expectRevert(HeaderProtocol.OutOfRecentBlockRange.selector);
        headerProtocol.request(1);
    }

    function test_Request_ValidFromContract_NoReward() external {
        uint256 bn = block.number;
        headerProtocol.request(bn);
        (
            address storedRequester,
            bytes memory storedHeader,
            uint256 storedReward
        ) = headerProtocol.headers(bn);
        assertEq(storedRequester, address(0), "No requester stored");
        assertEq(storedHeader.length, 0, "No header stored");
        assertEq(storedReward, 0, "No reward stored");
    }

    function test_Request_ValidFromContract_WithReward() external {
        uint256 bn = block.number;
        headerProtocol.request{value: 1 ether}(bn);
        (
            address storedRequester,
            bytes memory storedHeader,
            uint256 storedReward
        ) = headerProtocol.headers(bn);
        assertEq(storedRequester, address(this), "Requester stored");
        assertEq(storedHeader.length, 0, "No header yet");
        assertEq(storedReward, 1 ether, "Reward set");
    }

    // Test response() error paths
    function test_Response_InvalidBlockNumber() external {
        vm.expectRevert(HeaderProtocol.InvalidBlockNumber.selector);
        headerProtocol.response(0, hex"01", address(requester));
    }

    function test_Response_OutOfRangeBlock() external {
        vm.roll(500);
        vm.expectRevert(HeaderProtocol.OutOfRecentBlockRange.selector);
        headerProtocol.response(200, hex"1234", address(requester));
    }

    function test_Response_HeaderIsEmpty() external {
        uint256 bn = block.number;
        headerProtocol.request(bn);
        vm.expectRevert(HeaderProtocol.HeaderIsEmpty.selector);
        headerProtocol.response(bn, "", address(requester));
    }

    function test_Response_FailedToObtainBlockHash() external {
        uint256 bn = block.number;
        headerProtocol.request(bn);
        // blockhash(bn) == 0 here because bn == current block
        vm.expectRevert(HeaderProtocol.FailedToObtainBlockHash.selector);
        headerProtocol.response(bn, hex"1234", address(requester));
    }

    function test_Response_HeaderHashMismatch() external {
        vm.roll(block.number + 1);
        uint256 bn = block.number - 1;
        headerProtocol.request(bn);
        vm.expectRevert(HeaderProtocol.HeaderHashMismatch.selector);
        headerProtocol.response(bn, hex"deadbeef", address(requester));
    }

    // Test fallback & receive
    function test_DirectPaymentsNotSupported() external {
        vm.expectRevert(HeaderProtocol.DirectPaymentsNotSupported.selector);
        (bool success, ) = address(headerProtocol).call{value: 1 ether}("");
        success; // revert expected
    }

    function test_CallNonExistentFunction() external {
        vm.expectRevert(HeaderProtocol.FunctionDoesNotExist.selector);
        (bool success, ) = address(headerProtocol).call(
            abi.encodeWithSignature("nonExistentFunction()")
        );
        success;
    }

    function test_Response_WithoutRequest_ShouldJustVerifyInputs() external {
        vm.expectRevert(HeaderProtocol.InvalidBlockNumber.selector);
        headerProtocol.response(0, hex"011a0a", address(requester));
    }

    // // Now test success scenarios by simulating a stored header to skip hash checks

    // // Success scenario without reward:
    // // 1) Request a block
    // // 2) Simulate a successful response by storing a header directly.
    // // 3) Call response again with a different requester, should return stored header immediately.
    // function test_Response_SuccessNoReward() external {
    //     uint256 bn = block.number + 10; // arbitrary
    //     headerProtocol.request(bn); // no reward

    //     // Simulate that a correct header was already provided:
    //     storeHeader(bn, address(0), 0, dummyHeader);

    //     // Another requester tries to get this header
    //     MockRequester anotherReq = new MockRequester();
    //     headerProtocol.response(bn, hex"696e76616c6964", address(anotherReq));
    //     assertEq(anotherReq.lastReceivedBlock(), bn, "Got stored header");
    //     assertEq(
    //         anotherReq.lastReceivedHeader(),
    //         dummyHeader,
    //         "Stored header returned"
    //     );
    // }

    // // Success scenario with reward:
    // // 1) Request with reward
    // // 2) Simulate stored header and reward
    // // 3) Call response from a responder contract to get paid
    // function test_Response_SuccessWithReward() external {
    //     uint256 bn = block.number + 20;
    //     headerProtocol.request{value: 1 ether}(bn);

    //     // Simulate a verified header is already stored:
    //     storeHeader(bn, address(this), 1 ether, dummyHeader);

    //     // Now call response from a different address:
    //     address responder = address(0xabc);
    //     vm.deal(address(headerProtocol), 1 ether); // ensure contract has the reward
    //     vm.startPrank(responder);
    //     uint256 balanceBefore = responder.balance;
    //     headerProtocol.response(bn, hex"1122", address(requester));
    //     uint256 balanceAfter = responder.balance;
    //     vm.stopPrank();

    //     assertEq(balanceAfter, balanceBefore + 1 ether, "Responder got paid");
    //     assertEq(requester.lastReceivedBlock(), bn, "Requester got the header");
    //     assertEq(
    //         requester.lastReceivedHeader(),
    //         dummyHeader,
    //         "Correct stored header"
    //     );
    // }

    // // FailedToSendEther scenario:
    // // If responder reverts on receive:
    // // We'll simulate stored header with a reward and try to respond from revertOnReceive
    // function test_Response_FailedToSendEther() external {
    //     uint256 bn = block.number + 30;
    //     headerProtocol.request{value: 1 ether}(bn);

    //     // Simulate stored header and reward
    //     storeHeader(bn, address(this), 1 ether, dummyHeader);
    //     vm.deal(address(headerProtocol), 1 ether);

    //     vm.startPrank(address(revertOnReceive));
    //     vm.expectRevert(HeaderProtocol.FailedToSendEther.selector);
    //     headerProtocol.response(bn, dummyHeader, address(requester));
    //     vm.stopPrank();
    // }

    // // AlreadyStoredHeader scenario:
    // // Covered by test_Response_SuccessNoReward. But let's show old block scenario:
    // function test_Response_OldBlockWithStoredHeader() external {
    //     uint256 bn = block.number + 40;
    //     headerProtocol.request{value: 1 ether}(bn);

    //     storeHeader(bn, address(this), 1 ether, dummyHeader);
    //     vm.deal(address(headerProtocol), 1 ether);

    //     // Advance over 256 blocks
    //     vm.roll(block.number + 300);

    //     // Another requester tries to get header:
    //     MockRequester anotherReq = new MockRequester();
    //     headerProtocol.response(bn, hex"112233", address(anotherReq));
    //     assertEq(anotherReq.lastReceivedBlock(), bn);
    //     assertEq(anotherReq.lastReceivedHeader(), dummyHeader);
    // }

    // // ReentrantCall scenario:
    // // If `responseBlockHeader` calls `response()` again on same block, it should revert.
    // // We'll simulate stored header so no hash check is needed.
    // function test_Response_ReentrantCall() external {
    //     uint256 bn = block.number + 50;
    //     headerProtocol.request(bn);
    //     // Simulate stored header
    //     storeHeader(bn, address(this), 0, dummyHeader);

    //     MockRequesterReentrant reentrantReq = new MockRequesterReentrant(
    //         headerProtocol,
    //         bn
    //     );
    //     vm.expectRevert(HeaderProtocol.ReentrantCall.selector);
    //     headerProtocol.response(bn, hex"4455", address(reentrantReq));
    // }

    // // Cover the scenario where a stored header with no reward triggers the else branch:
    // // Already tested in test_Response_SuccessNoReward, but that scenario had no reward.
    // // Let's explicitly test an already stored header with no reward:
    // function test_Response_StoredHeader_NoRewardAgain() external {
    //     uint256 bn = block.number + 60;
    //     headerProtocol.request(bn); // no reward
    //     storeHeader(bn, address(this), 0, dummyHeader);

    //     // Respond again from a random address
    //     address someAddr = address(0xdead);
    //     vm.startPrank(someAddr);
    //     headerProtocol.response(bn, hex"1122", address(requester));
    //     vm.stopPrank();

    //     assertEq(requester.lastReceivedBlock(), bn);
    //     assertEq(requester.lastReceivedHeader(), dummyHeader);
    // }

    // // Another test for stored header with reward already given out:
    // // After first payout, no second payout occurs, but we still get the header.
    // // Simulate the scenario where reward was paid out (set reward=0 after)
    // function test_Response_StoredHeader_AfterPayout() external {
    //     uint256 bn = block.number + 70;
    //     // Suppose initially requested with reward:
    //     headerProtocol.request{value: 1 ether}(bn);

    //     // Simulate a scenario after payout: header stored, reward=0
    //     storeHeader(bn, address(this), 0, dummyHeader);

    //     // Now responding again should just return the header, no payment
    //     uint256 balanceBefore = address(this).balance;
    //     headerProtocol.response(bn, hex"5566", address(requester));
    //     uint256 balanceAfter = address(this).balance;
    //     assertEq(balanceAfter, balanceBefore, "No additional payment");
    //     assertEq(requester.lastReceivedBlock(), bn);
    //     assertEq(requester.lastReceivedHeader(), dummyHeader);
    // }

    receive() external payable {}
}
