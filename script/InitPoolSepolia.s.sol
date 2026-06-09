// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@v4-core/src/types/PoolId.sol";
import {Currency} from "@v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Initialises a dynamic-fee Uniswap V4 pool on Sepolia with the JITShield hook,
///         deploys two mock ERC20 tokens to act as the pool's currencies, and seeds an
///         initial passive liquidity position so the pool is immediately usable for swaps.
///
///         Required env:
///           POOL_MANAGER    — canonical V4 PoolManager on the target chain
///           JITSHIELD_HOOK  — address of the deployed JITShield hook (with 0x2AC8 low bits)
contract InitPoolSepolia is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    int24 constant TICK_SPACING = 60;
    int256 constant SEED_LIQUIDITY = 1e21;

    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address hookAddr = vm.envAddress("JITSHIELD_HOOK");

        vm.startBroadcast();

        // --- 1. Deploy two mock tokens. -----------------------------------------------------
        MockERC20 ta = new MockERC20("JIT Test Token A", "JTA", 18);
        MockERC20 tb = new MockERC20("JIT Test Token B", "JTB", 18);
        // Mint generous supply to the deployer.
        ta.mint(msg.sender, 1e24);
        tb.mint(msg.sender, 1e24);

        // --- 2. Sort tokens so currency0 < currency1. ---------------------------------------
        (Currency currency0, Currency currency1) = address(ta) < address(tb)
            ? (Currency.wrap(address(ta)), Currency.wrap(address(tb)))
            : (Currency.wrap(address(tb)), Currency.wrap(address(ta)));

        console2.log("Token A:", address(ta));
        console2.log("Token B:", address(tb));
        console2.log("currency0:", Currency.unwrap(currency0));
        console2.log("currency1:", Currency.unwrap(currency1));

        // --- 3. Deploy the liquidity router for ourselves (one router per script run). -----
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(poolManager);
        console2.log("LiquidityRouter:", address(router));

        // --- 4. Approve the router to spend our tokens. ------------------------------------
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);

        // --- 5. Initialise the pool with a dynamic-fee marker. -----------------------------
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        PoolId pid = key.toId();
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(pid));

        poolManager.initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialised");

        // --- 6. Seed initial passive liquidity. ---------------------------------------------
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: SEED_LIQUIDITY,
            salt: bytes32(0)
        });
        router.modifyLiquidity(key, params, "");
        console2.log("Seed liquidity added:", uint256(SEED_LIQUIDITY));

        vm.stopBroadcast();
    }
}
