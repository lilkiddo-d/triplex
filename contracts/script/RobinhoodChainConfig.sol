// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Robinhood Chain mainnet (chain id 4663) addresses. Mirrors /config/chains.ts — every value is sourced:
///  - tokens:    https://docs.robinhood.com/chain/contracts + https://api.robinhood.com/rhj/assets (official registry)
///  - Chainlink: https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
///  - Morpho:    https://docs.morpho.org/get-started/resources/addresses/ (Robinhood Chain)
///  - Uniswap:   https://github.com/Uniswap/sdks/blob/main/sdks/sdk-core/src/addresses.ts (ROBINHOOD_ADDRESSES)
library RobinhoodChainConfig {
    uint256 internal constant CHAIN_ID = 4663;

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    address internal constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address internal constant MORPHO_ADAPTIVE_CURVE_IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;
    address internal constant MORPHO_CHAINLINK_ORACLE_V2_FACTORY = 0xB7c16F6F8cF531447Bf27Ca7220f981E79C9cdF2;
    uint256 internal constant MORPHO_LLTV = 0.86e18;

    address internal constant UNI_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant UNI_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    struct Stock {
        string symbol;
        address token;
        address feed;
        uint24 uniFee;
    }

    /// @notice The five most liquid equity tokens (Uniswap v3 USDG-pool TVL, 2026-10-08; see DECISIONS.md).
    function stocks() internal pure returns (Stock[] memory s) {
        s = new Stock[](5);
        s[0] = Stock("CRCL", 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5, 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a, 3000);
        s[1] = Stock("NVDA", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15, 500);
        s[2] = Stock("SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb, 500);
        s[3] = Stock("MU", 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596, 3000);
        s[4] = Stock("QQQ", 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, 0x80901d846d5D7B030F26B480776EE3b29374C2ae, 500);
    }
}
