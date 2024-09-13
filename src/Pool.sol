// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IFactory {
    function getExchange(address token) external view returns (address);
}

contract ShillerPool is ERC20 {
    IERC20 public token;
    IFactory public factory;

    event TokenPurchase(address indexed buyer, uint256 indexed eth_sold, uint256 indexed tokens_bought);
    event EthPurchase(address indexed buyer, uint256 indexed tokens_sold, uint256 indexed eth_bought);
    event AddLiquidity(address indexed provider, uint256 indexed eth_amount, uint256 indexed token_amount);
    event RemoveLiquidity(address indexed provider, uint256 indexed eth_amount, uint256 indexed token_amount);
    event TokenAirdrop(address indexed buyer, uint256 eth_sold, uint256 indexed tokens_airdrop, address indexed referrer);

    uint256 public maxAirdropPerAddress;
    uint256 public airdropPercentBps;
    uint256 public maxAirdrop;
    uint256 public totalAirdrops;
    uint256 public minimumReferrerBalance;

    mapping (address => bool) public airdropReceived;

    constructor() ERC20("Shiller Pool V1", "SHL-V1") {
        // The constructor is empty because we'll use a setup function
    }

    function setup(address token_addr, uint256 _maxAirdropPerAddress, uint256 _airdropPercentBps, uint256 _maxAirdrops, uint256 _minimumReferrerBalance) public {
        require(address(factory) == address(0) && address(token) == address(0));
        require(token_addr != address(0));
        factory = IFactory(msg.sender);
        token = IERC20(token_addr);
        maxAirdropPerAddress = _maxAirdropPerAddress;
        airdropPercentBps = _airdropPercentBps;
        maxAirdrop = _maxAirdrops;
        minimumReferrerBalance = _minimumReferrerBalance;
    }

    function addLiquidity(uint256 min_liquidity, uint256 max_tokens, uint256 deadline) 
        public payable returns (uint256) 
    {
        require(deadline > block.timestamp && max_tokens > 0 && msg.value > 0, "Invalid input");
        uint256 total_liquidity = totalSupply();

        if (total_liquidity > 0) {
            require(min_liquidity > 0, "Min liquidity must be > 0");
            uint256 eth_reserve = address(this).balance - msg.value;
            uint256 token_reserve = token.balanceOf(address(this));
            uint256 token_amount = (msg.value * token_reserve / eth_reserve) + 1;
            uint256 liquidity_minted = msg.value * total_liquidity / eth_reserve;
            require(max_tokens >= token_amount && liquidity_minted >= min_liquidity, "Insufficient output amount");
            _mint(msg.sender, liquidity_minted);
            require(token.transferFrom(msg.sender, address(this), token_amount), "TransferFrom failed");
            emit AddLiquidity(msg.sender, msg.value, token_amount);
            emit Transfer(address(0), msg.sender, liquidity_minted);
            return liquidity_minted;
        } else {
            require(address(factory) != address(0) && address(token) != address(0) && msg.value >= 1000000000, "Invalid state");
            require(factory.getExchange(address(token)) == address(this), "Invalid exchange");
            uint256 token_amount = max_tokens;
            uint256 initial_liquidity = address(this).balance;
            _mint(msg.sender, initial_liquidity);
            require(token.transferFrom(msg.sender, address(this), token_amount), "TransferFrom failed");
            emit AddLiquidity(msg.sender, msg.value, token_amount);
            emit Transfer(address(0), msg.sender, initial_liquidity);
            return initial_liquidity;
        }
    }

    function removeLiquidity(uint256 amount, uint256 min_eth, uint256 min_tokens, uint256 deadline) 
        public returns (uint256, uint256) 
    {
        require(amount > 0 && deadline > block.timestamp && min_eth > 0 && min_tokens > 0, "Invalid input");
        uint256 total_liquidity = totalSupply();
        require(total_liquidity > 0, "No liquidity");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 eth_amount = amount * address(this).balance / total_liquidity;
        uint256 token_amount = amount * token_reserve / total_liquidity;
        require(eth_amount >= min_eth && token_amount >= min_tokens, "Insufficient output amount");
        
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(eth_amount);
        require(token.transfer(msg.sender, token_amount), "Token transfer failed");
        emit RemoveLiquidity(msg.sender, eth_amount, token_amount);
        emit Transfer(msg.sender, address(0), amount);
        return (eth_amount, token_amount);
    }

    function getInputPrice(uint256 input_amount, uint256 input_reserve, uint256 output_reserve) 
        private pure returns (uint256) 
    {
        require(input_reserve > 0 && output_reserve > 0, "Invalid reserves");
        uint256 input_amount_with_fee = input_amount * 997;
        uint256 numerator = input_amount_with_fee * output_reserve;
        uint256 denominator = (input_reserve * 1000) + input_amount_with_fee;
        return numerator / denominator;
    }

    function getOutputPrice(uint256 output_amount, uint256 input_reserve, uint256 output_reserve) 
        private pure returns (uint256) 
    {
        require(input_reserve > 0 && output_reserve > 0, "Invalid reserves");
        uint256 numerator = input_reserve * output_amount * 1000;
        uint256 denominator = (output_reserve - output_amount) * 997;
        return (numerator / denominator) + 1;
    }

    function ethToTokenInput(uint256 eth_sold, uint256 min_tokens, uint256 deadline, address buyer, address recipient) 
        private returns (uint256) 
    {
        require(deadline >= block.timestamp && eth_sold > 0 && min_tokens > 0, "Invalid input");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 tokens_bought = getInputPrice(eth_sold, address(this).balance - eth_sold, token_reserve);
        require(tokens_bought >= min_tokens, "Insufficient output amount");
        require(token.transfer(recipient, tokens_bought), "Transfer failed");
        emit TokenPurchase(buyer, eth_sold, tokens_bought);
        return tokens_bought;
    }

    receive() external payable {
        ethToTokenInput(msg.value, 1, block.timestamp, msg.sender, msg.sender);
    }

    function ethToTokenSwapInput(uint256 min_tokens, uint256 deadline) 
        public payable returns (uint256) 
    {
        return ethToTokenInput(msg.value, min_tokens, deadline, msg.sender, msg.sender);
    }

    function ethToTokenTransferInput(uint256 min_tokens, uint256 deadline, address recipient) 
        public payable returns (uint256) 
    {
        require(recipient != address(this) && recipient != address(0), "Invalid recipient");
        return ethToTokenInput(msg.value, min_tokens, deadline, msg.sender, recipient);
    }

    function ethToTokenOutput(uint256 tokens_bought, uint256 max_eth, uint256 deadline, address buyer, address recipient) 
        private returns (uint256) 
    {
        require(deadline >= block.timestamp && tokens_bought > 0 && max_eth > 0, "Invalid input");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 eth_sold = getOutputPrice(tokens_bought, address(this).balance - max_eth, token_reserve);
        uint256 eth_refund = max_eth - eth_sold;
        if (eth_refund > 0) {
            payable(buyer).transfer(eth_refund);
        }
        require(token.transfer(recipient, tokens_bought), "Transfer failed");
        emit TokenPurchase(buyer, eth_sold, tokens_bought);
        return eth_sold;
    }

    function ethToTokenSwapOutput(uint256 tokens_bought, uint256 deadline) 
        public payable returns (uint256) 
    {
        return ethToTokenOutput(tokens_bought, msg.value, deadline, msg.sender, msg.sender);
    }

    function ethToTokenTransferOutput(uint256 tokens_bought, uint256 deadline, address recipient) 
        public payable returns (uint256) 
    {
        require(recipient != address(this) && recipient != address(0), "Invalid recipient");
        return ethToTokenOutput(tokens_bought, msg.value, deadline, msg.sender, recipient);
    }

    function tokenToEthInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline, address buyer, address recipient) 
        private returns (uint256) 
    {
        require(deadline >= block.timestamp && tokens_sold > 0 && min_eth > 0, "Invalid input");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 eth_bought = getInputPrice(tokens_sold, token_reserve, address(this).balance);
        require(eth_bought >= min_eth, "Insufficient output amount");
        payable(recipient).transfer(eth_bought);
        require(token.transferFrom(buyer, address(this), tokens_sold), "TransferFrom failed");
        emit EthPurchase(buyer, tokens_sold, eth_bought);
        return eth_bought;
    }

    function tokenToEthSwapInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline) 
        public returns (uint256) 
    {
        return tokenToEthInput(tokens_sold, min_eth, deadline, msg.sender, msg.sender);
    }

    function tokenToEthTransferInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline, address recipient) 
        public returns (uint256) 
    {
        require(recipient != address(this) && recipient != address(0), "Invalid recipient");
        return tokenToEthInput(tokens_sold, min_eth, deadline, msg.sender, recipient);
    }

    function tokenToEthOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline, address buyer, address recipient) 
        private returns (uint256) 
    {
        require(deadline >= block.timestamp && eth_bought > 0, "Invalid input");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 tokens_sold = getOutputPrice(eth_bought, token_reserve, address(this).balance);
        require(max_tokens >= tokens_sold, "Insufficient input amount");
        payable(recipient).transfer(eth_bought);
        require(token.transferFrom(buyer, address(this), tokens_sold), "TransferFrom failed");
        emit EthPurchase(buyer, tokens_sold, eth_bought);
        return tokens_sold;
    }

    function tokenToEthSwapOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline) 
        public returns (uint256) 
    {
        return tokenToEthOutput(eth_bought, max_tokens, deadline, msg.sender, msg.sender);
    }

    function tokenToEthTransferOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline, address recipient) 
        public returns (uint256) 
    {
        require(recipient != address(this) && recipient != address(0), "Invalid recipient");
        return tokenToEthOutput(eth_bought, max_tokens, deadline, msg.sender, recipient);
    }

    function tokenToTokenInput(
        uint256 tokens_sold, 
        uint256 min_tokens_bought, 
        uint256 min_eth_bought, 
        uint256 deadline, 
        address buyer, 
        address recipient, 
        address payable exchange_addr
    ) private returns (uint256) {
        require(deadline >= block.timestamp && tokens_sold > 0 && min_tokens_bought > 0 && min_eth_bought > 0, "Invalid input");
        require(exchange_addr != address(this) && exchange_addr != address(0), "Invalid exchange address");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 eth_bought = getInputPrice(tokens_sold, token_reserve, address(this).balance);
        require(eth_bought >= min_eth_bought, "Insufficient ETH bought");
        require(token.transferFrom(buyer, address(this), tokens_sold), "TransferFrom failed");
        uint256 tokens_bought = ShillerPool(exchange_addr).ethToTokenTransferInput{value: eth_bought}(min_tokens_bought, deadline, recipient);
        emit EthPurchase(buyer, tokens_sold, eth_bought);
        return tokens_bought;
    }

    function tokenToTokenSwapInput(
        uint256 tokens_sold,
        uint256 min_tokens_bought,
        uint256 min_eth_bought,
        uint256 deadline,
        address token_addr
    ) public returns (uint256) {
        address payable exchange_addr = payable(factory.getExchange(token_addr));
        return tokenToTokenInput(tokens_sold, min_tokens_bought, min_eth_bought, deadline, msg.sender, msg.sender, exchange_addr);
    }

    function tokenToTokenTransferInput(
        uint256 tokens_sold,
        uint256 min_tokens_bought,
        uint256 min_eth_bought,
        uint256 deadline,
        address recipient,
        address token_addr
    ) public returns (uint256) {
        address payable exchange_addr = payable(factory.getExchange(token_addr));
        return tokenToTokenInput(tokens_sold, min_tokens_bought, min_eth_bought, deadline, msg.sender, recipient, exchange_addr);
    }

    // Public price functions
    function getEthToTokenInputPrice(uint256 eth_sold) public view returns (uint256) {
        require(eth_sold > 0, "Invalid ETH amount");
        uint256 token_reserve = token.balanceOf(address(this));
        return getInputPrice(eth_sold, address(this).balance, token_reserve);
    }

    function getEthToTokenOutputPrice(uint256 tokens_bought) public view returns (uint256) {
        require(tokens_bought > 0, "Invalid token amount");
        uint256 token_reserve = token.balanceOf(address(this));
        return getOutputPrice(tokens_bought, address(this).balance, token_reserve);
    }

    function getTokenToEthInputPrice(uint256 tokens_sold) public view returns (uint256) {
        require(tokens_sold > 0, "Invalid token amount");
        uint256 token_reserve = token.balanceOf(address(this));
        return getInputPrice(tokens_sold, token_reserve, address(this).balance);
    }

    function getTokenToEthOutputPrice(uint256 eth_bought) public view returns (uint256) {
        require(eth_bought > 0, "Invalid ETH amount");
        uint256 token_reserve = token.balanceOf(address(this));
        return getOutputPrice(eth_bought, token_reserve, address(this).balance);
    }

    // Getter functions
    function tokenAddress() public view returns (address) {
        return address(token);
    }

    function factoryAddress() public view returns (address) {
        return address(factory);
    }

    // Airdrop swap input
    function ethToAirdropInput(uint256 eth_sold, uint256 min_tokens, uint256 deadline, address buyer, address recipient, address referrer) 
        private returns (uint256) 
    {
        require(airdropReceived[recipient] == false, "Airdrop received");
        require(deadline >= block.timestamp && eth_sold > 0 && min_tokens > 0, "Invalid input");
        uint256 token_reserve = token.balanceOf(address(this));
        uint256 tokens_bought = getInputPrice(eth_sold, address(this).balance - eth_sold, token_reserve);
        uint256 tokens_airdrop = (tokens_bought * (airdropPercentBps + 10000))/10000;
        require(tokens_airdrop >= min_tokens, "Insufficient output amount");
        require(totalAirdrops + tokens_airdrop <= maxAirdrop, "Airdrops exhausted");
        require(tokens_airdrop <= maxAirdropPerAddress, "Airdrop limit exceeded");


        require(token.transfer(recipient, tokens_airdrop), "Transfer failed");

        airdropReceived[recipient] = true;
        totalAirdrops += tokens_airdrop;

        if (token.balanceOf(referrer) >= minimumReferrerBalance) {
          token.transfer(referrer, tokens_airdrop - tokens_bought);
        }
        
        emit TokenAirdrop(buyer, eth_sold, tokens_airdrop - tokens_bought, referrer);
        return tokens_airdrop;
    }

    function airdropTokenSwapInput(uint256 min_tokens, uint256 deadline, address referrer) 
        public payable returns (uint256) 
    {
        return ethToAirdropInput(msg.value, min_tokens, deadline, msg.sender, msg.sender, referrer);
    }

}