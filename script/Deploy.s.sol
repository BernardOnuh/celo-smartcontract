// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PredictEarn.sol";

contract DeployPredictEarn is Script {

    function run() external {
        address cUSD = vm.envAddress("CUSD_MAINNET"); 
        vm.startBroadcast();
        PredictEarn predictearn = new PredictEarn(cUSD);
        console.log("Sample match 1: Barcelona vs Atletico");
        console.log("Sample match 2: Real Madrid vs Sevilla");
        console.log("Sample match 3: Valencia vs Villarreal");
        vm.stopBroadcast();
        console.log("PredictEarn deployed at:", address(predictearn));
    }
    
}