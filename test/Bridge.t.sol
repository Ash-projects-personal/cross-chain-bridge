// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/OmniChainBridge.sol";

interface Vm {
    function prank(address) external;
    function expectRevert() external;
}

contract BridgeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint16 constant CHAIN_A = 101;
    uint16 constant CHAIN_B = 109;

    MockEndpoint endpoint;
    MockToken tokenA;
    WrappedToken wrappedB;
    OmniChainBridge bridgeA;
    OmniChainBridge bridgeB;
    address user = address(0x1234);
    address receiver = address(0xB0B);

    function check(bool cond, string memory m) internal pure {
        require(cond, m);
    }

    function setUp() public {
        endpoint = new MockEndpoint();
        tokenA = new MockToken();
        wrappedB = new WrappedToken();
        bridgeA = new OmniChainBridge(CHAIN_A, address(endpoint), address(tokenA), address(wrappedB));
        bridgeB = new OmniChainBridge(CHAIN_B, address(endpoint), address(tokenA), address(wrappedB));
        wrappedB.setBridge(address(bridgeB));
        bridgeA.setTrustedRemote(CHAIN_B, abi.encodePacked(address(bridgeB)));
        bridgeB.setTrustedRemote(CHAIN_A, abi.encodePacked(address(bridgeA)));
        tokenA.mint(user, 2_000_000 ether);
        vm.prank(user);
        tokenA.approve(address(bridgeA), 2_000_000 ether);
    }

    function _bridgeOnce(uint256 amount) internal {
        vm.prank(user);
        bridgeA.bridge(CHAIN_B, receiver, amount);
    }

    function testLockAndMintRoundTrip() public {
        _bridgeOnce(100 ether);
        check(tokenA.balanceOf(address(bridgeA)) == 100 ether, "not locked");
        check(tokenA.balanceOf(user) == 2_000_000 ether - 100 ether, "user not debited");
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(bridgeA)), 1);
        check(wrappedB.balanceOf(receiver) == 100 ether, "not minted");
    }

    function testReplaySameMessageReverts() public {
        _bridgeOnce(50 ether);
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(bridgeA)), 1);
        check(wrappedB.balanceOf(receiver) == 50 ether, "first mint wrong");
        vm.expectRevert();
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(bridgeA)), 1);
        check(wrappedB.balanceOf(receiver) == 50 ether, "replay minted twice");
    }

    function testOutOfOrderNonceReverts() public {
        _bridgeOnce(10 ether);
        _bridgeOnce(10 ether);
        // Deliver the second message first: its payload nonce is 2,
        // but bridgeB expects nonce 1 next.
        vm.expectRevert();
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(bridgeA)), 2);
    }

    function testUntrustedRemoteReverts() public {
        _bridgeOnce(10 ether);
        vm.expectRevert();
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(0xBAD)), 1);
    }

    function testOnlyEndpointCanDeliver() public {
        _bridgeOnce(10 ether);
        (, , bytes memory payload, ) = endpoint.lastMessage();
        vm.expectRevert();
        bridgeB.lzReceive(CHAIN_A, abi.encodePacked(address(bridgeA)), 1, payload);
    }

    function testDailyLimitBlocksOverLimit() public {
        vm.prank(user);
        vm.expectRevert();
        bridgeA.bridge(CHAIN_B, receiver, 1_000_001 ether);
    }

    function testSequentialMessagesMintInOrder() public {
        _bridgeOnce(10 ether);
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(bridgeA)), 1);
        _bridgeOnce(15 ether);
        endpoint.deliver(address(bridgeB), CHAIN_A, abi.encodePacked(address(bridgeA)), 2);
        check(wrappedB.balanceOf(receiver) == 25 ether, "sequential mint wrong");
    }
}
