// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LiquidityLocker} from "../src/LiquidityLocker.sol";
import {LaunchTypes} from "../src/interfaces/ILaunchpad.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LaunchpadTest is LaunchpadTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    Stack s;
    LaunchTypes.Manifest m;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        s = deployStack();
        m = singleLegManifest(creator, 4663, address(0), 0);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ───────────────────────────── creation ─────────────────────────────

    function test_create_deploysTokenAndCurve() public {
        bytes32 id = s.pad.manifestHash(m);
        address predicted = s.pad.predictToken(id);
        address token = createNative(s, m, 0);
        assertEq(token, predicted, "create3 address");
        assertEq(LaunchToken(token).totalSupply(), SUPPLY);
        assertEq(LaunchToken(token).balanceOf(address(s.pad)), SUPPLY);
        assertEq(LaunchToken(token).launchId(), id);
        assertEq(LaunchToken(token).name(), "Crossr Test");
        assertEq(s.pad.tokenOf(id), token);
        assertTrue(s.pad.isLaunchToken(token));

        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(uint8(c.status), uint8(LaunchTypes.Status.Active));
        assertEq(c.phantomQuote, PHANTOM);
        assertEq(c.target, TARGET);
        assertEq(c.supply, SUPPLY);
        // reserved = 2/7 of supply (phantom : threshold = 2 : 5)
        assertEq(c.reserved, (SUPPLY * 2) / 7);
        assertEq(s.pad.sellableTokens(token), SUPPLY - (SUPPLY * 2) / 7);
        // launch fee credited to treasury
        assertEq(s.escrow.balanceOf(treasury, address(0)), s.pad.creationFee());
        assertEq(s.pad.spotPrice(token), (PHANTOM * 1e18) / SUPPLY);
    }

    function test_create_revertsForNonCreator() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Launchpad.NotCreator.selector);
        s.pad.createLaunch{value: 0.0005 ether}(m, 0, noRelays(), 0, 0);
    }

    function test_create_revertsWrongChain() public {
        m.legs[0].chainId = 56;
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(Launchpad.WrongChain.selector);
        s.pad.createLaunch{value: 0.0005 ether}(m, 0, noRelays(), 0, 0);
    }

    function test_create_revertsDuplicate() public {
        createNative(s, m, 0);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(Launchpad.LegExists.selector);
        s.pad.createLaunch{value: 0.0005 ether}(m, 0, noRelays(), 0, 0);
    }

    function test_create_revertsBadAllocation() public {
        m.legs[0].allocationBps = 9_000;
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(Launchpad.InvalidManifest.selector);
        s.pad.createLaunch{value: 0.0005 ether}(m, 0, noRelays(), 0, 0);
    }

    function test_create_revertsDuplicateChain() public {
        LaunchTypes.Manifest memory mm = twoLegManifest(creator, 4663, 4663, 5_000);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(Launchpad.InvalidManifest.selector);
        s.pad.createLaunch{value: 0.0005 ether}(mm, 0, noRelays(), 0, 0);
    }

    function test_create_revertsQuoteNotEnabled() public {
        m.legs[0].quote = address(0xBEEF);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(Launchpad.QuoteNotEnabled.selector);
        s.pad.createLaunch{value: 0.0005 ether}(m, 0, noRelays(), 0, 0);
    }

    function test_create_revertsBadValue() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(Launchpad.BadValue.selector);
        s.pad.createLaunch{value: 0.001 ether}(m, 0, noRelays(), 0, 0);
    }

    function test_create_partialAllocationScalesCurve() public {
        LaunchTypes.Manifest memory mm = twoLegManifest(creator, 4663, 56, 6_000);
        address token = createNative(s, mm, 0);
        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(c.supply, (SUPPLY * 6) / 10);
        assertEq(c.phantomQuote, (PHANTOM * 6) / 10);
        assertEq(c.target, (TARGET * 6) / 10);
        // opening price is identical regardless of allocation
        assertEq(s.pad.spotPrice(token), (PHANTOM * 1e18) / SUPPLY);
        assertEq(LaunchToken(token).totalSupply(), (SUPPLY * 6) / 10);
    }

    function test_create_withDevBuy() public {
        address token = createNative(s, m, 0.1 ether);
        // creator is snipe-exempt, so only the 1% fee applies
        uint256 net = 0.1 ether - 0.001 ether;
        uint256 expected = CurveMath.tokensOut(PHANTOM, SUPPLY, net);
        assertEq(LaunchToken(token).balanceOf(creator), expected);
        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(c.realQuote, net);
    }

    // ───────────────────────────── buying ─────────────────────────────

    function test_buy_mathAndFees() public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10); // past snipe window
        uint256 spend = 1 ether;
        uint256 fee = spend / 100;
        uint256 net = spend - fee;
        uint256 expected = CurveMath.tokensOut(PHANTOM, SUPPLY, net);

        (uint256 quotedOut, uint256 quotedSpent, uint256 feeBps) = s.pad.quoteBuy(token, spend, alice);
        assertEq(quotedOut, expected);
        assertEq(quotedSpent, spend);
        assertEq(feeBps, 100);

        vm.prank(alice);
        uint256 out = s.pad.buy{value: spend}(token, spend, expected, alice, block.timestamp);
        assertEq(out, expected);
        assertEq(LaunchToken(token).balanceOf(alice), expected);

        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(c.realQuote, net);
        assertEq(c.tokensSold, expected);
        // 30% protocol / 70% creator of the 1% fee
        assertEq(s.escrow.balanceOf(treasury, address(0)), s.pad.creationFee() + (fee * 3000) / 10_000);
        assertEq(s.escrow.balanceOf(creator, address(0)), fee - (fee * 3000) / 10_000);
        // launchpad holds exactly the curve's real quote
        assertEq(address(s.pad).balance, net);
    }

    function test_buy_revertsOnSlippage() public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        vm.expectRevert(Launchpad.Slippage.selector);
        s.pad.buy{value: 1 ether}(token, 1 ether, type(uint128).max, alice, block.timestamp);
    }

    function test_buy_revertsExpired() public {
        address token = createNative(s, m, 0);
        vm.prank(alice);
        vm.expectRevert(Launchpad.Expired.selector);
        s.pad.buy{value: 1 ether}(token, 1 ether, 0, alice, block.timestamp - 1);
    }

    function test_buy_revertsBadValue() public {
        address token = createNative(s, m, 0);
        vm.prank(alice);
        vm.expectRevert(Launchpad.BadValue.selector);
        s.pad.buy{value: 0.5 ether}(token, 1 ether, 0, alice, block.timestamp);
    }

    function test_buy_whenPaused() public {
        address token = createNative(s, m, 0);
        s.pad.pause();
        vm.prank(alice);
        vm.expectRevert();
        s.pad.buy{value: 1 ether}(token, 1 ether, 0, alice, block.timestamp);
        s.pad.unpause();
        vm.prank(alice);
        s.pad.buy{value: 1 ether}(token, 1 ether, 0, alice, block.timestamp);
    }

    function test_snipeTax_decaysAndExempts() public {
        address token = createNative(s, m, 0);
        uint256 t0 = 1_800_000_000; // literal: via-IR rematerializes block.timestamp across warps
        // t = 0: 99% start, capped at 1e4 - 100 - 0 - 100 = 9800
        assertEq(s.pad.currentSnipeTaxBps(token, alice), 9_800);
        assertEq(s.pad.currentSnipeTaxBps(token, creator), 0, "creator exempt");
        // 1s of a 3s window: 4 halvings → 9900 >> 4 = 618
        vm.warp(t0 + 1);
        assertEq(s.pad.currentSnipeTaxBps(token, alice), 9_900 >> 4);
        vm.warp(t0 + 2);
        assertEq(s.pad.currentSnipeTaxBps(token, alice), 9_900 >> 9);
        vm.warp(t0 + 3);
        assertEq(s.pad.currentSnipeTaxBps(token, alice), 0);
    }

    function test_snipeTax_chargedAndSplit() public {
        address token = createNative(s, m, 0);
        uint256 spend = 1 ether;
        uint256 snipeBps = 9_800;
        uint256 baseFee = (spend * (100 + snipeBps)) / 10_000;
        uint256 net = spend - baseFee;
        uint256 expected = CurveMath.tokensOut(PHANTOM, SUPPLY, net);
        vm.prank(bob);
        uint256 out = s.pad.buy{value: spend}(token, spend, 0, bob, block.timestamp);
        assertEq(out, expected);
        assertEq(s.escrow.balanceOf(creator, address(0)), baseFee - (baseFee * 3000) / 10_000);
    }

    function test_snipeExemptList() public {
        m.snipeExempt = new address[](1);
        m.snipeExempt[0] = bob;
        address token = createNative(s, m, 0);
        assertEq(s.pad.currentSnipeTaxBps(token, bob), 0);
        assertEq(s.pad.currentSnipeTaxBps(token, alice), 9_800);
    }

    function test_creatorTax() public {
        m.creatorTaxBps = 500; // 5%
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        uint256 spend = 1 ether;
        vm.prank(alice);
        s.pad.buy{value: spend}(token, spend, 0, alice, block.timestamp);
        uint256 baseFee = spend / 100;
        uint256 tax = spend / 20;
        assertEq(s.escrow.balanceOf(creator, address(0)), baseFee - (baseFee * 3000) / 10_000 + tax);
        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(c.realQuote, spend - baseFee - tax);
    }

    // ───────────────────────────── selling ─────────────────────────────

    function test_sell_roundTrip() public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 out = s.pad.buy{value: 1 ether}(token, 1 ether, 0, alice, block.timestamp);

        (uint256 quoted, uint256 fees) = s.pad.quoteSell(token, out);
        assertGt(quoted, 0);
        uint256 before = alice.balance;
        vm.startPrank(alice);
        LaunchToken(token).approve(address(s.pad), out);
        uint256 got = s.pad.sell(token, out, quoted, alice, block.timestamp);
        vm.stopPrank();
        assertEq(got, quoted);
        assertEq(alice.balance - before, got);
        // selling everything back returns the net paid, minus ~1% fee, minus rounding
        assertApproxEqRel(got + fees, 0.99 ether, 1e12);
        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(c.tokensSold, 0);
        assertLe(c.realQuote, 2); // rounding dust only
        assertEq(LaunchToken(token).balanceOf(alice), 0);
    }

    function test_sell_revertsMoreThanSold() public {
        // Simulate tokens arriving from another leg (bridge) by minting via a fake bridge.
        address token = createNative(s, m, 0);
        s.pad.setModules(bob, address(0), address(s.locker), address(s.escrow), treasury);
        vm.prank(bob);
        LaunchToken(token).bridgeMint(alice, 1e24);
        vm.startPrank(alice);
        LaunchToken(token).approve(address(s.pad), 1e24);
        vm.expectRevert(Launchpad.InsufficientSold.selector);
        s.pad.sell(token, 1e24, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_sell_revertsSlippage() public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        vm.startPrank(alice);
        uint256 out = s.pad.buy{value: 1 ether}(token, 1 ether, 0, alice, block.timestamp);
        LaunchToken(token).approve(address(s.pad), out);
        vm.expectRevert(Launchpad.Slippage.selector);
        s.pad.sell(token, out, 10 ether, alice, block.timestamp);
        vm.stopPrank();
    }

    // ───────────────────────────── graduation ─────────────────────────────

    function _graduatedToken() internal returns (address token, uint256 spent) {
        token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        uint256 before = alice.balance;
        vm.prank(alice);
        s.pad.buy{value: 10 ether}(token, 10 ether, 0, alice, block.timestamp);
        spent = before - alice.balance;
    }

    function test_graduation_partialFillRefundsAndAutoGraduates() public {
        (address token, uint256 spent) = _graduatedToken();
        // gross needed = 4.2 / 0.99 (+ rounding)
        assertApproxEqRel(spent, (TARGET * 10_000) / 9_900, 1e9);
        assertLt(spent, 10 ether);

        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(uint8(c.status), uint8(LaunchTypes.Status.Graduated));
        assertEq(c.realQuote, 0);
        assertEq(s.pad.sellableTokens(token), 0);
        // alice got 5/7 of supply
        assertEq(LaunchToken(token).balanceOf(alice), SUPPLY - (SUPPLY * 2) / 7);
        // 10/49 of supply to the pool, 4/49 burned
        uint256 expectedPool = (SUPPLY * 10) / 49;
        assertApproxEqRel(SUPPLY - LaunchToken(token).totalSupply(), (SUPPLY * 4) / 49, 1e6, "burned");
        assertEq(LaunchToken(token).balanceOf(address(s.pad)), 0, "pad holds no tokens");
        assertEq(address(s.pad).balance, 0, "pad holds no quote");

        LiquidityLocker.Position memory p = s.locker.position(token);
        assertTrue(p.exists);
        assertGt(p.liquidity, 0);
        PoolId id = p.key.toId();
        (uint160 sqrtPrice,,,) = IPoolManager(address(s.poolManager)).getSlot0(id);
        assertGt(sqrtPrice, 0);
        assertEq(IPoolManager(address(s.poolManager)).getLiquidity(id), p.liquidity);
        // pool balances ≈ all raised quote and expectedPool tokens (minus rounding dust)
        assertApproxEqRel(address(s.poolManager).balance, TARGET, 1e9);
        assertApproxEqRel(LaunchToken(token).balanceOf(address(s.poolManager)), expectedPool, 1e9);
        // pool price ≈ terminal curve price: (phantom + target) / reserved
        uint256 termPrice = ((PHANTOM + TARGET) * 1e18) / ((SUPPLY * 2) / 7);
        uint256 poolPrice = (TARGET * 1e18) / expectedPool;
        assertApproxEqRel(poolPrice, termPrice, 1e9);
    }

    function test_graduation_blocksCurveTrading() public {
        (address token,) = _graduatedToken();
        vm.prank(bob);
        vm.expectRevert(Launchpad.NotActive.selector);
        s.pad.buy{value: 1 ether}(token, 1 ether, 0, bob, block.timestamp);
        vm.startPrank(alice);
        LaunchToken(token).approve(address(s.pad), 1);
        vm.expectRevert(Launchpad.NotActive.selector);
        s.pad.sell(token, 1, 0, alice, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(Launchpad.NotPendingGraduation.selector);
        s.pad.graduate(token);
    }

    function test_graduation_manualAfterAutoFailure() public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        // break the locker so auto-graduation fails, the buy must still succeed
        s.pad.setModules(address(0), address(0), address(0xdead), address(s.escrow), treasury);
        vm.prank(alice);
        s.pad.buy{value: 10 ether}(token, 10 ether, 0, alice, block.timestamp);
        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(uint8(c.status), uint8(LaunchTypes.Status.PendingGraduation));
        assertApproxEqAbs(c.realQuote, TARGET, 10, "raised the target (rounding dust only)");
        // no trading while pending
        vm.prank(bob);
        vm.expectRevert(Launchpad.NotActive.selector);
        s.pad.buy{value: 1 ether}(token, 1 ether, 0, bob, block.timestamp);
        // fix and graduate permissionlessly
        s.pad.setModules(address(0), address(0), address(s.locker), address(s.escrow), treasury);
        vm.prank(bob);
        s.pad.graduate(token);
        assertEq(uint8(s.pad.getCurve(token).status), uint8(LaunchTypes.Status.Graduated));
    }

    function test_graduation_withGraduationFee() public {
        s.pad.setFees(100, 3000, 500, 0.0005 ether); // 5% graduation fee
        (address token,) = _graduatedToken();
        uint256 gradFee = (TARGET * 500) / 10_000;
        assertEq(s.escrow.balanceOf(treasury, address(0)) - s.pad.creationFee(), gradFee + _treasuryTradeFees());
        assertApproxEqRel(address(s.poolManager).balance, TARGET - gradFee, 1e9);
        // fewer tokens go to the pool so the price is still continuous
        uint256 poolTokens = LaunchToken(token).balanceOf(address(s.poolManager));
        uint256 termPrice = ((PHANTOM + TARGET) * 1e18) / ((SUPPLY * 2) / 7);
        assertApproxEqRel(((TARGET - gradFee) * 1e18) / poolTokens, termPrice, 1e9);
    }

    function _treasuryTradeFees() internal view returns (uint256) {
        // the single graduating buy paid gross = 4.2/0.99, fee = 1% of that, 30% to treasury
        uint256 gross = (TARGET * 10_000 + 9_899) / 9_900;
        return ((gross / 100) * 3000) / 10_000;
    }

    function test_hook_blocksForeignInitialize() public {
        (address token,) = _graduatedToken();
        LiquidityLocker.Position memory p = s.locker.position(token);
        PoolKey memory k = p.key;
        k.fee = 3000; // new key, same hook
        vm.expectRevert();
        s.poolManager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    // ───────────────────────────── post-graduation swaps + hook fees ─────────────────────────────

    function test_postGraduation_swapChargesHookFee() public {
        m.creatorTaxBps = 200; // 2% creator tax post-graduation as well
        (address token,) = _graduatedToken();
        LiquidityLocker.Position memory p = s.locker.position(token);
        PoolKey memory key = p.key;
        bool ethIs0 = Currency.unwrap(key.currency0) == address(0);

        uint256 treasuryTokBefore = s.escrow.balanceOf(treasury, token);
        uint256 creatorTokBefore = s.escrow.balanceOf(creator, token);

        // exact-in 0.1 ETH → token; fee is on the unspecified (token) side
        vm.prank(bob);
        s.swapRouter.swap{value: 0.1 ether}(
            key,
            SwapParams({
                zeroForOne: ethIs0,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: ethIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 bobTokens = LaunchToken(token).balanceOf(bob);
        assertGt(bobTokens, 0);
        uint256 treasuryGot = s.escrow.balanceOf(treasury, token) - treasuryTokBefore;
        uint256 creatorGot = s.escrow.balanceOf(creator, token) - creatorTokBefore;
        assertGt(treasuryGot, 0);
        assertGt(creatorGot, 0);
        // gross output G: bob got G*(1-3%), treasury 0.3%, creator 0.7% + 2%
        uint256 gross = bobTokens + treasuryGot + creatorGot;
        assertApproxEqAbs(treasuryGot, (gross * 30) / 10_000, 2);
        assertApproxEqAbs(creatorGot, (gross * 270) / 10_000, 2);

        // claim token fees from escrow
        vm.prank(creator);
        s.escrow.claim(token);
        assertEq(LaunchToken(token).balanceOf(creator), creatorGot);

        // exact-in token → ETH: fee on ETH side, credited as native
        uint256 creatorEthBefore = s.escrow.balanceOf(creator, address(0));
        vm.startPrank(bob);
        LaunchToken(token).approve(address(s.swapRouter), bobTokens);
        s.swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !ethIs0,
                amountSpecified: -int256(bobTokens),
                sqrtPriceLimitX96: !ethIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertGt(s.escrow.balanceOf(creator, address(0)), creatorEthBefore);
    }

    function test_locker_collectsLpFeesWhenPoolFeeSet() public {
        s.locker.setConfig(3000, 60, 5000, treasury); // 0.3% pool fee
        (address token,) = _graduatedToken();
        LiquidityLocker.Position memory p = s.locker.position(token);
        bool ethIs0 = Currency.unwrap(p.key.currency0) == address(0);
        vm.prank(bob);
        s.swapRouter.swap{value: 1 ether}(
            p.key,
            SwapParams({
                zeroForOne: ethIs0,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: ethIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint256 a0, uint256 a1) = s.locker.collect(token);
        uint256 ethFees = ethIs0 ? a0 : a1;
        assertApproxEqRel(ethFees, 0.003 ether, 1e15);
        assertEq(s.locker.claimable(creator, address(0)), ethFees / 2);
        uint256 before = creator.balance;
        vm.prank(creator);
        s.locker.claim(address(0));
        assertEq(creator.balance - before, ethFees / 2);
    }

    // ───────────────────────────── ERC20 quote ─────────────────────────────

    function test_erc20Quote_fullLifecycle() public {
        MockERC20 usd = new MockERC20("USD", "USD", 6);
        s.pad.setQuoteConfig(address(usd), true, 3_236e6, 8_090e6);
        m.legs[0].quote = address(usd);
        vm.deal(creator, 1 ether);
        usd.mint(creator, 1_000e6);
        vm.startPrank(creator);
        usd.approve(address(s.pad), 1_000e6);
        address token = s.pad.createLaunch{value: 0.0005 ether}(m, 0, noRelays(), 1_000e6, 0);
        vm.stopPrank();
        assertGt(LaunchToken(token).balanceOf(creator), 0);
        assertEq(s.escrow.balanceOf(creator, address(usd)), 7e6); // 70% of 1% of 1000

        vm.warp(block.timestamp + 10);
        usd.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usd.approve(address(s.pad), 20_000e6);
        uint256 out = s.pad.buy(token, 5_000e6, 0, alice, block.timestamp);
        LaunchToken(token).approve(address(s.pad), out / 2);
        s.pad.sell(token, out / 2, 0, alice, block.timestamp);
        // crossing buy graduates into a USD/token pool
        s.pad.buy(token, 20_000e6 - 5_000e6, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(uint8(s.pad.getCurve(token).status), uint8(LaunchTypes.Status.Graduated));
        assertApproxEqRel(usd.balanceOf(address(s.poolManager)), 8_090e6, 1e9);
        assertEq(usd.balanceOf(address(s.pad)), 0);
        assertLt(usd.balanceOf(alice), 20_000e6);
    }

    // ───────────────────────────── escrow ─────────────────────────────

    function test_escrow_claim() public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        s.pad.buy{value: 1 ether}(token, 1 ether, 0, alice, block.timestamp);
        uint256 bal = s.escrow.balanceOf(creator, address(0));
        uint256 before = creator.balance;
        vm.prank(creator);
        s.escrow.claim(address(0));
        assertEq(creator.balance - before, bal);
        assertEq(s.escrow.balanceOf(creator, address(0)), 0);
        vm.prank(alice);
        vm.expectRevert();
        s.escrow.creditToken(alice, token, 1);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    function testFuzz_buysNeverOvershootTarget(uint256[8] memory amounts) public {
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        s.pad.setModules(address(0), address(0), address(0xdead), address(s.escrow), treasury); // keep pending
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 a = bound(amounts[i], 1e9, 3 ether);
            LaunchTypes.Curve memory c = s.pad.getCurve(token);
            if (c.status != LaunchTypes.Status.Active) break;
            vm.deal(alice, a);
            vm.prank(alice);
            s.pad.buy{value: a}(token, a, 0, alice, block.timestamp);
            c = s.pad.getCurve(token);
            assertLe(c.realQuote, TARGET + 1e6);
            assertLe(c.tokensSold, SUPPLY - c.reserved);
            assertEq(address(s.pad).balance, c.realQuote);
        }
    }

    function testFuzz_sellNeverExceedsHoldings(uint256 buyAmt, uint256 sellFrac) public {
        buyAmt = bound(buyAmt, 1e12, 4 ether);
        sellFrac = bound(sellFrac, 1, 10_000);
        address token = createNative(s, m, 0);
        vm.warp(block.timestamp + 10);
        vm.deal(alice, buyAmt);
        vm.startPrank(alice);
        uint256 out = s.pad.buy{value: buyAmt}(token, buyAmt, 0, alice, block.timestamp);
        uint256 sellAmt = (out * sellFrac) / 10_000;
        if (sellAmt == 0) return;
        LaunchToken(token).approve(address(s.pad), sellAmt);
        uint256 got = s.pad.sell(token, sellAmt, 0, alice, block.timestamp);
        vm.stopPrank();
        assertLe(got, buyAmt);
        LaunchTypes.Curve memory c = s.pad.getCurve(token);
        assertEq(address(s.pad).balance, c.realQuote);
    }
}
