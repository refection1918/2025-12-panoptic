// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {MarketState} from "@types/MarketState.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract CollateralTrackerHarness is CollateralTracker {
    constructor(uint256 fee) CollateralTracker(fee) {}
    
    // Helper to expose internal state
    function getMarketState() external view returns (uint256 index, uint256 epoch, uint256 raw) {
        index = s_marketState.borrowIndex();
        epoch = s_marketState.marketEpoch();
        raw = MarketState.unwrap(s_marketState);
    }

    function forceAssetsInAMM(uint128 amount) external {
        s_assetsInAMM = amount;
    }
}

contract BorrowIndexOverflowTest is Test {
    // using stdStorage for StdStorage; // Not needed
    CollateralTrackerHarness ct;
    
    function setUp() public {
        // Deploy Harness (riskEngine/panopticPool will be address(0))
        ct = new CollateralTrackerHarness(0);
        ct.initialize();
        
        // Force assets in AMM to allow interest accrual
        ct.forceAssetsInAMM(uint128(1e18));
    }
    
    function test_BorrowIndexOverflow() public {
        // Set rate to 100% per second (1e18)
        // We want to reach > 2^80 (~1.2e24)
        // Start index = 1e18.
        // Needs multiplier ~1.2e6 (e^14).
        // Time = 20 seconds -> e^20 ~ 4.8e8 multiplier.
        // Result ~4.8e26. Fits in uint128 (max 3.4e38). Overflow uint80.
        
        uint128 rate = 1e20; 
        
        // Mock RiskEngine returns
        vm.mockCall(address(0), abi.encodeWithSelector(IRiskEngine.interestRate.selector), abi.encode(rate));
        vm.mockCall(address(0), abi.encodeWithSelector(IRiskEngine.updateInterestRate.selector), abi.encode(rate, 0));
        
        // Initial State
        (uint256 idx, uint256 ep, ) = ct.getMarketState();
        console.log("Initial Index:", idx);
        console.log("Initial Epoch:", ep);
        
        // Warp time
        vm.warp(block.timestamp + 20);
        
        // Accrue Interest
        // This will call address(0).updateInterestRate
        ct.accrueInterest();
        
        (uint256 newIdx, uint256 newEp, uint256 raw) = ct.getMarketState();
        console.log("New Index:", newIdx);
        console.log("New Epoch:", newEp);
        console.log("Raw:", raw);
        
        uint256 expectedEpoch = block.timestamp >> 2;
        console.log("Expected Epoch:", expectedEpoch);
        
        // Check for corruption
        // If borrowIndex overflowed uint80, it would increment epoch
        if (newEp > expectedEpoch + 1000) {
            console.log("VULNERABILITY CONFIRMED: Epoch Corrupted by Index Overflow");
            console.log("Diff:", newEp - expectedEpoch);
        } else {
             console.log("Epoch valid.");
        }
        
        require(newEp <= expectedEpoch + 1000, "Epoch corrupted");
    }
}
