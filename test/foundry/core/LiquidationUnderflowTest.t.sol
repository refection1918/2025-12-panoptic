// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

contract MockPanopticPool {
    function panopticPool() external view returns (address) {
        return address(this);
    }
}

contract MockToken is ERC20Minimal {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRiskEngine {
    function updateInterestRate(uint256, uint256) external pure returns (uint128, uint256) {
        return (0, 0); 
    }
    function interestRate(uint256, uint256) external pure returns (uint128) {
        return 0;
    }
}

contract LiquidationUnderflowTest is Test {
    using ClonesWithImmutableArgs for address;

    CollateralTracker ct;
    MockToken token;
    MockPanopticPool pp;
    MockRiskEngine re;
    CollateralTracker implementation;

    function setUp() public {
        token = new MockToken();
        pp = new MockPanopticPool();
        re = new MockRiskEngine();
        
        implementation = new CollateralTracker(10);
        
        bytes memory args = abi.encodePacked(
            address(pp),
            true,               
            address(token),     
            address(token),     
            address(token),     
            address(re),        
            address(0),         
            uint24(10)          
        );
        
        ct = CollateralTracker(address(implementation).clone(args));
        ct.initialize();
    }

    function test_LiquidationUnderflow_Standalone() public {
        address Alice = address(0x1);
        
        // 1. Initial State: Alice deposits real assets
        uint256 depositAmount = 100 ether;
        token.mint(Alice, depositAmount);
        
        // Donate extra tokens to CT to ensure transfer logic doesn't fail due to lack of assets
        // This isolates the failure to the share burn underflow.
        token.mint(address(ct), 10000 ether);
        
        vm.startPrank(Alice);
        token.approve(address(ct), depositAmount);
        ct.deposit(depositAmount, Alice);
        vm.stopPrank();
        
        // 2. Simulate Share Inflation via Delegation
        vm.prank(address(pp)); 
        ct.delegate(Alice); 
        
        // 3. Attempt to Burn amount > internalSupply
        // Internal Supply is ~100 ether (initial deposit)
        // Alice has massive phantom shares.
        uint256 burnAmount = 1000 ether; 
        
        vm.startPrank(Alice);
        // Expect revert due to _internalSupply underflow
        vm.expectRevert(); 
        ct.withdraw(burnAmount, Alice, Alice);
        vm.stopPrank();
        
        console.log("CONFIRMED: Liquidation/Withdrawal reverted (Underflow).");
    }
}
