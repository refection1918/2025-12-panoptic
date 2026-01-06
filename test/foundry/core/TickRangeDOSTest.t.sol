// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {TokenId} from "@types/TokenId.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {Errors} from "@libraries/Errors.sol";

// Minimal Mock Pool
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    int24 public tickSpacing = 60;
    
    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }

    function slot0() external pure returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    ) {
        return (0, 0, 0, 0, 0, 0, true);
    }
}

contract MockFactory {
    address public pool;
    constructor(address _pool) { pool = _pool; }
    function getPool(address, address, uint24) external view returns (address) { return pool; }
}

contract MockERC20 {
    function approve(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
    // Huge total supply (e.g. 10^50 to trigger tick limit)
    function totalSupply() external pure returns (uint256) { return 10**50; }
}

contract TickRangeDOSTest is Test {
    SemiFungiblePositionManager sfpm;
    address pool;
    address token0;
    address token1;
    bytes poolKey;

    function setUp() public {
        token0 = address(new MockERC20());
        token1 = address(new MockERC20());
        if (token0 > token1) (token0, token1) = (token1, token0);

        pool = address(new MockUniswapV3Pool());
        MockUniswapV3Pool(pool).setTokens(token0, token1);
        
        address factory = address(new MockFactory(pool));
        sfpm = new SemiFungiblePositionManager(IUniswapV3Factory(factory), type(uint256).max, 10**13); // metal, metal
        
        poolKey = abi.encode(pool);
    }

    // ERC1155 receiver to allow transfers to this contract
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function test_TickRangeDOS() public {
        // Initialize pool - with high totalSupply, enforced tick range will be extremely narrow
        // initializeAMMPool returns the actual poolId used by SFPM
        uint64 poolId = sfpm.initializeAMMPool(token0, token1, 500, 0);

        // Log event shows minEnforcedTick: -1, maxEnforcedTick: 1
        // Any position with tickLower < -1 or tickUpper > 1 will revert with InvalidTickBound
        
        // Construct a TokenId for a position with width=10 -> tickLower=-300, tickUpper=300
        // This will violate the enforced tick range [-1, 1]
        uint256 legDataShort = (1 << 1) | (10 << 36); // Ratio=1, Width=10, Short
        TokenId tokenIdShort = TokenId.wrap(uint256(poolId) | (legDataShort << 64));

        vm.expectRevert(Errors.InvalidTickBound.selector);
        sfpm.mintTokenizedPosition(poolKey, tokenIdShort, 100, -600, 600);
    }
}
