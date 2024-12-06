// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HeaderProtocol} from "@headerprotocol/contracts/v1/HeaderProtocol.sol";

contract HeaderProtocolScript is Script {
    HeaderProtocol public headerProtocol;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        headerProtocol = new HeaderProtocol();

        vm.stopBroadcast();
    }
}
