// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {CollateralTrackerTest} from "./CollateralTracker.t.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {Math} from "@libraries/PanopticMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import "forge-std/console2.sol";

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n; symbol = s; decimals = d;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
             allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }
}

contract StrangleCollateralTest is CollateralTrackerTest {
    using Math for uint256;
    using SafeCast for uint256;

    function test_Strangle_ITM_UnderCollateralization() public {
        // Mock Pool
        address poolAddr = address(USDC_WETH_5);
        MockToken t0 = new MockToken("USDC", "USDC", 6);
        MockToken t1 = new MockToken("WETH", "WETH", 18);
        
        vm.mockCall(poolAddr, abi.encodeWithSignature("token0()"), abi.encode(address(t0)));
        vm.mockCall(poolAddr, abi.encodeWithSignature("token1()"), abi.encode(address(t1)));
        vm.mockCall(poolAddr, abi.encodeWithSignature("fee()"), abi.encode(uint24(500)));
        vm.mockCall(poolAddr, abi.encodeWithSignature("tickSpacing()"), abi.encode(int24(10)));
        
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(200000);
        vm.mockCall(poolAddr, abi.encodeWithSignature("slot0()"), abi.encode(sqrtP, int24(200000), 0, 0, 0, 0, true));
        vm.mockCall(poolAddr, abi.encodeWithSignature("feeGrowthGlobal0X128()"), abi.encode(0));
        vm.mockCall(poolAddr, abi.encodeWithSignature("feeGrowthGlobal1X128()"), abi.encode(0));

        _initWorld(0); 

        // Deal tokens to Alice
        t0.mint(Alice, 1_000_000 ether);
        t1.mint(Alice, 1_000_000 ether);
        t0.mint(Swapper, 1_000_000 ether);
        t1.mint(Swapper, 1_000_000 ether);

        // Approve tokens
        vm.startPrank(Alice);
        t0.approve(address(collateralToken0), type(uint256).max);
        t1.approve(address(collateralToken1), type(uint256).max);
        
        // Deposit Collateral
        collateralToken0.deposit(10_000 ether, Alice);
        collateralToken1.deposit(10_000 ether, Alice);

        // 1. Construct a Short Strangle
        // Current Tick approx 200000 (ETH/USDC?). No, check tick.
        int24 currTick = currentTick;
        int24 tickSpacingLocal = tickSpacing;

        // Strikes: Call at +tickSpacing, Put at -tickSpacing (Example)
        int24 strikeCall = ((currTick + tickSpacingLocal * 2) / tickSpacingLocal) * tickSpacingLocal;
        int24 strikePut = ((currTick - tickSpacingLocal * 2) / tickSpacingLocal) * tickSpacingLocal;

        // Create TokenId
        // Leg 0: Short Call (Asset 0? Check token0/1). 
        // Token0 = USDC, Token1 = WETH.
        // Call on ETH (Token1). Pays Token1? Moves Token1. 
        // Strike > Price.
        
        // We want Short Call (Bearish) and Short Put (Bullish).
        // Short Call: Strike High. Risk if Price UP.
        // Short Put: Strike Low. Risk if Price DOWN.
        
        // Leg 0: Short Call at strikeCall.
        // asset=1 (ETH), optionRatio=1, isLong=0 (Short), tokenType=1 (Move T1), riskPartner=1
        // Leg 1: Short Put at strikePut.
        // asset=1 (ETH), optionRatio=1, isLong=0 (Short), tokenType=0 (Move T0? Put usually moves Numeraire?), riskPartner=0

        // Wait, standard Put moves Token0 (pay USDC to sell ETH).
        // Standard Call moves Token1 (pay ETH to buy USDC? No).
        
        // In Panoptic: 
        // tokenType=0 -> token0. tokenType=1 -> token1.
        // Put (Strike K). If Exercised: Sell 1 unit of T1 for K units of T0.
        // If I am Short Put. I must Buy T1. I pay K T0.
        // So I move T0. (tokenType=0). Correct.
        
        // Call (Strike K). If Exercised: Buy 1 unit of T1 for K units of T0.
        // If I am Short Call. I must Sell T1. I pay 1 unit of T1.
        // So I move T1. (tokenType=1). Correct.

        TokenId tokenId = TokenId.wrap(0);
        // Leg 0: Short Call ETH (Partner 1)
        // legIndex, ratio, asset(1=ETH), isLong(0=Short), tokenType(1=MoveT1), partner(1), strike, width(1)
        tokenId = tokenId.addLeg(0, 1, 1, 0, 1, 1, strikeCall, 1); 
        // Leg 1: Short Put ETH (Partner 0)
        // legIndex, ratio, asset(1=ETH), isLong(0=Short), tokenType(0=MoveT0), partner(0), strike, width(1)
        tokenId = tokenId.addLeg(1, 1, 1, 0, 0, 0, strikePut, 1);
        
        // Validate
        // tokenId.validate(); // Internal

        TokenId[] memory posList = new TokenId[](1);
        posList[0] = tokenId;

        // Mint
        // positionSize = 1 ether (10^18)
        uint128 size = 1 ether;
        
        mintOptions(panopticPool, posList, size, 0, 0, 0, false);
        
        // Check Solvency Initial
        PositionBalance[] memory balances = new PositionBalance[](1);
        balances[0] = panopticPool.positionBalance(Alice, tokenId);
        
        bool solvent = riskEngine.isAccountSolvent(
            balances, 
            posList, 
            currTick, 
            Alice, 
            LeftRightUnsigned.wrap(0), 
            LeftRightUnsigned.wrap(0), 
            collateralToken0, 
            collateralToken1, 
            10_000_000 // Buffer
        );
        assertTrue(solvent, "Should be solvent initially");

        // 2. Move Price Up massively (Call becomes Deep ITM)
        // New Price: +30%?
        int24 newTick = currTick + 15000; // 1.0001^15000 ~= 4.4x price
        uint160 newSqrtPrice = TickMath.getSqrtRatioAtTick(newTick);
        
        // Mock the pool slot0
        vm.mockCall(
            address(pool),
            abi.encodeWithSignature("slot0()"),
            abi.encode(newSqrtPrice, newTick, 0, 0, 0, 0, true)
        );

        // Check Solvency again
        // We did NOT deposit more collateral. 
        // Liability on Short Call:
        // Price moved up 4.4x.
        // I owe 1 ETH (symbolic).
        // Value of 1 ETH in USDC increased 4.4x.
        // I hold USDC collateral?
        // I deposited 10,000 USDC and 10,000 WETH.
        
        // If I am Short Call T1 (ETH). I owe T1.
        // RiskEngine calculates required collateral in T1.
        // If Deep ITM, I expect "r1" logic to require ~100% of Notional (1 ETH).
        // 1 ETH = 10^18 units.
        // I deposited 10,000 ETH. So I have plenty.
        
        // Let's reduce collateral to the "Edge" case.
        // Withdraw all excess collateral first?
        // Hard to calculate exact excess.
        
        // Instead, let's look at what getMargin returns.
        PositionBalance[] memory balances2 = new PositionBalance[](1);
        balances2[0] = panopticPool.positionBalance(Alice, tokenId);

        (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
            balances2, 
            newTick, 
            Alice, 
            posList, 
            LeftRightUnsigned.wrap(0), 
            LeftRightUnsigned.wrap(0), 
            collateralToken0, 
            collateralToken1
        );
        
        uint256 req0 = tokenData0.leftSlot(); // Required T0
        uint256 req1 = tokenData1.leftSlot(); // Required T1

        console2.log("Required T0:", req0);
        console2.log("Required T1:", req1); // Should be large for Short Call?

        // Verify Strangle Logic
        // Leg 0: Short Call (Deep ITM). 
        // Leg 1: Short Put (Deep OTM).
        
        // Normal Call Req: ~1 ETH (since ITM).
        // Strangle Call Req: Halved base ratio? But ITM part preserved?
        
        // If Strangle Collateral logic is flawed, req1 might be 0.5 ETH?
        // If correct, req1 should be ~1 ETH (Intrinsic Value).

        // Asset 1 is WETH.
        // We have 1 position of size 1 ether.
        // We moved 1 ether.
        // Req1 should be close to 1 ether (10^18).
        
        if (req1 < 0.9 ether) {
            console2.log("VULNERABILITY CONFIRMED: Requirement is significantly less than Notional for Deep ITM Strangle Leg");
            revert("VULNERABILITY_FOUND");
        } else {
            console2.log("Logic seems safe. Req1:", req1);
        }
    }
}
