// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CurveMath} from "./libraries/CurveMath.sol";
import {LaunchTypes, ILaunchpad} from "./interfaces/ILaunchpad.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {ILaunchRelay} from "./interfaces/ILaunchRelay.sol";
import {ILiquidityLocker} from "./interfaces/ILiquidityLocker.sol";
import {IFeeEscrow} from "./interfaces/IFeeEscrow.sol";
import {Create3Factory} from "./Create3Factory.sol";

/// @title Launchpad
/// @notice Multichain bonding-curve launchpad. A launch is a Manifest (identical on every chain) with one
///         "leg" per chain; each leg is an independent Pons-style constant-product curve in that chain's
///         quote asset. The token has the same address on every chain and is bridgeable between them,
///         so cross-chain arbitrage keeps the legs priced together. Each leg graduates on its own into
///         a Uniswap v4 pool owned by the LiquidityLocker.
contract Launchpad is ILaunchpad, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeTransferLib for address;
    using LaunchTypes for LaunchTypes.Manifest;

    // ───────────────────────────── errors ─────────────────────────────
    error NotCreator();
    error NotRelay();
    error NotSelf();
    error InvalidManifest();
    error WrongChain();
    error LegExists();
    error QuoteNotEnabled();
    error RemoteQuoteNotAllowed();
    error RemoteChainUnsupported();
    error NotActive();
    error NotPendingGraduation();
    error Expired();
    error ZeroAmount();
    error Slippage();
    error BadValue();
    error InsufficientSold();
    error InvalidBps();
    error UnknownToken();

    // ───────────────────────────── events ─────────────────────────────
    event LaunchManifest(bytes32 indexed launchId, bytes manifest);
    event LegCreated(
        address indexed token,
        bytes32 indexed launchId,
        uint8 legIndex,
        address indexed creator,
        address quote,
        uint128 supply,
        uint128 reserved,
        uint128 phantomQuote,
        uint128 target,
        uint16 creatorTaxBps,
        string name,
        string symbol,
        string metadataURI
    );
    event LegRelayed(bytes32 indexed launchId, uint8 legIndex, uint64 chainId, uint256 fee);
    event Trade(
        address indexed token,
        address indexed trader,
        address indexed recipient,
        bool isBuy,
        uint256 quoteAmount, // gross quote paid (buy) or gross quote value before fees (sell)
        uint256 tokenAmount,
        uint256 fee, // base curve fee (incl. snipe tax)
        uint256 creatorTax,
        uint128 realQuote,
        uint128 tokensSold
    );
    event ReadyToGraduate(address indexed token);
    event Graduated(address indexed token, uint256 tokensToPool, uint256 quoteToPool, uint256 tokensBurned);
    event AutoGraduationFailed(address indexed token, bytes reason);
    event QuoteConfigSet(address indexed quote, bool enabled, uint128 phantomQuote, uint128 target);
    event RemoteQuoteSet(uint64 indexed chainId, address indexed quote, bool allowed);
    event FeesSet(uint16 tradeFeeBps, uint16 protocolShareBps, uint16 graduationFeeBps, uint256 creationFee);
    event SnipeTaxSet(uint16 startBps, uint32 seconds_);
    event ModulesSet(address bridge, address relay, address locker, address escrow, address treasury);

    // ───────────────────────────── config ─────────────────────────────
    struct QuoteConfig {
        bool enabled;
        uint128 phantomQuote; // for a full (10_000 bps) leg
        uint128 target; // graduation threshold for a full leg
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant MAX_LEGS = 8;
    uint256 public constant MAX_SNIPE_EXEMPT = 16;
    uint16 public constant MAX_CREATOR_TAX_BPS = 1_000;

    Create3Factory public immutable factory;
    IFeeEscrow public escrow;
    ILiquidityLocker public locker;
    ILaunchRelay public relay;
    address public bridge;
    address public treasury;

    uint16 public tradeFeeBps = 100; // 1% of the quote leg, both directions
    uint16 public protocolShareBps = 3_000; // 30% of base fee to protocol, 70% to creator
    uint16 public graduationFeeBps = 0; // taken from raised quote at graduation
    uint256 public creationFee = 0.0005 ether; // per leg, paid on the chain where the launch is submitted
    uint16 public snipeTaxStartBps = 9_900; // decays with 14 halvings over snipeTaxSeconds
    uint32 public snipeTaxSeconds = 3;

    mapping(address quote => QuoteConfig) public quoteConfigs;
    mapping(uint64 chainId => mapping(address quote => bool)) public remoteQuoteAllowed;

    // ───────────────────────────── state ─────────────────────────────
    mapping(address token => LaunchTypes.Curve) internal _curves;
    mapping(bytes32 launchId => address token) public tokenOf;
    mapping(address token => bool) public isLaunchToken;
    mapping(address token => mapping(address => bool)) public snipeExempt;

    struct RelaySpec {
        uint8 legIndex;
        bytes options; // LayerZero executor options for the remote createLeg
    }

    constructor(Create3Factory factory_, address owner_, address treasury_) Ownable(owner_) {
        factory = factory_;
        treasury = treasury_;
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setModules(address bridge_, address relay_, address locker_, address escrow_, address treasury_)
        external
        onlyOwner
    {
        bridge = bridge_;
        relay = ILaunchRelay(relay_);
        locker = ILiquidityLocker(locker_);
        escrow = IFeeEscrow(escrow_);
        treasury = treasury_;
        emit ModulesSet(bridge_, relay_, locker_, escrow_, treasury_);
    }

    function setQuoteConfig(address quote, bool enabled, uint128 phantomQuote, uint128 target) external onlyOwner {
        if (enabled && (phantomQuote == 0 || target == 0)) revert InvalidManifest();
        quoteConfigs[quote] = QuoteConfig(enabled, phantomQuote, target);
        emit QuoteConfigSet(quote, enabled, phantomQuote, target);
    }

    function setRemoteQuote(uint64 chainId, address quote, bool allowed) external onlyOwner {
        remoteQuoteAllowed[chainId][quote] = allowed;
        emit RemoteQuoteSet(chainId, quote, allowed);
    }

    function setFees(uint16 tradeFeeBps_, uint16 protocolShareBps_, uint16 graduationFeeBps_, uint256 creationFee_)
        external
        onlyOwner
    {
        if (tradeFeeBps_ > 1_000 || protocolShareBps_ > 5_000 || graduationFeeBps_ > 1_000) revert InvalidBps();
        tradeFeeBps = tradeFeeBps_;
        protocolShareBps = protocolShareBps_;
        graduationFeeBps = graduationFeeBps_;
        creationFee = creationFee_;
        emit FeesSet(tradeFeeBps_, protocolShareBps_, graduationFeeBps_, creationFee_);
    }

    function setSnipeTax(uint16 startBps, uint32 seconds_) external onlyOwner {
        if (startBps > 9_900 || seconds_ > 60) revert InvalidBps();
        snipeTaxStartBps = startBps;
        snipeTaxSeconds = seconds_;
        emit SnipeTaxSet(startBps, seconds_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ───────────────────────────── launching ─────────────────────────────

    /// @notice Create the leg of `manifest` that lives on this chain, optionally relaying the other legs
    ///         to their chains, and optionally performing a first buy in the same transaction.
    /// @param devBuyQuote  quote amount for the creator's first buy (0 for none). Native quote: included
    ///                     in msg.value; ERC20 quote: pulled with transferFrom.
    /// @dev msg.value must equal creationFee * (1 + relays.length) + sum(relay fees) [+ devBuyQuote if native].
    function createLaunch(
        LaunchTypes.Manifest calldata manifest,
        uint8 legIndex,
        RelaySpec[] calldata relays,
        uint256 devBuyQuote,
        uint256 devBuyMinOut
    ) external payable nonReentrant whenNotPaused returns (address token) {
        if (msg.sender != manifest.creator) revert NotCreator();
        _validate(manifest);
        bytes32 launchId = manifest.hash();
        token = _createLeg(manifest, launchId, legIndex);

        uint256 cost = creationFee;
        for (uint256 i = 0; i < relays.length; i++) {
            uint8 idx = relays[i].legIndex;
            if (idx >= manifest.legs.length || idx == legIndex) revert InvalidManifest();
            LaunchTypes.Leg calldata leg = manifest.legs[idx];
            if (leg.chainId == block.chainid) revert InvalidManifest();
            if (address(relay) == address(0) || !relay.isSupported(leg.chainId)) revert RemoteChainUnsupported();
            if (!remoteQuoteAllowed[leg.chainId][leg.quote]) revert RemoteQuoteNotAllowed();
            uint256 fee = relay.quoteLeg(manifest, idx, relays[i].options);
            relay.sendLeg{value: fee}(manifest, idx, relays[i].options, manifest.creator);
            cost += fee + creationFee;
            emit LegRelayed(launchId, idx, leg.chainId, fee);
        }
        uint256 launchFees = creationFee * (1 + relays.length);
        if (launchFees > 0) escrow.creditNative{value: launchFees}(treasury);

        address quote = manifest.legs[legIndex].quote;
        if (quote == address(0)) {
            if (msg.value != cost + devBuyQuote) revert BadValue();
        } else {
            if (msg.value != cost) revert BadValue();
            if (devBuyQuote > 0) quote.safeTransferFrom(msg.sender, address(this), devBuyQuote);
        }
        if (devBuyQuote > 0) _buy(token, devBuyQuote, devBuyMinOut, msg.sender);
    }

    /// @inheritdoc ILaunchpad
    function createLegFromRelay(LaunchTypes.Manifest calldata manifest, uint8 legIndex)
        external
        nonReentrant
        whenNotPaused
    {
        if (msg.sender != address(relay)) revert NotRelay();
        _validate(manifest);
        _createLeg(manifest, manifest.hash(), legIndex);
    }

    function _createLeg(LaunchTypes.Manifest calldata m, bytes32 launchId, uint8 legIndex)
        internal
        returns (address token)
    {
        if (legIndex >= m.legs.length) revert InvalidManifest();
        LaunchTypes.Leg calldata leg = m.legs[legIndex];
        if (leg.chainId != block.chainid) revert WrongChain();
        if (tokenOf[launchId] != address(0)) revert LegExists();
        QuoteConfig memory cfg = quoteConfigs[leg.quote];
        if (!cfg.enabled) revert QuoteNotEnabled();

        uint256 supply = (TOTAL_SUPPLY * leg.allocationBps) / 10_000;
        uint256 phantom = (uint256(cfg.phantomQuote) * leg.allocationBps) / 10_000;
        uint256 target = (uint256(cfg.target) * leg.allocationBps) / 10_000;
        uint256 reserved = CurveMath.reservedTokens(supply, phantom, target);

        token = factory.deployLaunchToken(launchId, m.name, m.symbol, m.metadataURI, supply);

        LaunchTypes.Curve storage c = _curves[token];
        c.quote = leg.quote;
        c.creator = m.creator;
        c.launchId = launchId;
        c.legIndex = legIndex;
        c.status = LaunchTypes.Status.Active;
        c.creatorTaxBps = m.creatorTaxBps;
        c.snipeTaxStartBps = snipeTaxStartBps;
        c.snipeTaxSeconds = snipeTaxSeconds;
        c.createdAt = uint64(block.timestamp);
        c.phantomQuote = uint128(phantom);
        c.supply = uint128(supply);
        c.reserved = uint128(reserved);
        c.target = uint128(target);

        tokenOf[launchId] = token;
        isLaunchToken[token] = true;
        snipeExempt[token][m.creator] = true;
        for (uint256 i = 0; i < m.snipeExempt.length; i++) {
            snipeExempt[token][m.snipeExempt[i]] = true;
        }

        emit LaunchManifest(launchId, abi.encode(m));
        emit LegCreated(
            token,
            launchId,
            legIndex,
            m.creator,
            leg.quote,
            uint128(supply),
            uint128(reserved),
            uint128(phantom),
            uint128(target),
            m.creatorTaxBps,
            m.name,
            m.symbol,
            m.metadataURI
        );
    }

    function _validate(LaunchTypes.Manifest calldata m) internal pure {
        uint256 n = m.legs.length;
        if (n == 0 || n > MAX_LEGS) revert InvalidManifest();
        if (m.creator == address(0)) revert InvalidManifest();
        if (m.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert InvalidManifest();
        if (bytes(m.name).length == 0 || bytes(m.name).length > 64) revert InvalidManifest();
        if (bytes(m.symbol).length == 0 || bytes(m.symbol).length > 16) revert InvalidManifest();
        if (bytes(m.metadataURI).length > 512) revert InvalidManifest();
        if (m.snipeExempt.length > MAX_SNIPE_EXEMPT) revert InvalidManifest();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            LaunchTypes.Leg calldata leg = m.legs[i];
            if (leg.allocationBps == 0) revert InvalidManifest();
            sum += leg.allocationBps;
            for (uint256 j = 0; j < i; j++) {
                if (m.legs[j].chainId == leg.chainId) revert InvalidManifest();
            }
        }
        if (sum != 10_000) revert InvalidManifest();
    }

    // ───────────────────────────── trading ─────────────────────────────

    /// @notice Buy tokens with `quoteAmount` of the leg's quote asset. Native quote is msg.value.
    /// @dev Partial fills never revert: if the buy would cross graduation, only the remaining sellable
    ///      tokens are sold and the unused quote is refunded. `minTokensOut` is a price bound:
    ///      spent * minTokensOut <= quoteAmount * tokensOut.
    function buy(address token, uint256 quoteAmount, uint256 minTokensOut, address recipient, uint256 deadline)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        LaunchTypes.Curve storage c = _curves[token];
        if (c.status != LaunchTypes.Status.Active) revert NotActive();
        if (c.quote == address(0)) {
            if (msg.value != quoteAmount) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            c.quote.safeTransferFrom(msg.sender, address(this), quoteAmount);
        }
        tokensOut = _buy(token, quoteAmount, minTokensOut, recipient == address(0) ? msg.sender : recipient);
    }

    function _buy(address token, uint256 received, uint256 minTokensOut, address recipient)
        internal
        returns (uint256 tokensOut)
    {
        if (received == 0) revert ZeroAmount();
        LaunchTypes.Curve storage c = _curves[token];

        uint256 snipeBps = _snipeTaxBps(token, c, recipient);
        uint256 totalBps = uint256(tradeFeeBps) + c.creatorTaxBps + snipeBps;

        uint256 x = uint256(c.phantomQuote) + c.realQuote;
        uint256 y = uint256(c.supply) - c.tokensSold;
        uint256 sellable = y - c.reserved;

        uint256 spent = received;
        uint256 net = spent - (spent * totalBps) / 10_000;
        tokensOut = CurveMath.tokensOut(x, y, net);

        if (tokensOut >= sellable) {
            tokensOut = sellable;
            net = CurveMath.quoteIn(x, y, sellable);
            spent = CurveMath.grossForNet(net, totalBps);
            if (spent > received) spent = received;
            net = spent - (spent * totalBps) / 10_000;
        }
        if (tokensOut == 0) revert ZeroAmount();
        if (spent * minTokensOut > received * tokensOut) revert Slippage();

        uint256 baseFee = (spent * (tradeFeeBps + snipeBps)) / 10_000;
        uint256 creatorTax = (spent * c.creatorTaxBps) / 10_000;
        // net + baseFee + creatorTax may be < spent by rounding; the dust stays with the curve.
        c.realQuote += uint128(spent - baseFee - creatorTax);
        c.tokensSold += uint128(tokensOut);

        _distributeFees(c, baseFee, creatorTax);
        token.safeTransfer(recipient, tokensOut);

        emit Trade(token, msg.sender, recipient, true, spent, tokensOut, baseFee, creatorTax, c.realQuote, c.tokensSold);

        uint256 refund = received - spent;
        if (refund > 0) _payQuote(c.quote, msg.sender, refund);

        if (tokensOut == sellable) {
            c.status = LaunchTypes.Status.PendingGraduation;
            emit ReadyToGraduate(token);
            try this.selfGraduate(token) {}
            catch (bytes memory reason) {
                emit AutoGraduationFailed(token, reason);
            }
        }
    }

    /// @notice Sell `tokenAmount` tokens back to the curve for the leg's quote asset.
    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (tokenAmount == 0) revert ZeroAmount();
        LaunchTypes.Curve storage c = _curves[token];
        if (c.status != LaunchTypes.Status.Active) revert NotActive();
        // A leg can only pay out quote it took in; tokens bridged from another leg cannot drain it below zero.
        if (tokenAmount > c.tokensSold) revert InsufficientSold();
        if (recipient == address(0)) recipient = msg.sender;

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 x = uint256(c.phantomQuote) + c.realQuote;
        uint256 y = uint256(c.supply) - c.tokensSold;
        uint256 gross = CurveMath.quoteOut(x, y, tokenAmount);
        uint256 baseFee = (gross * tradeFeeBps) / 10_000;
        uint256 creatorTax = (gross * c.creatorTaxBps) / 10_000;
        quoteOut = gross - baseFee - creatorTax;
        if (quoteOut < minQuoteOut) revert Slippage();

        c.realQuote -= uint128(gross);
        c.tokensSold -= uint128(tokenAmount);

        _distributeFees(c, baseFee, creatorTax);
        _payQuote(c.quote, recipient, quoteOut);

        emit Trade(token, msg.sender, recipient, false, gross, tokenAmount, baseFee, creatorTax, c.realQuote, c.tokensSold);
    }

    // ───────────────────────────── graduation ─────────────────────────────

    /// @notice Permissionless: moves a sold-out curve into its Uniswap v4 pool.
    function graduate(address token) external nonReentrant {
        _graduate(token);
    }

    /// @dev Self-call used by the crossing buy so a failing graduation never reverts the trade.
    function selfGraduate(address token) external {
        if (msg.sender != address(this)) revert NotSelf();
        _graduate(token);
    }

    function _graduate(address token) internal {
        LaunchTypes.Curve storage c = _curves[token];
        if (c.status != LaunchTypes.Status.PendingGraduation) revert NotPendingGraduation();

        uint256 raised = c.realQuote;
        uint256 gradFee = (raised * graduationFeeBps) / 10_000;
        uint256 quoteToPool = raised - gradFee;

        // Pool opens at the curve's terminal price: tokens = quote / price, price = x / y.
        uint256 x = uint256(c.phantomQuote) + raised;
        uint256 y = uint256(c.supply) - c.tokensSold; // == reserved
        uint256 tokensToPool = (quoteToPool * y) / x;
        if (tokensToPool > y) tokensToPool = y;
        uint256 burn = y - tokensToPool;

        c.status = LaunchTypes.Status.Graduated;
        c.realQuote = 0;

        if (burn > 0) ILaunchToken(token).burnFromLaunchpad(burn);
        if (gradFee > 0) _creditFee(c.quote, treasury, gradFee);

        token.safeTransfer(address(locker), tokensToPool);
        if (c.quote == address(0)) {
            locker.lock{value: quoteToPool}(token, c.quote, tokensToPool, quoteToPool, c.creator, c.creatorTaxBps);
        } else {
            c.quote.safeTransfer(address(locker), quoteToPool);
            locker.lock(token, c.quote, tokensToPool, quoteToPool, c.creator, c.creatorTaxBps);
        }
        emit Graduated(token, tokensToPool, quoteToPool, burn);
    }

    // ───────────────────────────── fee plumbing ─────────────────────────────

    function _distributeFees(LaunchTypes.Curve storage c, uint256 baseFee, uint256 creatorTax) internal {
        uint256 toProtocol = (baseFee * protocolShareBps) / 10_000;
        uint256 toCreator = baseFee - toProtocol + creatorTax;
        if (toProtocol > 0) _creditFee(c.quote, treasury, toProtocol);
        if (toCreator > 0) _creditFee(c.quote, c.creator, toCreator);
    }

    function _creditFee(address quote, address account, uint256 amount) internal {
        if (quote == address(0)) {
            escrow.creditNative{value: amount}(account);
        } else {
            quote.safeTransfer(address(escrow), amount);
            escrow.creditToken(account, quote, amount);
        }
    }

    function _payQuote(address quote, address to, uint256 amount) internal {
        if (quote == address(0)) to.safeTransferETH(amount);
        else quote.safeTransfer(to, amount);
    }

    function _snipeTaxBps(address token, LaunchTypes.Curve storage c, address recipient)
        internal
        view
        returns (uint256)
    {
        if (c.snipeTaxStartBps == 0 || c.snipeTaxSeconds == 0) return 0;
        if (snipeExempt[token][recipient] || snipeExempt[token][msg.sender]) return 0;
        uint256 elapsed = block.timestamp - c.createdAt;
        if (elapsed >= c.snipeTaxSeconds) return 0;
        uint256 halvings = (elapsed * 14) / c.snipeTaxSeconds;
        uint256 bps = uint256(c.snipeTaxStartBps) >> halvings;
        // never take more than leaves the buyer 1%
        uint256 cap = 10_000 - tradeFeeBps - c.creatorTaxBps - 100;
        return bps > cap ? cap : bps;
    }

    // ───────────────────────────── views ─────────────────────────────

    function getCurve(address token) external view returns (LaunchTypes.Curve memory) {
        return _curves[token];
    }

    function predictToken(bytes32 launchId) external view returns (address) {
        return factory.predict(launchId);
    }

    function manifestHash(LaunchTypes.Manifest calldata m) external pure returns (bytes32) {
        return m.hash();
    }

    function currentSnipeTaxBps(address token, address buyer) external view returns (uint256) {
        return _snipeTaxBps(token, _curves[token], buyer);
    }

    /// @notice Quote a buy of `quoteAmount` for `buyer`; returns tokens out and the quote actually spent.
    function quoteBuy(address token, uint256 quoteAmount, address buyer)
        external
        view
        returns (uint256 tokensOut, uint256 spent, uint256 totalFeeBps)
    {
        LaunchTypes.Curve storage c = _curves[token];
        if (c.status != LaunchTypes.Status.Active) return (0, 0, 0);
        totalFeeBps = uint256(tradeFeeBps) + c.creatorTaxBps + _snipeTaxBps(token, c, buyer);
        uint256 x = uint256(c.phantomQuote) + c.realQuote;
        uint256 y = uint256(c.supply) - c.tokensSold;
        uint256 sellable = y - c.reserved;
        spent = quoteAmount;
        uint256 net = spent - (spent * totalFeeBps) / 10_000;
        tokensOut = CurveMath.tokensOut(x, y, net);
        if (tokensOut >= sellable) {
            tokensOut = sellable;
            net = CurveMath.quoteIn(x, y, sellable);
            spent = CurveMath.grossForNet(net, totalFeeBps);
            if (spent > quoteAmount) spent = quoteAmount;
        }
    }

    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 quoteOut, uint256 fees) {
        LaunchTypes.Curve storage c = _curves[token];
        if (c.status != LaunchTypes.Status.Active || tokenAmount > c.tokensSold) return (0, 0);
        uint256 x = uint256(c.phantomQuote) + c.realQuote;
        uint256 y = uint256(c.supply) - c.tokensSold;
        uint256 gross = CurveMath.quoteOut(x, y, tokenAmount);
        fees = (gross * tradeFeeBps) / 10_000 + (gross * c.creatorTaxBps) / 10_000;
        quoteOut = gross - fees;
    }

    function spotPrice(address token) external view returns (uint256) {
        LaunchTypes.Curve storage c = _curves[token];
        if (c.status == LaunchTypes.Status.None) revert UnknownToken();
        return CurveMath.spotPrice(uint256(c.phantomQuote) + c.realQuote, uint256(c.supply) - c.tokensSold);
    }

    function sellableTokens(address token) external view returns (uint256) {
        LaunchTypes.Curve storage c = _curves[token];
        return uint256(c.supply) - c.tokensSold - c.reserved;
    }

    receive() external payable {}
}
