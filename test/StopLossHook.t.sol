// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {HookTest} from "./utils/HookTest.sol";
import {StopLossHook} from "../src/StopLossHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract StopLossHookTest is HookTest, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    StopLossHook stopLossHook;
    PoolKey poolKey;
    PoolId poolId;

    address user1 = vm.addr(0xABCD);
    address user2 = vm.addr(0xBCDE);

    function setUp() public {
        // creates the pool manager, test tokens, and other utility routers
        HookTest.initHookTestEnv();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, 0, type(StopLossHook).creationCode, abi.encode(address(manager),"", 100));
        stopLossHook = new StopLossHook{salt: salt}(IPoolManager(address(manager)), "", 100);
        require(address(stopLossHook) == hookAddress, "StopLossHookTest: hook address mismatch");

        // Create the pool
        poolKey = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(stopLossHook));
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);    //this is a one to one ratio

        // Provide liquidity to the pool
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether), ZERO_BYTES);
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether), ZERO_BYTES);
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether),
            ZERO_BYTES
        );

        //setup users
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        token0.transfer(user1, 10 ether);
        token1.transfer(user1, 10 ether);
        token0.transfer(user2, 10 ether);
        token1.transfer(user2, 10 ether);
    }

    function testPlaceOrder() public {
        int24 tick = 100;
        uint256 amount = 5 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));
        token0.approve(address(stopLossHook), amount);

        int24 positionTickUpper;
        vm.expectRevert("no deposit");
        positionTickUpper = stopLossHook.placeOrder(poolKey, tick, amount, zeroForOne);

        positionTickUpper = stopLossHook.placeOrder{value: 1 ether}(poolKey, tick, amount, zeroForOne);
        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(positionTickUpper, 120);
        //balance should have transferred out, and be kept in the stopLossHook
        assertEq(originalBalance - newBalance, amount);

        uint256 tokenId = stopLossHook.getTokenId(poolKey, positionTickUpper, zeroForOne);
        uint256 tokenBalance = stopLossHook.balanceOf(address(this), tokenId);

        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function testStopLossWithTwoUsers() public {
        int24 tick = -300;
        uint256 positionAmount =  0.1 ether;
        bool zeroForOne = false;

        //open a stop loss order should price cross a boundary
        vm.startPrank(user1);
        token1.approve(address(stopLossHook), positionAmount);

        uint256 tokenIdAtPosition = stopLossHook.getTokenId(poolKey, tick, zeroForOne);
        stopLossHook.placeOrder{value: 1 ether}(poolKey, tick, positionAmount, zeroForOne);
        assertEq(positionAmount, stopLossHook.balanceOf(user1, tokenIdAtPosition));
        assertEq(stopLossHook.getGasBalancesAmount(user1), 1 ether);
        vm.stopPrank();

        //a different user executes the swap
        vm.startPrank(user2);

        // Approve for swapping
        uint256 swapAmount = 1 ether;
        token0.approve(address(swapRouter), swapAmount);
        token1.approve(address(swapRouter), swapAmount);

        //set gas price, the default in foundry is 0
        vm.txGasPrice(1);

        uint256 user1GasBalanceBefore = stopLossHook.getGasBalancesAmount(user1);
        uint256 user2GasBalanceBefore = stopLossHook.getGasBalancesAmount(user2);

        //pass the swap executor address into hookData so that it is available downstream
        bytes memory hookData = abi.encodePacked(user2);
        swap(poolKey, 1 ether, !zeroForOne, hookData);

        vm.stopPrank();

        //check that the stop loss order was filled as expected
        int256 tokensLeftToSell = stopLossHook.stopLossPositions(poolId, tick, zeroForOne);
        assertEq(tokensLeftToSell, 0);

        //check if user1's deposit was used to pay for the hook execution
        //the deposit was sent in when the position was opened
        uint256 user1GasBalanceAfter = stopLossHook.getGasBalancesAmount(user1);
        uint256 user2GasBalanceAfter = stopLossHook.getGasBalancesAmount(user2);

        //user1 should have lost some balance to pay for the execution of the stopLoss swap
        assertGt(user1GasBalanceBefore, user1GasBalanceAfter);
        //user2 should have gained balance since they executed the swap
        assertGt(user2GasBalanceAfter, user2GasBalanceBefore);

    }

    function testOrderExecuteZeroForOneMultiplePositions() public {
        int24 tick = -300;
        uint256 amount =  0.1 ether;
        bool zeroForOne = false;

        //open two stopLoss positions, splitting the amount between them
        //if the price of the asset drops, sell more -- that is the idea here
        token1.approve(address(stopLossHook), amount);
        int24 tickUpper = stopLossHook.placeOrder{value: 1 ether}(poolKey, tick, amount / 2, zeroForOne);
        tickUpper = stopLossHook.placeOrder(poolKey, tick * 2, amount / 2, zeroForOne);

        swap(poolKey, 1 ether, !zeroForOne, ZERO_BYTES);

        //check that both the orders were filled
        int256 tokensLeftToSell = stopLossHook.stopLossPositions(poolId, tick, zeroForOne);
        assertEq(tokensLeftToSell, 0);
        tokensLeftToSell = stopLossHook.stopLossPositions(poolId, tick * 2, zeroForOne);
        assertEq(tokensLeftToSell, 0);
    }

    //since the test contract acts as an active actor, we need these:
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

}
