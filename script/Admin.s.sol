// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PredictEarn.sol";

/// @notice Interactive admin helpers — run individual functions via env vars.
///
/// Create a match:
///   PREDICT_EARN=<addr> ACTION=create forge script script/Admin.s.sol \
///     --rpc-url $CELO_RPC_URL --private-key $PRIVATE_KEY --broadcast
///
/// Resolve a match:
///   PREDICT_EARN=<addr> ACTION=resolve MATCH_IDX=0 OUTCOME=1 forge script ...
///
/// Withdraw fees:
///   PREDICT_EARN=<addr> ACTION=fees forge script ...
contract AdminScript is Script {
    function run() external {
        address peAddr = vm.envAddress("PREDICT_EARN");
        string  memory action = vm.envString("ACTION");
        uint256 deployerKey   = vm.envUint("PRIVATE_KEY");
        PredictEarn pe        = PredictEarn(peAddr);

        vm.startBroadcast(deployerKey);

        if (_eq(action, "create")) {
            PredictEarn.CreateMatchParams memory p = PredictEarn.CreateMatchParams({
                matchId:      vm.envString("MATCH_ID"),
                homeTeam:     vm.envString("HOME_TEAM"),
                awayTeam:     vm.envString("AWAY_TEAM"),
                league:       vm.envString("LEAGUE"),
                commenceTime: vm.envUint("COMMENCE_TIME"),
                homeOddBP:    vm.envUint("HOME_ODD_BP"),
                drawOddBP:    vm.envUint("DRAW_ODD_BP"),
                awayOddBP:    vm.envUint("AWAY_ODD_BP")
            });
            uint256 idx = pe.createMatch(p);
            console2.log("Match created at index:", idx);
        }

        else if (_eq(action, "close")) {
            uint256 idx = vm.envUint("MATCH_IDX");
            pe.closeMatch(idx);
            console2.log("Match closed:", idx);
        }

        else if (_eq(action, "resolve")) {
            uint256 idx     = vm.envUint("MATCH_IDX");
            uint8   outcome = uint8(vm.envUint("OUTCOME")); // 1=HOME 2=DRAW 3=AWAY
            pe.resolveMatch(idx, PredictEarn.Outcome(outcome));
            console2.log("Match resolved:", idx, "outcome:", outcome);
        }

        else if (_eq(action, "cancel")) {
            uint256 idx = vm.envUint("MATCH_IDX");
            pe.cancelMatch(idx);
            console2.log("Match cancelled:", idx);
        }

        else if (_eq(action, "fees")) {
            uint256 before = pe.totalFeesCollected();
            pe.withdrawFees();
            console2.log("Withdrew fees (wei):", before);
        }

        else if (_eq(action, "approve_waitlist")) {
            address wallet = vm.envAddress("WALLET");
            pe.approveWaitlist(wallet);
            console2.log("Approved:", wallet);
        }

        else {
            revert(string.concat("AdminScript: unknown action '", action, "'"));
        }

        vm.stopBroadcast();
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
