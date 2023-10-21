// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "forge-std/console.sol";
import "forge-std/console2.sol";

contract StopLossHook is BaseHook, ERC1155 {

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId => int24 tickUpper) public tickUpperLasts;

    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public stopLossPositions;

    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    uint256 constant MIN_PREPAY_BALANCE = 100; // in wei
    mapping(address user => uint256) public gasBalances;
    mapping(uint256 tokenId => address[]) public positionOwners;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}


    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: true,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _setTickUpperLast(key.toId(), _getTickUpper(tick, key.tickSpacing));
        return StopLossHook.afterInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {

        address hookInitiator;
        if (hookData.length == 20)
            hookInitiator = address(uint160(bytes20(hookData)));

        int24 lastTickUpper = tickUpperLasts[key.toId()];
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 currentTickUpper = _getTickUpper(currentTick, key.tickSpacing);

        //bool swapZeroForOne = !params.zeroForOne;
        int256 totalAmountAtTick;
        uint256 gasVar;

        if (lastTickUpper > currentTickUpper) {
            //sell positions through the range the price just moved
            //price has moved into a lower range
            for (int24 tickIndex = lastTickUpper;  currentTickUpper < tickIndex; ) {
                totalAmountAtTick = stopLossPositions[key.toId()][tickIndex][!params.zeroForOne];
                if (totalAmountAtTick > 0) {
                    //console.log("filling an order at");
                    //console2.log("upper tick index", tickIndex);
                    gasVar = gasleft();
                    fillOrder(key, tickIndex, !params.zeroForOne, totalAmountAtTick);
                    uint256 gasConsumed = (gasVar - gasleft()) * getGasPrice();
                    //console.log("Gas Consumed: ", gasConsumed);
                    if (hookInitiator != address(0)) {
                        gasBalances[positionOwners[getTokenId(key, tickIndex, !params.zeroForOne)][0]] -= gasConsumed;
                        gasBalances[hookInitiator] += gasConsumed;
                    }
                    //tokenId = getTokenId(key, tickIndex, swapZeroForOne);
                    // {
                    //     for (uint256 ownerIndex; ownerIndex < positionOwners[tokenId].length; ownerIndex++) {
                    //         address positionOwner = positionOwners[tokenId][ownerIndex];
                    //         gasBalances[positionOwner] -= gasCost;
                    //         console.log("gas cost: ", gasCost);
                    //     }
                    // }
                    //delete positionOwners[tokenId] ;
                }
                tickIndex -= key.tickSpacing;
            }
        }
        else {
            //the price moved into a higher range
            //in this case, see if the stop loss needs to be moved up
            
            console.log("tick moved up conditional");
            // TBD
        }

        return StopLossHook.afterSwap.selector;

    }

    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    )   external payable returns (int24) {

        //TBD if there is already a position, then 
        //the deposit is not needed, should be covered from before        
        if (msg.value == 0)
            require(gasBalances[msg.sender] > MIN_PREPAY_BALANCE, "no deposit");
        else
        {
            require(msg.value > MIN_PREPAY_BALANCE, "no deposit and no prepayment sent");
            gasBalances[msg.sender] += msg.value;
        }
        
        int24 tickUpper = _getTickUpper(tick, key.tickSpacing);
        stopLossPositions[key.toId()][tickUpper][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tickUpper, zeroForOne);

        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickUpper, zeroForOne);
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenToBeSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        
        IERC20(tokenToBeSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        address[] memory ownersOfPosition  = positionOwners[tokenId];
        bool found = false;
        for (uint256 index; (index < ownersOfPosition.length) && !found; index++) {
            if (ownersOfPosition[index] == msg.sender) {
                found = true;
                continue;
            }
        }
        if (!found)
            positionOwners[tokenId].push(msg.sender);

        return tickUpper;
    }

    function fillOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO -1
        });
        BalanceDelta delta = abi.decode(
            poolManager.lock(
                abi.encodeCall(this.handleSwap, (key, swapParams))
            ),
            (BalanceDelta)
        );

        stopLossPositions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));

        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;
    }

    //this will remain the same in most of the trading order types
    //the post swap settlement is the same
    //this executes the trailing stop loss order, and sells the positions
    //this will also then directly decrease the price / change the price
    //meaning we have to monitor the price...is that some kind of recursion?
    //centralized exchanges would also need to deal with some flavor of this
    function handleSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external returns (BalanceDelta) {
        //actual swap happens here, as a result of the stopLoss order, which is a sell
        BalanceDelta delta = poolManager.swap(key, params, "");

        //the rest settles the swap
        //console.log("here in the swap handler", params.zeroForOne);
        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    uint128(delta.amount0())
                );
                poolManager.settle(key.currency0);
            }
        } else {
            // Same as above
            // If we owe Uniswap Token 1, we need to send them the required amount
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(delta.amount1())
                );
                poolManager.settle(key.currency1);
            }

            // If we are owed Token 0, we take it from the Pool Manager
            if (delta.amount0() < 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(-delta.amount0())
                );
            }
        }

        return delta;        
    }


    function getTokenId(
        PoolKey calldata key,
        int24 tickUpper,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encodePacked(key.toId(), tickUpper, zeroForOne))
            );
    }

    // Utility Helpers
    function _getTickLower(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }
    
    function _setTickUpperLast(PoolId poolId, int24 tickUpper) private {
        tickUpperLasts[poolId] = tickUpper;
    }

    function _getTickUpper(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick > 0 && actualTick % tickSpacing != 0) intervals++;
        return intervals * tickSpacing;
    }

    function depositGasBalance() external payable {
        gasBalances[msg.sender] += msg.value;
    }

    function withdrawGasBalance(uint256 amount) external {
        uint256 currentBalance = gasBalances[msg.sender];
        require(currentBalance > amount, "not enough balance");
        gasBalances[msg.sender] -= amount;

    }

    function getGasPrice() public view returns (uint256) {
        uint256 gasPrice;
        assembly {
            gasPrice := gasprice()
        }
        return gasPrice;
    }
}