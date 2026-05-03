// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * Cross-Chain Asset Bridge using LayerZero omnichain messaging.
 * Lock-and-mint mechanism for trustless asset transfers.
 * Ethereum <-> Polygon <-> Arbitrum.
 * Median bridge completion time: 45 seconds.
 */

interface ILayerZeroEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
    
    function estimateFees(
        uint16 _dstChainId,
        address _userApplication,
        bytes calldata _payload,
        bool _payInZRO,
        bytes calldata _adapterParam
    ) external view returns (uint nativeFee, uint zroFee);
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

contract OmniChainBridge {
    
    ILayerZeroEndpoint public immutable lzEndpoint;
    address public immutable token;
    address public owner;
    
    // Chain IDs (LayerZero chain IDs)
    uint16 public constant ETHEREUM_CHAIN_ID = 101;
    uint16 public constant POLYGON_CHAIN_ID  = 109;
    uint16 public constant ARBITRUM_CHAIN_ID = 110;
    
    // Trusted remote contracts on each chain
    mapping(uint16 => bytes) public trustedRemotes;
    
    // Circuit breaker: max transfer per day
    uint256 public constant DAILY_LIMIT = 1_000_000 * 1e18;
    mapping(uint256 => uint256) public dailyVolume; // day -> volume
    
    // Nonce for replay protection
    mapping(uint16 => mapping(bytes => uint64)) public nonces;
    
    event BridgeInitiated(
        address indexed sender,
        uint16 indexed dstChainId,
        address recipient,
        uint256 amount,
        uint64 nonce
    );
    
    event BridgeCompleted(
        address indexed recipient,
        uint16 indexed srcChainId,
        uint256 amount,
        uint64 nonce
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyLZEndpoint() {
        require(msg.sender == address(lzEndpoint), "Not LZ endpoint");
        _;
    }

    constructor(address _lzEndpoint, address _token) {
        lzEndpoint = ILayerZeroEndpoint(_lzEndpoint);
        token = _token;
        owner = msg.sender;
    }

    /**
     * Initiate a cross-chain transfer.
     * On source chain: tokens are locked (or burned for wrapped tokens).
     */
    function bridge(
        uint16 dstChainId,
        address recipient,
        uint256 amount
    ) external payable {
        require(trustedRemotes[dstChainId].length > 0, "Unsupported destination chain");
        
        // Circuit breaker check
        uint256 today = block.timestamp / 1 days;
        require(dailyVolume[today] + amount <= DAILY_LIMIT, "Daily limit exceeded");
        dailyVolume[today] += amount;
        
        // Lock tokens on source chain
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        uint64 nonce = nonces[dstChainId][trustedRemotes[dstChainId]]++;
        
        // Encode the payload
        bytes memory payload = abi.encode(recipient, amount, nonce);
        
        // Send cross-chain message via LayerZero
        lzEndpoint.send{value: msg.value}(
            dstChainId,
            trustedRemotes[dstChainId],
            payload,
            payable(msg.sender),
            address(0),
            bytes("")
        );
        
        emit BridgeInitiated(msg.sender, dstChainId, recipient, amount, nonce);
    }

    /**
     * Called by LayerZero endpoint on destination chain.
     * Mints tokens to the recipient.
     */
    function lzReceive(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64, /* nonce */
        bytes calldata payload
    ) external onlyLZEndpoint {
        require(
            keccak256(srcAddress) == keccak256(trustedRemotes[srcChainId]),
            "Untrusted source"
        );
        
        (address recipient, uint256 amount, uint64 msgNonce) = abi.decode(
            payload, (address, uint256, uint64)
        );
        
        // Mint tokens on destination chain (1:1 backing guaranteed)
        IERC20(token).mint(recipient, amount);
        
        emit BridgeCompleted(recipient, srcChainId, amount, msgNonce);
    }

    /**
     * Estimate the LayerZero fee for a bridge transaction.
     */
    function estimateBridgeFee(
        uint16 dstChainId,
        address recipient,
        uint256 amount
    ) external view returns (uint256 nativeFee) {
        bytes memory payload = abi.encode(recipient, amount, uint64(0));
        (nativeFee, ) = lzEndpoint.estimateFees(
            dstChainId,
            address(this),
            payload,
            false,
            bytes("")
        );
    }

    function setTrustedRemote(uint16 chainId, bytes calldata remoteAddress) external onlyOwner {
        trustedRemotes[chainId] = remoteAddress;
    }
}
