// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback}  from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks}           from "v4-core/interfaces/IHooks.sol";
import {PoolKey}          from "v4-core/types/PoolKey.sol";
import {Currency}         from "v4-core/types/Currency.sol";
import {BalanceDelta}     from "v4-core/types/BalanceDelta.sol";
import {TickMath}         from "v4-core/libraries/TickMath.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Minimal swap router for the BCC/WETH v4 pool.
///
/// Wraps/unwraps WETH so users transact in native ETH. Single pool, single
/// hook — no command encoding, no path-finding, no multi-hop. Just buy() and
/// sell() with slippage + deadline. Quotes happen frontend-side from sqrtPriceX96.
contract ComradeSwap is IUnlockCallback {
    IPoolManager public immutable poolManager;
    IWETH9       public immutable weth;
    IERC20Min    public immutable comrade;
    PoolKey      public key;

    error Expired();
    error InsufficientOutput();
    error WrongCallback();
    error EthRefundFailed();

    struct CB {
        address sender;
        bool    isBuy;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(IPoolManager _pm, IWETH9 _weth, IERC20Min _comrade, PoolKey memory _key) {
        poolManager = _pm;
        weth = _weth;
        comrade = _comrade;
        key = _key;
        require(address(_comrade) < address(_weth), "BCC must be token0");
    }

    /// @notice Buy an EXACT number of BCC, pay up to msg.value ETH. Refund the rest.
    /// Forces whole-BCC outputs so each unit corresponds to a real Comrade NFT.
    function buy(uint256 bccOut, uint256 maxEthIn, uint256 deadline) external payable returns (uint256 ethSpent) {
        if (block.timestamp > deadline) revert Expired();
        require(msg.value >= maxEthIn, "msg.value < maxEthIn");
        // Encoding: amountIn field carries the exact-output bcc target,
        // minOut field carries maxEthIn (interpreted as "max input" in callback).
        ethSpent = abi.decode(
            poolManager.unlock(abi.encode(CB(msg.sender, true, bccOut, maxEthIn))),
            (uint256)
        );
    }

    /// @notice Sell BCC for ETH. User must approve this contract for `bccAmount`.
    function sell(uint256 bccAmount, uint256 minEthOut, uint256 deadline) external returns (uint256 ethOut) {
        if (block.timestamp > deadline) revert Expired();
        require(comrade.transferFrom(msg.sender, address(this), bccAmount), "BCC transferFrom");
        ethOut = abi.decode(
            poolManager.unlock(abi.encode(CB(msg.sender, false, bccAmount, minEthOut))),
            (uint256)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert WrongCallback();
        CB memory p = abi.decode(raw, (CB));

        // BCC=token0, WETH=token1.
        // Buy:  zeroForOne=false, EXACT-OUTPUT (positive amountSpecified = bcc target)
        // Sell: zeroForOne=true,  EXACT-INPUT  (negative amountSpecified = bcc paid)
        bool zeroForOne = !p.isBuy;
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   p.isBuy ? int256(p.amountIn) : -int256(p.amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(key, sp, "");
        int256 d0 = int256(delta.amount0());
        int256 d1 = int256(delta.amount1());

        if (p.isBuy) {
            // Exact-output: pool consumed -d1 WETH, returned +d0 BCC (= bccOut target).
            uint256 wethOwed = uint256(-d1);
            // Slippage guard: maxEthIn was passed in p.minOut
            if (wethOwed > p.minOut) revert InsufficientOutput();
            weth.deposit{value: wethOwed}();
            weth.transfer(address(poolManager), wethOwed);
            poolManager.settle();

            uint256 bccOut = uint256(d0);
            poolManager.take(key.currency0, p.sender, bccOut);

            // Refund any leftover ETH
            if (address(this).balance > 0) {
                (bool ok,) = p.sender.call{value: address(this).balance}("");
                if (!ok) revert EthRefundFailed();
            }
            return abi.encode(wethOwed);  // return ETH spent (frontend can show)
        } else {
            // Owe BCC (token0, negative), receive WETH (token1, positive).
            uint256 bccOwed = uint256(-d0);
            comrade.transfer(address(poolManager), bccOwed);
            poolManager.settle();

            uint256 wethRecv = uint256(d1);
            if (wethRecv < p.minOut) revert InsufficientOutput();
            poolManager.take(key.currency1, address(this), wethRecv);
            weth.withdraw(wethRecv);

            (bool ok,) = p.sender.call{value: wethRecv}("");
            if (!ok) revert EthRefundFailed();
            return abi.encode(wethRecv);
        }
    }

    receive() external payable {}
}
