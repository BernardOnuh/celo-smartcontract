// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PredictEarn.sol";

/// @notice Deploy PredictEarn to Celo mainnet or Alfajores testnet.
///
/// Usage (Alfajores):
///   forge script script/Deploy.s.sol \
///     --rpc-url $ALFAJORES_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast --verify \
///     --verifier-url https://api-alfajores.celoscan.io/api \
///     --etherscan-api-key $CELOSCAN_API_KEY
///
/// Usage (mainnet):
///   forge script script/Deploy.s.sol \
///     --rpc-url $CELO_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast --verify \
///     --etherscan-api-key $CELOSCAN_API_KEY
contract DeployPredictEarn is Script {
    function run() external returns (PredictEarn pe) {
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        require(feeRecipient != address(0), "Deploy: FEE_RECIPIENT not set");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        pe = new PredictEarn(feeRecipient);
        vm.stopBroadcast();

        console2.log("PredictEarn deployed at:", address(pe));
        console2.log("Admin:                  ", pe.admin());
        console2.log("Fee recipient:          ", pe.feeRecipient());
    }
}
