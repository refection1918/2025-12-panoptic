// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {Errors} from "@libraries/Errors.sol";
import {LeftRightSigned, LeftRightLibrary} from "@types/LeftRight.sol";

// Mock PanopticPool to control numberOfLegs replay
contract MockPanopticPool {
    mapping(address => uint256) public legs;
    
    function setNumberOfLegs(address user, uint256 count) external {
        legs[user] = count;
    }

    function numberOfLegs(address user) external view returns (uint256) {
        return legs[user];
    }

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

// Subclass to expose internal storage for Bad Debt test
contract ExposedCollateralTracker is CollateralTracker {
    constructor(uint256 _commissionFee) CollateralTracker(_commissionFee) {}

    // Helper to manipulate internal state for testing purposes
    // We need to simulate a case where user has debt but 0 legs
    function setNetBorrows(address user, int128 amount) external {
        int128 index = s_interestState[user].rightSlot();
        LeftRightSigned newState = LeftRightSigned.wrap(0);
        newState = newState.addToLeftSlot(amount);
        newState = newState.addToRightSlot(index);
        s_interestState[user] = newState;
    }
}

contract LiquidateTransferRaceTest is Test {
    using ClonesWithImmutableArgs for address;

    ExposedCollateralTracker ct;
    MockToken token;
    MockPanopticPool pp;
    MockRiskEngine re;
    ExposedCollateralTracker implementation;

    function setUp() public {
        token = new MockToken();
        pp = new MockPanopticPool();
        re = new MockRiskEngine();
        
        implementation = new ExposedCollateralTracker(10);
        
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
        
        ct = ExposedCollateralTracker(address(implementation).clone(args));
        ct.initialize();
    }

    // Test Case 1: Front-running Liquidation
    // Determine if transfer() is blocked when user has open positions (legs > 0)
    function testFrontRunTransferWithLegs() public {
        address Alice = address(0x1);
        address Bob = address(0x2);
        
        uint256 depositAmount = 100 ether;
        token.mint(Alice, depositAmount);
        
        vm.startPrank(Alice);
        token.approve(address(ct), depositAmount);
        ct.deposit(depositAmount, Alice);
        
        // Simulate Alice opening a position
        pp.setNumberOfLegs(Alice, 1);
        
        // Alice attempts to front-run liquidation by transferring collateral
        vm.expectRevert(Errors.PositionCountNotZero.selector);
        ct.transfer(Bob, 50 ether);
        
        vm.stopPrank();
    }

    // Test Case 2: Transfer-Blocking Liquidation (Dust attack)
    // Check if receiving dust during liquidation causes failure
    // NOTE: In the real contract, settleLiquidation calls settleLiquidation in CT.
    // We need to verify verify settleLiquidation logic doesn't revert on extra balance.
    function testDustTransferDuringLiquidation() public {
        address Alice = address(0x1); // Liquidatee
        address Liquidator = address(0x2);
        address MaliciousActor = address(0x3);
        
        // Setup Alice
        uint256 aliceDeposit = 1000 ether;
        token.mint(Alice, aliceDeposit);
        vm.startPrank(Alice);
        token.approve(address(ct), aliceDeposit);
        ct.deposit(aliceDeposit, Alice);
        vm.stopPrank();

        // Setup Liquidator (needs tokens to pay bonus if negative, or just to exist)
        uint256 liqDeposit = 100 ether;
        token.mint(Liquidator, liqDeposit);

        // Setup logic for settleLiquidation call simulation
        // The PanopticPool calls: ct.settleLiquidation(liquidator, liquidatee, bonus)
        // We simulate this call from the MockPanopticPool (which acts as caller)
        
        // Malicious actor sends dust to Alice
        uint256 dust = 1; // 1 wei
        token.mint(MaliciousActor, dust);
        vm.startPrank(MaliciousActor);
        token.approve(address(ct), dust);
        ct.deposit(dust, MaliciousActor);
        // Alice needs 0 legs to receive transfer? No, recipient check is only on sender side in standard ERC20, 
        // BUT CollateralTracker inherits ERC20Minimal. 
        // Let's check if Alice can RECEIVE transfers. 
        // CollateralTracker.transfer -> _accrueInterest(msg.sender) -> ERC20Minimal.transfer -> balanceOf check.
        // There is no override for _transfer or receiver checks in CollateralTracker. 
        // So Alice can receive funds even if she has legs (implied, not explicitly checked on receiver).
        // Standard ERC20 transfer doesn't check receiver status usually.
        
        // Actually, let's verify if Alice can receive if she has legs.
        pp.setNumberOfLegs(Alice, 5); 
        ct.transfer(Alice, dust); 
        vm.stopPrank();
        
        console.log("Alice Balance after dust:", ct.balanceOf(Alice));
        
        // Now simulate settleLiquidation
        int256 bonus = 50 ether; // Positive bonus means liquidator gets paid from liquidatee
        
        vm.prank(address(pp));
        ct.delegate(Alice);
        
        vm.prank(address(pp));
        // Should succeed despite the dust
        ct.settleLiquidation(Liquidator, Alice, bonus);
        
        console.log("Liquidation Settled Successfully");
    }

    // Test Case 3: Solvency Bypass mechanisms
    // Verify if transfer is allowed when legs == 0 but user has debt
    function testTransferWithZeroLegsAndBadDebt() public {
        address Alice = address(0x1);
        address Bob = address(0x2);

        // 1. Specific setup: Legs = 0, but Debt > 0
        pp.setNumberOfLegs(Alice, 0);
        
        // Give Alice some collateral
        uint256 depositAmount = 100 ether;
        token.mint(Alice, depositAmount);
        
        vm.startPrank(Alice);
        token.approve(address(ct), depositAmount);
        ct.deposit(depositAmount, Alice);
        
        // Manually impose debt
        // We use our exposed function to set netBorrows > 0
        // This simulates a scenario where a user might have closed positions but interest/debt remains,
        // OR a bug allowed closing legs without settling debt.
        ct.setNetBorrows(Alice, 50 ether); // 50 ether debt
        
        // 2. Action: Alice attempts to transfer collateral out
        // Expectation: If the check is ONLY on numberOfLegs, this will succeed.
        // If it succeeds, it confirms that maintaining legs=0 with debt is a hazardous state.
        ct.transfer(Bob, depositAmount);
        
        console.log("Transfer successful despite debt (as expected for this test case)");
        console.log("Alice Balance:", ct.balanceOf(Alice));
        console.log("Bob Balance:", ct.balanceOf(Bob));
    }
}
