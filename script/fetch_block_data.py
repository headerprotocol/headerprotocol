import sys
import rlp # pip install rlp
from hexbytes import HexBytes
from eth_hash.auto import keccak
from web3 import Web3 # pip install web3

# Connect to local Anvil blockchain
anvil_url = "http://127.0.0.1:8545"  # Replace with your Anvil URL if different
web3 = Web3(Web3.HTTPProvider(anvil_url))

if not web3.is_connected():
    print("Failed to connect to Anvil")
    exit()

# Fetch block X data
block_number = int(sys.argv[1])
block = web3.eth.get_block(block_number)

# Extract block header fields
block_header = [
    HexBytes(block["parentHash"]),           # parentHash
    HexBytes(block["sha3Uncles"]),           # sha3Uncles
    HexBytes(block["miner"]),                # miner
    HexBytes(block["stateRoot"]),            # stateRoot
    HexBytes(block["transactionsRoot"]),     # transactionsRoot
    HexBytes(block["receiptsRoot"]),         # receiptsRoot
    HexBytes(block["logsBloom"]),            # logsBloom
    block["difficulty"],                     # difficulty
    block["number"],                         # number
    block["gasLimit"],                       # gasLimit
    block["gasUsed"],                        # gasUsed
    block["timestamp"],                      # timestamp
    HexBytes(block["extraData"]),            # extraData
    HexBytes(block["mixHash"]),              # mixHash
    HexBytes(block["nonce"]),                # nonce
    block.get("baseFeePerGas", 0),           # baseFeePerGas (default to 0 if not present)
    HexBytes(block.get("withdrawalsRoot", b"0x")),  # withdrawalsRoot (default to empty)
    block.get("blobGasUsed", 0),             # blobGasUsed (default to 0)
    block.get("excessBlobGas", 0),           # excessBlobGas (default to 0)
    HexBytes(block.get("parentBeaconBlockRoot", b"0x")),  # parentBeaconBlockRoot (default to empty)
]

# RLP encoding
encoded_header = rlp.encode(block_header)

# Compute blockhash
blockhash = keccak(encoded_header)

print(f"FAKE_BLOCK_HASH=0x{blockhash.hex()}")
print(f"BLOCK_HEADER_HEX={encoded_header.hex()}")

# anvil
# python script/fetch_block_data.py

# FAKE_BLOCK_HASH=f90240a01b12b28af0b296cf01ff9ad801f63effc30ab05b9f64eef5d2e018b4e03eade5a01dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347940000000000000000000000000000000000000000a096803c87abde96ff3834f26d08b9212d1e8dd351b8fcb7436c69c828821ad230a0c884ea4887aa8a9a4be3d8e65daf9181cc4a171fce8ac444a0dd90d48747b413a01aa8fd324feaba437626709c17ef79bd1cba1bdb4a787cb1f4dae6135c78a466b901000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002100000000000800004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000020000200000000000000000004000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000080058401c9c38082afd3846764a52780a00000000000000000000000000000000000000000000000000000000000000000880000000000000000842359f045a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b4218080a00000000000000000000000000000000000000000000000000000000000000000
# BLOCK_HEADER_HEX=bee5846ddfad41f67406b3bf9c9c27349235abf42c1ac9036384d2edf61ebee9