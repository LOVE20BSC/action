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
    mapping(address => uint256) private _balanceOf;
    mapping(address => mapping(address => uint256)) private _allowance;
    bool public failTransferFrom;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setFailTransferFrom(bool failTransferFrom_) external {
        failTransferFrom = failTransferFrom_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function mint(address to) external returns (uint256 liquidity) {
        liquidity = 1000;
        _totalSupply += liquidity;
        _balanceOf[to] += liquidity;
        reserve0 = 5000;
        reserve1 = 5000;
        blockTimestampLast = uint32(block.timestamp);
        return liquidity;
    }

    function mintTo(address to, uint256 amount) external {
        _totalSupply += amount;
        _balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balanceOf[msg.sender] -= amount;
        _balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransferFrom) {
            return false;
        }
        uint256 allowed = _allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            _allowance[from][msg.sender] = allowed - amount;
        }
        _balanceOf[from] -= amount;
        _balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
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
