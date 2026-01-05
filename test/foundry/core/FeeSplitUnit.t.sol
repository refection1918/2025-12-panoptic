// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";

// Harness contract to expose internal constants
contract HarnessRiskEngine is RiskEngine {
    constructor() RiskEngine(0, 0, msg.sender, msg.sender) {}

    function getSplits() external pure returns (uint16 pSplit, uint16 bSplit) {
        pSplit = PROTOCOL_SPLIT;
        bSplit = BUILDER_SPLIT;
    }
}

contract FeeSplitUnit is Test {
    HarnessRiskEngine public splitChecker;
    uint256 constant DECIMALS = 10_000;

    function setUp() public {
        splitChecker = new HarnessRiskEngine();
    }

    function test_VerifyFeeSplitLeak() public {
        console2.log("=== Panoptic Fee Split Verification (Via Constant Inspection) ===");
        
        (uint16 protocolSplit, uint16 builderSplit) = splitChecker.getSplits();
        
        console2.log("Protocol Split (bps):", protocolSplit);
        console2.log("Builder Split (bps): ", builderSplit);
        
        uint256 totalSplit = uint256(protocolSplit) + uint256(builderSplit);
        console2.log("Total Split (bps):   ", totalSplit);
        console2.log("DECIMALS (bps):      ", DECIMALS);
        
        uint256 uncollected = DECIMALS - totalSplit;
        console2.log("Uncollected (bps):   ", uncollected);
        
        uint256 leakPercentage = (uncollected * 100) / DECIMALS;
        console2.log("Revenue Leak (%):    ", leakPercentage);
        
        if (uncollected > 0) {
            console2.log("VULNERABILITY CONFIRMED: Fee split sums to less than 100%.");
        } else {
            console2.log("Status: No leaks detected.");
        }
        
        assertLt(totalSplit, DECIMALS, "Total split should be less than 100%");
        // assertEq(leakPercentage, 10); // User claims 5%, let's see which one it is.
    }
}
