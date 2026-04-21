// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PredictEarn.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PredictEarnTest is Test {
    PredictEarn public predictearn;
    MockERC20   public cusd;

    address owner = address(this);
    address alice = address(0xA);

    function setUp() public {
        cusd = new MockERC20();
        predictearn = new PredictEarn(address(cusd));
    }

    function testRegisterMatch() public {
        predictearn.registerMatch(
            "match-001",
            "Liverpool vs Chelsea",
            block.timestamp + 1 days
        );
        assertEq(predictearn.getMatchCount(), 1);
    }
}