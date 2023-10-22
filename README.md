
# V4 StopLoss Hook with Gas Accountability

### Introduction

The TakeProfit hook was altered to be a stop loss hook. If the tick range decreases into the range where an swap order has been placed, then it is executed.

### Gas Accounting

V4 hooks are executed in the context of the transaction initator. If a stop loss order is triggered, it will thus be paid for by the initiator of the swap which caused the tick range to change. This means that the stop loss order will effectively get a free ride, gas paid for by the original swap initiator.

This hook aims to mitigate this by requiring an eth deposit when the stop loss order is placed. When the order is triggered, the deposit is transferred to the original swap initiator.

Eth deposits can be added or removed at any time, however the condition is that if there is an outstanding stop loss position, then a minimum deposit should be used.

### Main Test

```
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
```

### Future Work
- trailing stop loss -- the stop position could move up into higher tick ranges and maintain a tick distance of a threshold
- generalized gas accounting -- the fact that all hooks will be paid for by a transaction executor will lead to instances where this execution-tax will be a disincentive to participate. There is room to make the hook funding more generalized so that it can be used as a design pattern. Or that there are other ways of accounting for this, eg. through signatures


### Acknowledgements
1. based on the [v4-template](https://github.com/saucepoint/v4-template) by @saucepoint
2. LearnWeb3's [TakeProfit hook lesson](https://learnweb3.io/lessons/uniswap-v4-hooks-create-a-fully-on-chain-take-profit-orders-hook-on-uniswap-v4)
3. also based on  [v4-stoploss](https://github.com/saucepoint/v4-stoploss)
4. the ERC 4337 entry point contract's gas accounting design




