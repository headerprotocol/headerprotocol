// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HeaderProtocol} from "@headerprotocol/contracts/v1/HeaderProtocol.sol";

// PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

// forge script \
//    --broadcast \
//    --rpc-url http://127.0.0.1:8545 \
//    --private-key $PK \
//    script/HeaderProtocol.s.sol

// OR

// forge create \
//    --broadcast \
//    --rpc-url http://127.0.0.1:8545 \
//    --private-key $PK \
//    contracts/v1/HeaderProtocol.sol:HeaderProtocol

contract HeaderProtocolScript is Script {
    HeaderProtocol private headerProtocol;

    function setUp() external {
        vm.startBroadcast();

        headerProtocol = new HeaderProtocol();

        vm.stopBroadcast();
    }

    function run() public {}
}
