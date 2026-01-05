// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {Math} from "@libraries/Math.sol";

/// @title Harness to expose internal _computeBuilderWallet function
contract HarnessRiskEngine is RiskEngine {
    using Math for uint256;
    
    constructor() RiskEngine(0, 0, msg.sender, msg.sender) {}

    /// @notice Exposes the internal _computeBuilderWallet function for testing
    function computeBuilderWallet(uint256 builderCode) external view returns (address) {
        return _computeBuilderWallet(builderCode);
    }
    
    /// @notice Simulates the exact casting logic from getRiskParameters at line 871
    function simulateFeeRecipientCast(uint256 builderCode) external view returns (uint128) {
        // This is the exact logic from RiskEngine.sol#L871:
        // uint128 feeRecipient = uint256(uint160(_computeBuilderWallet(builderCode))).toUint128();
        return Math.toUint128(uint256(uint160(_computeBuilderWallet(builderCode))));
    }
}

/// @title BuilderAddressOverflow PoC
/// @notice Demonstrates that RiskEngine.getRiskParameters() reverts for nearly all builder codes
/// @dev The vulnerability is at RiskEngine.sol#L871 where a 160-bit address is cast to uint128
contract BuilderAddressOverflowTest is Test {
    HarnessRiskEngine public harnessEngine;

    uint256 constant UINT128_MAX = type(uint128).max;

    function setUp() public {
        harnessEngine = new HarnessRiskEngine();
    }

    /// @notice Proves that almost all builder codes produce addresses > uint128.max
    /// @dev Shows the root cause: CREATE2 addresses are 160-bit, but feeRecipient is uint128
    function test_BuilderAddressOverflow_RootCause() public view {
        console2.log("=== Builder Address Overflow Vulnerability PoC ===");
        console2.log("");
        console2.log("uint128.max:          ", UINT128_MAX);
        console2.log("uint160.max:          ", type(uint160).max);
        console2.log("");
        console2.log("The RiskEngine.getRiskParameters() function at line 871 does:");
        console2.log("  uint128 feeRecipient = uint256(uint160(wallet)).toUint128();");
        console2.log("");
        console2.log("Math.toUint128() reverts with CastingError if value > uint128.max");
        console2.log("");
        
        // Test multiple random builder codes
        uint256[] memory testBuilderCodes = new uint256[](5);
        testBuilderCodes[0] = 1;
        testBuilderCodes[1] = 12345;
        testBuilderCodes[2] = 99999;
        testBuilderCodes[3] = uint256(keccak256("random_builder"));
        testBuilderCodes[4] = uint256(keccak256("another_builder"));

        uint256 overflowCount = 0;
        
        for (uint256 i = 0; i < testBuilderCodes.length; i++) {
            // Compute the wallet address using the exposed internal function
            address wallet = harnessEngine.computeBuilderWallet(testBuilderCodes[i]);
            uint256 walletAsUint = uint256(uint160(wallet));
            
            bool wouldOverflow = walletAsUint > UINT128_MAX;
            
            console2.log("---------------------------------------");
            console2.log("Builder Code:", testBuilderCodes[i]);
            console2.log("  Computed Wallet:", wallet);
            console2.log("  As uint256:     ", walletAsUint);
            console2.log("  > uint128.max?  ", wouldOverflow ? "YES (WILL REVERT)" : "NO (OK)");
            
            if (wouldOverflow) overflowCount++;
        }
        
        console2.log("");
        console2.log("=== SUMMARY ===");
        console2.log("Builder codes tested:", testBuilderCodes.length);
        console2.log("Would cause revert:  ", overflowCount);
        console2.log("");
        
        if (overflowCount > 0) {
            console2.log("VULNERABILITY CONFIRMED: Builder addresses exceed uint128.max");
            console2.log("getRiskParameters() will revert with CastingError for these codes.");
        }
    }

    /// @notice Demonstrates the actual revert when simulating the toUint128 cast
    function test_SimulateFeeRecipientCast_Reverts() public {
        console2.log("=== Demonstrating CastingError Revert ===");
        console2.log("");
        
        uint256 builderCode = 12345;
        
        // First, show what the computed address would be
        address wallet = harnessEngine.computeBuilderWallet(builderCode);
        uint256 walletAsUint = uint256(uint160(wallet));
        
        console2.log("Builder Code:       ", builderCode);
        console2.log("Computed wallet:    ", wallet);
        console2.log("Wallet as uint256:  ", walletAsUint);
        console2.log("uint128.max:        ", UINT128_MAX);
        console2.log("Overflows uint128:  ", walletAsUint > UINT128_MAX);
        console2.log("");
        
        if (walletAsUint > UINT128_MAX) {
            console2.log("Calling simulateFeeRecipientCast() which replicates line 871...");
            console2.log("EXPECTED: Revert with CastingError");
            console2.log("");
            
            // This should revert with CastingError
            vm.expectRevert();
            harnessEngine.simulateFeeRecipientCast(builderCode);
            
            console2.log("CONFIRMED: Call reverted as expected due to CastingError");
            console2.log("");
            console2.log("=== IMPACT ===");
            console2.log("- The Builder feature is COMPLETELY BROKEN");
            console2.log("- Any mint/burn operation using a builder code will FAIL");
            console2.log("- Builders cannot earn fees from the protocol");
            console2.log("- Users cannot support builders they want to use");
        } else {
            console2.log("This builder code happens to produce a small address (rare)");
            // Still verify it works without revert
            uint128 result = harnessEngine.simulateFeeRecipientCast(builderCode);
            console2.log("Result:", result);
        }
    }

    /// @notice Statistical analysis: probability of overflow
    function test_StatisticalAnalysis() public pure {
        console2.log("=== Statistical Analysis of Address Overflow ===");
        console2.log("");
        console2.log("Address Range Analysis:");
        console2.log("  - Ethereum addresses are 160-bit values (20 bytes)");
        console2.log("  - uint128 can only hold values from 0 to 2^128 - 1");
        console2.log("  - CREATE2 generates addresses uniformly across 160-bit space");
        console2.log("");
        console2.log("Probability Calculation:");
        console2.log("  - Total address space:        2^160");
        console2.log("  - Addresses <= uint128.max:   2^128");
        console2.log("  - Probability of NOT overflow: 2^128 / 2^160 = 1/2^32");
        console2.log("  - Probability of overflow:     1 - 1/2^32 = 99.99999998%");
        console2.log("");
        console2.log("CONCLUSION:");
        console2.log("  Only 1 in 4,294,967,296 (2^32) builder codes will work.");
        console2.log("  For practical purposes, the Builder feature is DISABLED.");
    }
}
