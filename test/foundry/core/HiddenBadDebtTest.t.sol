// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {Math} from "@libraries/Math.sol";
import {Errors} from "@libraries/Errors.sol";

// Mock Token
contract MockToken is ERC20Minimal {
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract CollateralTrackerHarness is CollateralTracker {
    constructor(uint256 fee) CollateralTracker(fee) {}
    
    function initializeHarness() external {
        s_initialized = true;
    }

    // Helper to mint shares and update accounting "as if" deposited
    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
        s_depositedAssets += uint128(amount);
    }
    
    function simulateDelegate(address user) external {
        balanceOf[user] += type(uint248).max;
    }

    function simulateRevoke(address user) external {
        uint256 balance = balanceOf[user];
        if (type(uint248).max > balance) {
            balanceOf[user] = 0;
            // s_internalSupply update omitted as it might be private and doesn't affect totalSupply
        } else {
            balanceOf[user] = balance - type(uint248).max;
        }
    }

    // Expose settle helper to simulate liquidation call
    // Logic matches _updateBalancesAndSettle's check:
    function simulateLiquidationSettle(address user, uint256 sharesToBurn) external {
        if (balanceOf[user] < sharesToBurn) {
             revert Errors.NotEnoughTokens(address(this), sharesToBurn, 0);
        }
        _burn(user, sharesToBurn);
    }
    
    // Simulate withdraw logic without calling internal transfer that needs underlyingToken()
    function simulateWithdraw(address user, uint256 shares, address token) external {
        uint256 assets = convertToAssets(shares);
        _burn(user, shares);
        s_depositedAssets -= uint128(assets); // Withdraw reduces tracked assets
        ERC20Minimal(token).transfer(user, assets);
    }
}

contract HiddenBadDebtTest is Test {
    CollateralTrackerHarness ct;
    MockToken token;
    
    address Alice = address(0xA);
    address Bob = address(0xB);
    address Charlie = address(0xC);

    function setUp() public {
        token = new MockToken();
        ct = new CollateralTrackerHarness(0);
        ct.initializeHarness();
    }

    function test_HiddenBadDebt_RaceToExit() public {
        // 1. Setup Initial State
        // Alice: 50, Charlie: 50. Total 100.
        token.mint(address(ct), 110 ether); 
        ct.mintShares(Alice, 50 ether);
        ct.mintShares(Charlie, 50 ether);
        
        assertEq(ct.totalAssets(), 100 ether, "Initial Assets correct");
        assertEq(ct.totalSupply(), 100 ether, "Initial Supply correct");

        // 2. Simulate AMM Loss (Real Assets Lost)
        // Charlie loses 40 assets in AMM. Contract only has 70 real assets left (110 - 40).
        // Wait, setup minted 110 tokens but registered 100 assets.
        // Let's settle on: 100 deposited. 100 tokens.
        deal(address(token), address(ct), 60 ether); // 40 Lost.
        
        assertEq(token.balanceOf(address(ct)), 60 ether, "Real assets lost");
        assertEq(ct.totalAssets(), 100 ether, "Accounting unaware of loss");

        // 3. Charlie becomes Insolvent and is Liquidated
        // Debt = 40 shares.
        // Protocol burns 40 shares from Charlie.
        
        ct.simulateDelegate(Charlie);
        
        // Liquidation settle runs.
        ct.simulateLiquidationSettle(Charlie, 40 ether);
        
        // Revoke phantom shares
        ct.simulateRevoke(Charlie);
        
        // State after Liquidation:
        // Charlie Real Shares = 50 - 40 = 10.
        // Total Supply = 100 - 40 = 60.
        // Total Assets (Accounting) = 100 (Unchanged).
        // Total Real Assets = 60.
        // Price = 100 / 60 = ~1.666.
        
        assertEq(ct.totalSupply(), 60 ether, "Supply reduced by bad debt");
        assertEq(ct.totalAssets(), 100 ether, "Assets accounting unchanged");
        
        // 4. Alice Races to Exit
        // She withdraws 30 shares.
        // Expected Assets = 30 * 100 / 60 = 50.
        
        ct.simulateWithdraw(Alice, 30 ether, address(token));
        
        uint256 aliceReceived = token.balanceOf(Alice);
        console.log("Alice Withdrew 30 shares, received:", aliceReceived);
        
        assertEq(aliceReceived, 50 ether, "Alice profited from insolvency");
        
        // Alice got 50 assets for 30 shares (originally worth 30).
        // Contract has 10 assets left.
        // Remaining Claims: Alice (20 shares), Charlie (10 shares). Total 30 shares.
        // Assets: 10.
        // Real Value per Share = 10 / 30 = 0.33.
        // Accounting Price = (100 - 50) / (60 - 30) = 50 / 30 = 1.66.
        // Next withdrawer gets 1.66 * Shares.
        
        console.log("Confirmation: Hidden Bad Debt causes Inflation + Arbitrage");
    }
}
