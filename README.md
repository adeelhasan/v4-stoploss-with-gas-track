
# V4 StopLoss Hook with Gas Accountability

### Introduction

The TakeProfit hook was altered to be a stop loss hook. If the tick range decreases into the range where an swap order has been placed, then it is executed.

### Gas Accounting

V4 hooks are executed in the context of the transaction initator. If a stop loss order is triggered, it will thus be paid for by the initiator of the swap which caused the tick range to change. This means that the stop loss order will effectively get a free ride, gas paid for by the original swap initiator.

This hook aims to mitigate this by requiring an eth deposit when the stop loss order is placed. When the order is triggered, the deposit is transferred to the original swap initiator.

Eth deposits can be added or removed at any time, however the condition is that if there is an outstanding stop loss position, then a minimum deposit should be used.

### Main Test



### Acknowledgements
1. based on the [v4-template](https://github.com/saucepoint/v4-template) by @saucepoint
2. LearnWeb3's [TakeProfit hook lesson](https://learnweb3.io/lessons/uniswap-v4-hooks-create-a-fully-on-chain-take-profit-orders-hook-on-uniswap-v4)
3. also based on  [v4-stoploss](https://github.com/saucepoint/v4-stoploss)
4. the ERC 4337 entry point contract's gas accounting design




