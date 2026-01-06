// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {MarketState, MarketStateLibrary} from "@types/MarketState.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {LeftRightSigned} from "@types/LeftRight.sol";

contract CollateralTrackerHarness is CollateralTracker {
    using Math for uint256;

    constructor(uint256 fee) CollateralTracker(fee) {}
    
    function initializeHarness() external {
        // functionality from CollateralTracker.initialize()
        s_initialized = true;
        _internalSupply = 10 ** 6;
        s_depositedAssets = 1;
        s_marketState = MarketStateLibrary.storeMarketState(WAD, block.timestamp >> 2, 0, 0);
    }
    
    // Helper to expose internal state
    function getMarketState() external view returns (uint256 index, uint256 epoch, uint256 raw, uint256 unrealized) {
        index = s_marketState.borrowIndex();
        epoch = s_marketState.marketEpoch();
        raw = MarketState.unwrap(s_marketState);
        unrealized = s_marketState.unrealizedInterest();
    }

    function forceAssetsInAMM(uint128 amount) external {
        s_assetsInAMM = amount;
    }

    function setInterestState(address user, int128 netBorrows, int128 index) external {
         s_interestState[user] = LeftRightSigned.wrap(0).addToLeftSlot(netBorrows).addToRightSlot(index);
    }

    function getInterestState(address user) external view returns (int128 netBorrows, int128 index) {
        LeftRightSigned state = s_interestState[user];
        netBorrows = state.leftSlot();
        index = state.rightSlot();
    }

    // Bypass modify allow
    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
        s_depositedAssets += uint128(amount); // Keep assets consistent with shares roughly
    }
}

contract GhostInterestTest is Test {
    CollateralTrackerHarness ct;
    address lender = address(0x1);
    address borrower = address(0x2);
    
    function setUp() public {
        ct = new CollateralTrackerHarness(0);
        ct.initializeHarness();
        
        // Setup Lender
        vm.deal(lender, 1000e18);
        // We use mintShares to simulate deposit without needing transferFrom/approve dance with underlying
        ct.mintShares(lender, 1000); 
        
        // Setup Borrower
        ct.mintShares(borrower, 100);
        
        // Force assets in AMM to allow interest accrual
        ct.forceAssetsInAMM(uint128(1000));
    }
    
    function test_GhostInterestInflation() public {
        // 1. Borrower borrows 500 assets
        // Initial index is 1e18
        ct.setInterestState(borrower, 500, int128(uint128(1e18)));

        // 2. Mock High Interest Rate (100% per sec) to cause insolvency fast
        uint128 rate = 1e18; 
        vm.mockCall(address(0), abi.encodeWithSelector(IRiskEngine.interestRate.selector), abi.encode(rate));
        vm.mockCall(address(0), abi.encodeWithSelector(IRiskEngine.updateInterestRate.selector), abi.encode(rate, 0));
        
        // 3. Current State check
        (,,, uint256 unrealizedBefore) = ct.getMarketState();
        assertEq(unrealizedBefore, 0, "Initial unrealized should be 0");
        
        // 4. Warp time to accrue massive interest
        // 500 borrowed * (huge rate) -> > 100 collateral
        vm.warp(block.timestamp + 10);
        
        // 5. Trigger Accrual for Borrower
        vm.prank(borrower);
        ct.accrueInterest();
        
        // 6. Verify Borrower is burned out
        uint256 borrowerShares = ct.balanceOf(borrower);
        console.log("Borrower Shares After:", borrowerShares);
        assertEq(borrowerShares, 0, "Borrower should be burned to 0");
        
        // 7. Check Ghost Interest
        (,,, uint256 unrealizedAfter) = ct.getMarketState();
        console.log("Unrealized Interest After Burn:", unrealizedAfter);
        
        // Interest Owed logic:
        // Rate ~ 100% per sec. 10 secs. Index grows ~ e^10 factor or similar massive amount.
        // Debt >> 500 * 10 = 5000.
        // Borrower had 100 shares ~ 100 assets.
        // Paid 100.
        // Unpaid ~ 4900+.
        
        assertGt(unrealizedAfter, 0, "Ghost interest should exist");
        
        // 8. Check Total Assets Logic
        // Real Assets = 1000 (Lender) + 100 (Borrower Initial) + 1 (Init) = 1101? 
        // Note: mintShares added to s_depositedAssets. 
        // Lender: 1000. Borrower: 100. Init: 1. Total Deposited: 1101.
        // AssetsInAMM: 1000 (forced).
        // Total Assets = s_depositedAssets + s_assetsInAMM + unrealized.
        // Note: s_depositedAssets tracks user deposits. 
        // In this harness, we just minted shares and added to s_depositedAssets.
        // But s_assetsInAMM also counts towards logic.
        // Let's rely on totalAssets() view
        
        uint256 reportedAssets = ct.totalAssets();
        console.log("Reported Total Assets:", reportedAssets);
        
        // Real assets underlying the system:
        // Because we forced s_assetsInAMM, it's a bit artificial. 
        // But the point is unrealized interest is ADDED to totalAssets.
        // If that interest is bad debt (unrecoverable), it shouldn't be valid asset.
        
        // Verification:
        // Does the lender get more shares/assets value than exists?
        // Lender shares = 1000.
        // Assets = 1101 + unrealized (bad debt).
        // If lender withdraws, assert they can't withdraw reportedAssets if it exceeds physical balance (which isn't tracked here fully).
        // But we can check share price.
        
        uint256 sharePrice = ct.convertToAssets(1 ether); // 1 share
        console.log("Share Price (Assets per 1e18 shares):", sharePrice);
        
        // If bad debt was cleared, unrealized should be low (just for current block).
        // Here it should be huge.
        
        if (unrealizedAfter > 1000) {
             console.log("VULNERABILITY CONFIRMED: Bad debt remains in unrealized interest");
        }
    }
}
