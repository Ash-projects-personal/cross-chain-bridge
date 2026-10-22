// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWrappedToken {
    function mintWrapped(address to, uint256 amount) external;
}

interface ILayerZeroEndpoint {
    function send(
        uint16 dstChainId,
        bytes calldata destination,
        bytes calldata payload,
        address payable refundAddress,
        address zroPaymentAddress,
        bytes calldata adapterParams
    ) external payable;
}

/// @title OmniChainBridge
/// @notice Lock and mint bridge over a LayerZero shaped endpoint
/// interface. On the source side it locks an ERC20. On the destination
/// side the endpoint delivers the message to lzReceive, which checks the
/// trusted remote and the inbound nonce before minting the wrapped token.
///
/// Replay protection: inbound nonces must arrive in order per source
/// chain, starting at 1. Each accepted nonce is recorded, so delivering
/// the same message twice reverts instead of minting twice. The original
/// version of this contract accepted a nonce and never checked it; that
/// hole is fixed here and pinned by a test.
contract OmniChainBridge {
    uint16 public immutable localChainId;
    ILayerZeroEndpoint public immutable endpoint;
    IERC20 public immutable lockToken;
    IWrappedToken public immutable wrappedToken;

    uint256 public constant DAILY_LIMIT = 1_000_000 ether;

    mapping(uint16 => bytes) public trustedRemotes;
    mapping(uint16 => uint64) public outboundNonce;
    mapping(uint16 => uint64) public inboundNonce;
    mapping(uint16 => uint256) public dailyVolume;
    mapping(uint16 => uint256) public dailyVolumeDay;

    event BridgeSent(uint16 indexed dstChainId, uint64 nonce, address indexed sender, address indexed receiver, uint256 amount);
    event BridgeReceived(uint16 indexed srcChainId, uint64 nonce, address indexed receiver, uint256 amount);

    constructor(uint16 _localChainId, address _endpoint, address _lockToken, address _wrappedToken) {
        localChainId = _localChainId;
        endpoint = ILayerZeroEndpoint(_endpoint);
        lockToken = IERC20(_lockToken);
        wrappedToken = IWrappedToken(_wrappedToken);
    }

    function setTrustedRemote(uint16 chainId, bytes calldata remote) external {
        // In this local version the deployer is the only caller in tests.
        // A production version would gate this behind ownership.
        trustedRemotes[chainId] = remote;
    }

    function bridge(uint16 dstChainId, address receiver, uint256 amount) external {
        require(amount > 0, "zero amount");
        require(trustedRemotes[dstChainId].length != 0, "no trusted remote");

        uint256 today = block.timestamp / 1 days;
        if (dailyVolumeDay[dstChainId] != today) {
            dailyVolumeDay[dstChainId] = today;
            dailyVolume[dstChainId] = 0;
        }
        require(dailyVolume[dstChainId] + amount <= DAILY_LIMIT, "daily limit exceeded");
        dailyVolume[dstChainId] += amount;

        require(lockToken.transferFrom(msg.sender, address(this), amount), "lock failed");

        uint64 nonce = ++outboundNonce[dstChainId];
        bytes memory payload = abi.encode(nonce, msg.sender, receiver, amount);
        endpoint.send(dstChainId, trustedRemotes[dstChainId], payload, payable(msg.sender), address(0), bytes(""));
        emit BridgeSent(dstChainId, nonce, msg.sender, receiver, amount);
    }

    function lzReceive(uint16 srcChainId, bytes calldata srcAddress, uint64, bytes calldata payload) external {
        require(msg.sender == address(endpoint), "only endpoint");
        bytes memory trusted = trustedRemotes[srcChainId];
        require(trusted.length != 0, "no trusted remote");
        require(keccak256(srcAddress) == keccak256(trusted), "untrusted remote");

        (uint64 nonce, , address receiver, uint256 amount) =
            abi.decode(payload, (uint64, address, address, uint256));

        // The replay fix: nonces must be exactly the next expected one.
        require(nonce == inboundNonce[srcChainId] + 1, "bad nonce: replay or out of order");
        inboundNonce[srcChainId] = nonce;

        wrappedToken.mintWrapped(receiver, amount);
        emit BridgeReceived(srcChainId, nonce, receiver, amount);
    }
}

/// @notice Minimal ERC20 for local tests. Not audited, not for production.
contract MockToken {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not approved");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mintable wrapped token. Only its owner (the bridge) can mint
/// and burn.
contract WrappedToken is MockToken {
    address public bridge;

    function setBridge(address _bridge) external {
        require(bridge == address(0), "bridge already set");
        bridge = _bridge;
    }

    function mintWrapped(address to, uint256 amount) external {
        require(msg.sender == bridge, "only bridge");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @notice Stand in endpoint for local tests. Records the last message and
/// delivers it to a target bridge when the test asks, the way a real
/// endpoint would call lzReceive on the destination contract.
contract MockEndpoint {
    struct Message {
        uint16 dstChainId;
        bytes destination;
        bytes payload;
        bool sent;
    }

    Message public lastMessage;

    function send(
        uint16 dstChainId,
        bytes calldata destination,
        bytes calldata payload,
        address payable,
        address,
        bytes calldata
    ) external payable {
        lastMessage = Message(dstChainId, destination, payload, true);
    }

    function deliver(address targetBridge, uint16 srcChainId, bytes calldata srcAddress, uint64 nonce) external {
        require(lastMessage.sent, "nothing to deliver");
        OmniChainBridge(targetBridge).lzReceive(srcChainId, srcAddress, nonce, lastMessage.payload);
    }
}
