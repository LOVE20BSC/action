// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockUniswapV2Pair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 private _totalSupply;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function mint(address) external returns (uint256 liquidity) {
        liquidity = 1000;
        _totalSupply += liquidity;
        reserve0 = 5000;
        reserve1 = 5000;
        blockTimestampLast = uint32(block.timestamp);
        return liquidity;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external view returns (uint256) {
        return _totalSupply;
    }
}

contract MockUniswapV2Router {
    function addLiquidity(address, address, uint256, uint256, uint256, uint256, address, uint256)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return (0, 0, 0);
    }

    function removeLiquidity(address, address, uint256, uint256, uint256, address, uint256)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}
