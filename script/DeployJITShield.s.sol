// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "@v4-periphery/test/shared/HookMiner.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {JITShield} from "../src/JITShield.sol";

/// @notice Deploys JITShield via the canonical CREATE2 Deployer Proxy so the resulting address
///         carries the correct hook permission bits in its low 14 bits.
/// @dev    Required env:
///           POOL_MANAGER         — address of the v4 PoolManager on the target chain
///           JITSHIELD_OWNER      — address that controls config + protocol-fee withdrawal
///         Optional env (defaults shown):
///           JITSHIELD_SURGE_BIPS=7000        (0.7% surge)
///           JITSHIELD_PROTOCOL_BIPS=1000     (10% of the surge to protocol)
///           JITSHIELD_TIMELOCK_BLOCKS=5
contract DeployJITShield is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address ownerAddr = vm.envAddress("JITSHIELD_OWNER");
        uint24 surge = uint24(vm.envOr("JITSHIELD_SURGE_BIPS", uint256(7000)));
        uint16 protocolBips = uint16(vm.envOr("JITSHIELD_PROTOCOL_BIPS", uint256(1000)));
        uint16 timeLock = uint16(vm.envOr("JITSHIELD_TIMELOCK_BLOCKS", uint256(5)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory ctorArgs = abi.encode(IPoolManager(poolManagerAddr), ownerAddr, surge, protocolBips, timeLock);

        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(JITShield).creationCode, ctorArgs);

        console2.log("Mined hook address:", expected);
        console2.log("Salt:");
        console2.logBytes32(salt);
        console2.log("Low 14 bits:", uint160(expected) & Hooks.ALL_HOOK_MASK);
        console2.log("Target flags:", flags);
        require(uint160(expected) & Hooks.ALL_HOOK_MASK == flags, "mined flags mismatch");

        vm.startBroadcast();
        JITShield hook = new JITShield{salt: salt}(
            IPoolManager(poolManagerAddr), ownerAddr, surge, protocolBips, timeLock
        );
        vm.stopBroadcast();

        require(address(hook) == expected, "deployed address mismatch");
        console2.log("JITShield deployed at:", address(hook));
    }
}
