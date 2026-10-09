`<chainId>.json` files in this folder are written by `contracts/script/Deploy.s.sol`.
Schema (all addresses checksummed hex strings):

```json
{
  "chainId": 4663,
  "deployBlock": 0,
  "quoteToken": "0x...",          // USDG
  "factory": "0x...",
  "navCalculator": "0x...",
  "rebalancer": "0x...",
  "oracle": "0x...",
  "marketClock": "0x...",
  "feeCollector": "0x...",
  "projectTokenHooks": "0x...",
  "complianceRegistry": "0x...",
  "timelock": "0x...",
  "products": [
    { "symbol": "3L-NVDA", "address": "0x...", "adapter": "0x...", "underlying": "0x...",
      "underlyingSymbol": "NVDA", "isLong": true, "targetLeverage": 3 }
  ]
}
```
