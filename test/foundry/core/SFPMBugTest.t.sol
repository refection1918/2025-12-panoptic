// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {TokenId} from "@types/TokenId.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";

// Simple mock for Uniswap V3 Pool to check liquidity calls
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing = 60;
    uint128 public liquidity;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }
    Slot0 public slot0;

    constructor() {
        slot0.sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
        slot0.tick = 0;
    }

    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function positions(bytes32 key) external view returns (uint128 _liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) {
        return (liquidity, 0, 0, 0, 0);
    }

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data) external returns (uint256 amount0, uint256 amount1) {
        liquidity += amount;
        return (uint256(amount), uint256(amount));
    }

    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256 amount0, uint256 amount1) {
        liquidity -= amount;
        return (uint256(amount), uint256(amount));
    }

    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) external returns (uint128 amount0, uint128 amount1) {
        return (0, 0);
    }
}

contract MockERC20 {
    function totalSupply() external pure returns (uint256) { return 10000 ether; }
    function balanceOf(address) external pure returns (uint256) { return 10000 ether; }
    function approve(address, uint256) external pure returns (bool) { return true; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
}

contract SFPMBugTest is Test {
    SemiFungiblePositionManager sfpm;
    MockUniswapV3Pool pool;
    address token0;
    address token1;

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function setUp() public {
        pool = new MockUniswapV3Pool();
        // Mock Factory to return our pool
        address factory = address(new MockFactory(address(pool)));
        
        token0 = address(new MockERC20());
        token1 = address(new MockERC20());
        
        if (token0 > token1) (token0, token1) = (token1, token0);
        
        pool.setTokens(token0, token1);

        sfpm = new SemiFungiblePositionManager(IUniswapV3Factory(factory), 10**13, 10**13); 
    }

    function testBurnAddsLiquidityBug() public {
        // 1. Initialize Pool in SFPM
        // initializeAMMPool(address token0, address token1, uint24 fee, uint8 vegoid)
        uint64 poolId = sfpm.initializeAMMPool(token0, token1, 3000, 4);

        // 2. Create a TokenId for a Short Option (isLong=0)
        // TokenId: [Leg3][Leg2][Leg1][Leg0][PoolId]
        
        uint256 legData = (1 << 1) | (2 << 36); // Ratio=1 (offset 1), Width=2 (offset 36)
        
        uint256 tokenIdVal = uint256(poolId) | (legData << 64);
        TokenId tokenId = TokenId.wrap(tokenIdVal);
        
        // poolKey for calling mint/burn
        bytes memory poolKey = abi.encode(address(pool));

        // 3. Mint Position
        // Checks liquidity before
        uint128 liq0 = pool.liquidity();
        assertEq(liq0, 0);
        
        sfpm.mintTokenizedPosition(
            poolKey,
            tokenId,
            100, // positionSize
            -100, 100 // tickLimits (ignored in mock mostly)
        );
        
        uint128 liqAfterMint = pool.liquidity();
        assertTrue(liqAfterMint > 0, "Mint should add liquidity");
        
        console.log("Liquidity after Mint:", liqAfterMint);

        // 4. Burn Position (Same TokenId)
        sfpm.burnTokenizedPosition(
            poolKey,
            tokenId,
            100, // positionSize
            -100, 100
        );
        
        uint128 liqAfterBurn = pool.liquidity();
        console.log("Liquidity after Burn:", liqAfterBurn);
        
        // 5. Assert Bug
        if (liqAfterBurn > liqAfterMint) {
            console.log("CRITICAL BUG CONFIRMED: Liquidity increased after burn!");
            fail(); // Fail to flag
        } else {
            console.log("Bug NOT reproduced. Liquidity decreased.");
        }
    }
}

contract MockFactory {
    address pool;
    constructor(address _pool) { pool = _pool; }
    function getPool(address, address, uint24) external view returns (address) { return pool; }
}
