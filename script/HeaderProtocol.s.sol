// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HeaderProtocol} from "@headerprotocol/contracts/v1/HeaderProtocol.sol";

contract HeaderProtocolScript is Script {
    HeaderProtocol private headerProtocol;

    function setUp() external {
        vm.startBroadcast();

        headerProtocol = new HeaderProtocol();

        vm.stopBroadcast();
    }

    function run() public {}
}
