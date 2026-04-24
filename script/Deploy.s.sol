// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PredictEarn.sol";

contract DeployPredictEarn is Script {

    function run() external {
        address cUSD = vm.envAddress("CUSD_MAINNET"); 
        vm.startBroadcast();
        PredictEarn predictearn = new PredictEarn(cUSD);
        console.log("Sample match 1: Bayern vs Leverkusen");
        console.log("Sample match 2: Dortmund vs Leipzig");
        console.log("Sample match 3: Frankfurt vs Stuttgart");
        vm.stopBroadcast();
        console.log("PredictEarn deployed at:", address(predictearn));
    }
    
}