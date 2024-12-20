#!/bin/bash

# anvil

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Config
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
HEADER_INDEX=15

# Deploy HeaderProtocol
HEADER_PROTOCOL=$(forge create --private-key $PRIVATE_KEY contracts/v1/HeaderProtocol.sol:HeaderProtocol --broadcast | grep "Deployed to" | awk '{print $3}')
echo "HeaderProtocol deployed at: $HEADER_PROTOCOL"

# Deploy MockHeader 1
MOCK_HEADER1=$(forge create --private-key $PRIVATE_KEY contracts/v1/mocks/MockHeader.sol:MockHeader --broadcast --constructor-args $HEADER_PROTOCOL | grep "Deployed to" | awk '{print $3}')
echo "MockHeader 1 deployed at: $MOCK_HEADER1"

# Deploy MockHeader 2
MOCK_HEADER2=$(forge create --private-key $PRIVATE_KEY contracts/v1/mocks/MockHeader.sol:MockHeader --broadcast --constructor-args $HEADER_PROTOCOL | grep "Deployed to" | awk '{print $3}')
echo "MockHeader 2 deployed at: $MOCK_HEADER2"

for i in {0..10}; do cast rpc evm_mine --rpc-url http://127.0.0.1:8545; done > /dev/null

read -p "Press enter to Request"

# Request Block Header
cast send --private-key $PRIVATE_KEY $MOCK_HEADER1 "mockRequest(uint256,uint256)" 20 $HEADER_INDEX

for i in {0..10}; do cast rpc evm_mine --rpc-url http://127.0.0.1:8545; done > /dev/null

read -p "Press enter to Commit"

# Commit Block
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "commit(uint256)" 20

eval $(python3 "$SCRIPT_DIR/fetch_block_data.py" 20)

read -p "Press enter to Respond"

# Respond to Block Header
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "response(uint256,uint256,bytes,address)" 20 $HEADER_INDEX $BLOCK_HEADER_HEX $MOCK_HEADER1

read -p "Press enter to Request"

for i in {0..10}; do cast rpc evm_mine --rpc-url http://127.0.0.1:8545; done > /dev/null

# Request Another Block Header
cast send --private-key $PRIVATE_KEY $MOCK_HEADER1 "mockRequest(uint256,uint256)" 50 1 --value 1000000000000000000

for i in {0..300}; do cast rpc evm_mine --rpc-url http://127.0.0.1:8545; done > /dev/null

read -p "Press enter to Refund"

# Refund Task
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "refund(uint256,uint256)" 50 1

read -p "Press enter to Respond"

eval $(python3 "$SCRIPT_DIR/fetch_block_data.py" 300)

# Respond to Block Header
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "response(uint256,uint256,bytes,address)" 300 1 $BLOCK_HEADER_HEX $MOCK_HEADER1

# Respond to Block Header
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "response(uint256,uint256,bytes,address)" 300 1 $BLOCK_HEADER_HEX $MOCK_HEADER2

# Respond to Block Header
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "response(uint256,uint256,bytes,address)" 300 1 $BLOCK_HEADER_HEX $MOCK_HEADER1

read -p "Press enter to Commit"

# Commit Block
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "commit(uint256)" 310

read -p "Press enter to Respond"

eval $(python3 "$SCRIPT_DIR/fetch_block_data.py" 310)

# Respond to Block Header
cast send --private-key $PRIVATE_KEY $HEADER_PROTOCOL "response(uint256,uint256,bytes,address)" 310 1 $BLOCK_HEADER_HEX $MOCK_HEADER1
