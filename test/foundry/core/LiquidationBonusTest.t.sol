// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {Math} from "@libraries/Math.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {PositionBalance} from "@types/PositionBalance.sol";

contract MockToken is ERC20Minimal {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSFPM is ISemiFungiblePositionManager {
    LeftRightSigned public mockNetAmmDelta;
    
    function setMockNetAmmDelta(int256 amount0, int256 amount1) external {
        mockNetAmmDelta = LeftRightSigned.wrap(0).addToRightSlot(int128(int256(amount0))).addToLeftSlot(int128(int256(amount1)));
    }

    function burnTokenizedPosition(
        bytes calldata, 
        TokenId,
        uint128,
        int24,
        int24
    ) external override returns (
        LeftRightUnsigned[4] memory collectedByLeg,
        LeftRightSigned netAmmDelta,
        int24 finalTick
    ) {
        netAmmDelta = mockNetAmmDelta; 
        finalTick = 0;
    }
    
    function getAccountLiquidity(bytes calldata, address, uint256, int24, int24) external pure override returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(0);
    }
    
    function mintTokenizedPosition(bytes calldata, TokenId, uint128, int24, int24) external override returns (LeftRightUnsigned[4] memory, LeftRightSigned, int24) { return ([LeftRightUnsigned.wrap(0),LeftRightUnsigned.wrap(0),LeftRightUnsigned.wrap(0),LeftRightUnsigned.wrap(0)], LeftRightSigned.wrap(0), 0); }
    
    function getAccountPremium(bytes calldata, address, uint256, int24, int24, int24, uint256, uint256) external view returns (uint128, uint128) { return (0,0); }
    
    function expandEnforcedTickRange(uint64) external {}
    
    function getPoolId(bytes memory, uint8) external view returns (uint64) { return 0; }
    function getEnforcedTickLimits(uint64) external view returns (int24, int24) { return (0,0); }
    function getCurrentTick(bytes memory) external view returns (int24) { return 0; }
    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external override {}
    function safeBatchTransferFrom(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external override {}
}

import {PositionBalance} from "@types/PositionBalance.sol";

// ... (Contracts)

contract PanopticPoolHarness is PanopticPool {
    constructor(ISemiFungiblePositionManager _sfpm) PanopticPool(_sfpm) {}

    function expose_liquidate(
        address liquidatee,
        TokenId[] calldata positionIdList,
        int24 twapTick,
        int24 currentTick
    ) external {
        _liquidate(liquidatee, positionIdList, twapTick, currentTick);
    }

    function setPositionsHash(address user, uint256 hash) external {
        s_positionsHash[user] = hash;
    }
    
    function setPositionBalance(address user, TokenId tokenId, PositionBalance balance) external {
        s_positionBalance[user][tokenId] = balance;
    }
}

contract LiquidationBonusTest is Test {
    using ClonesWithImmutableArgs for address;
    using TokenIdLibrary for TokenId;

    MockToken token0;
    MockToken token1;
    MockSFPM sfpm;
    PanopticPoolHarness ppImpl;
    PanopticPoolHarness pp; 
    RiskEngine re;
    
    address ct0;
    address ct1;

    function setUp() public {
        token0 = new MockToken();
        token1 = new MockToken();
        sfpm = new MockSFPM();
        re = new RiskEngine(0, 0, address(0), address(0)); 
        
        ppImpl = new PanopticPoolHarness(sfpm);
        
        ct0 = makeAddr("CollateralTracker0");
        ct1 = makeAddr("CollateralTracker1");
        
        address poolManager = address(0);
        uint64 poolId = 123;
        
        bytes memory args = abi.encodePacked(
            ct0,
            ct1,
            address(re),
            poolManager,
            poolId,
            abi.encode(address(token0), address(token1), uint24(500), int24(10), address(0))
        );
        
        pp = PanopticPoolHarness(address(ppImpl).clone(args));
    }

    function test_LiquidationBonus_NegativeNetPaid() public {
        address liquidatee = address(0xAA);
        address liquidator = address(0xBB);
        
        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.delegate.selector), abi.encode());
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.delegate.selector), abi.encode());
        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.revoke.selector), abi.encode());
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.revoke.selector), abi.encode());
        
        vm.mockCall(ct0, abi.encodeWithSignature("balanceOf(address)", liquidatee), abi.encode(uint256(1000)));
        vm.mockCall(ct1, abi.encodeWithSignature("balanceOf(address)", liquidatee), abi.encode(uint256(0)));

        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.settleBurn.selector), abi.encode(int128(-10000000)));
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.settleBurn.selector), abi.encode(int128(0)));

        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.settleLiquidation.selector), abi.encode());
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.settleLiquidation.selector), abi.encode());

        // Mock RiskEngine.getMargin to bypass complex logic and return Insolvent state
        // Return: (tokenData0, tokenData1, ...?)
        // LeftRightUnsigned tokenData = (Required << 128) | Balance
        LeftRightUnsigned tokenData0 = LeftRightUnsigned.wrap(0).addToRightSlot(1000).addToLeftSlot(2000);
        LeftRightUnsigned tokenData1 = LeftRightUnsigned.wrap(0).addToRightSlot(0).addToLeftSlot(0);
        
        vm.mockCall(
            address(re), 
            abi.encodeWithSelector(RiskEngine.getMargin.selector), 
            abi.encode(tokenData0, tokenData1, LeftRightUnsigned.wrap(0))
        );

        sfpm.setMockNetAmmDelta(-10000000, 0);

        TokenId[] memory positions = new TokenId[](1);
        TokenId tid = TokenId.wrap(0);
        tid = tid.addPoolId(123).addTickSpacing(10);
        tid = tid.addLeg(0, 1, 0, 0, 0, 0, 0, 10); 
        positions[0] = tid;
        
        uint256 hash = 0;
        for(uint i=0; i<positions.length; i++) {
            hash = PanopticMath.updatePositionsHash(hash, positions[i], true);
        }
        pp.setPositionsHash(liquidatee, hash);
        pp.setPositionBalance(liquidatee, tid, PositionBalance.wrap(100)); // Size 100

        vm.startPrank(liquidator);
        pp.expose_liquidate(liquidatee, positions, 0, 0);
        vm.stopPrank();
    }

    function test_LiquidationBonus_InsolvencyDOS() public {
        address liquidatee = address(0xAA);
        address liquidator = address(0xBB);
        
        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.delegate.selector), abi.encode());
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.delegate.selector), abi.encode());
        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.revoke.selector), abi.encode());
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.revoke.selector), abi.encode());
        
        // Mock Balance to 0 (Empty Wallet)
        vm.mockCall(ct0, abi.encodeWithSignature("balanceOf(address)", liquidatee), abi.encode(uint256(0)));
        vm.mockCall(ct1, abi.encodeWithSignature("balanceOf(address)", liquidatee), abi.encode(uint256(0)));

        // Mock settleBurn returns +10,000,000 (User OWES 10M tokens)
        // If CT.settleBurn tries to transferFrom user, it should Revert if user has no approval/balance.
        // We Mock it to Revert IF we want to check behavior, but VM.mockCall intercepts it.
        // To test DOS, we rely on the fact that Real CT *would* revert.
        // But here we are testing verify behavior if it *succeeds* or how `getLiquidationBonus` handles the debt.
        
        // Let's Mock it to return +10M and see if getLiquidationBonus haircuts properly.
        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.settleBurn.selector), abi.encode(int128(10000000)));
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.settleBurn.selector), abi.encode(int128(0)));

        vm.mockCall(ct0, abi.encodeWithSelector(CollateralTracker.settleLiquidation.selector), abi.encode());
        vm.mockCall(ct1, abi.encodeWithSelector(CollateralTracker.settleLiquidation.selector), abi.encode());
        
        // RiskEngine Mock
        // Balance 0. Required 2000.
        LeftRightUnsigned tokenData0 = LeftRightUnsigned.wrap(0).addToRightSlot(0).addToLeftSlot(2000);
        LeftRightUnsigned tokenData1 = LeftRightUnsigned.wrap(0).addToRightSlot(0).addToLeftSlot(0);
        
        vm.mockCall(
            address(re), 
            abi.encodeWithSelector(RiskEngine.getMargin.selector), 
            abi.encode(tokenData0, tokenData1, LeftRightUnsigned.wrap(0))
        );

        sfpm.setMockNetAmmDelta(10000000, 0); // Positive Delta (User Pays)

        // Setup Position
        TokenId[] memory positions = new TokenId[](1);
        TokenId tid = TokenId.wrap(0);
        tid = tid.addPoolId(123).addTickSpacing(10);
        tid = tid.addLeg(0, 1, 0, 0, 0, 0, 0, 10); 
        positions[0] = tid;
        
        uint256 hash = 0;
        for(uint i=0; i<positions.length; i++) {
            hash = PanopticMath.updatePositionsHash(hash, positions[i], true);
        }
        pp.setPositionsHash(liquidatee, hash);
        pp.setPositionBalance(liquidatee, tid, PositionBalance.wrap(100));

        // Execution
        vm.startPrank(liquidator);
        pp.expose_liquidate(liquidatee, positions, 0, 0);
        vm.stopPrank();
    }
}
