// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DeployBase} from "./DeployBase.sol";
import {RobinhoodChainConfig as C} from "./RobinhoodChainConfig.sol";

/// @title Deploy
/// @notice One-shot deployment of Triplex on Robinhood Chain (or a local anvil fork of it):
///         deploys and wires every contract, creates the 20 products (3L/2L/1S/2S x 5 stocks), hands all admin
///         roles to the 48h Timelock, and writes `deployments/<chainId>.json` + the frontend config.
///
///         Signs ONLY through the Foundry keystore account passed on the CLI (`--account triplex-deployer`);
///         this script never reads a private key. Optional env:
///           GUARDIAN, KEEPER, PROPOSER, TREASURY  (default: deployer; TREASURY default: the Timelock)
contract Deploy is Script, DeployBase {
    function run() external returns (Deployment memory d) {
        address deployer = msg.sender;
        require(block.chainid == C.CHAIN_ID || block.chainid == 31337, "Deploy: unsupported chain");
        require(C.USDG.code.length != 0, "Deploy: USDG missing - run against Robinhood Chain or a fork of it");

        Roles memory r = Roles({
            deployer: deployer,
            guardian: vm.envOr("GUARDIAN", deployer),
            keeper: vm.envOr("KEEPER", deployer),
            proposer: vm.envOr("PROPOSER", deployer),
            treasury: vm.envOr("TREASURY", address(0))
        });

        // On Arbitrum-based chains `block.number` is an L1 estimate; logs are indexed by the L2 number.
        uint256 startBlock = _l2BlockNumber();
        vm.startBroadcast(deployer);
        d = _deploy(r);
        vm.stopBroadcast();

        _log(d, r);
        _write(d, startBlock);
    }

    function _l2BlockNumber() internal returns (uint256) {
        bytes memory raw = vm.rpc("eth_blockNumber", "[]");
        uint256 n;
        for (uint256 i; i < raw.length; ++i) n = (n << 8) | uint8(raw[i]);
        return n;
    }

    // ---------------------------------------------------------------- outputs

    function _write(Deployment memory d, uint256 startBlock) internal {
        string memory json = _json(d, startBlock);
        string memory chain = vm.toString(block.chainid);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            // simulation only: never overwrite real deployment files with simulated addresses
            vm.writeFile(string.concat("deployments/", chain, "-dryrun.json"), json);
            console2.log("Dry run: wrote deployments/%s-dryrun.json", chain);
            return;
        }
        vm.writeFile(string.concat("deployments/", chain, ".json"), json);
        vm.writeFile(string.concat("../app/src/config/deployments/", chain, ".json"), json);
        console2.log("Wrote deployments/%s.json and app/src/config/deployments/%s.json", chain, chain);
    }

    function _json(Deployment memory d, uint256 startBlock) internal view returns (string memory s) {
        s = string.concat("{\n", _kv("chainId", vm.toString(block.chainid), false));
        s = string.concat(s, _kv("deployBlock", vm.toString(startBlock), false));
        s = string.concat(s, _addr("quoteToken", C.USDG), _addr("factory", address(d.factory)));
        s = string.concat(s, _addr("navCalculator", address(d.nav)), _addr("rebalancer", address(d.rebalancer)));
        s = string.concat(s, _addr("oracle", address(d.oracle)), _addr("marketClock", address(d.clock)));
        s = string.concat(s, _addr("feeCollector", address(d.feeCollector)), _addr("projectTokenHooks", address(d.hooks)));
        s = string.concat(s, _addr("complianceRegistry", address(d.compliance)), _addr("timelock", address(d.timelock)));
        s = string.concat(s, _addr("swapAdapter", address(d.swapAdapter)), _addr("twapPriceSource", address(d.twap)));
        s = string.concat(s, _addr("tokenImplementation", d.tokenImpl), _addr("adapterImplementation", d.adapterImpl));
        s = string.concat(s, '  "products": [\n');
        for (uint256 i; i < d.products.length; ++i) {
            s = string.concat(s, _productJson(d.products[i]), i + 1 == d.products.length ? "\n" : ",\n");
        }
        s = string.concat(s, "  ]\n}\n");
    }

    function _addr(string memory k, address a) internal pure returns (string memory) {
        return _kv(k, vm.toString(a), true);
    }

    function _productJson(ProductOut memory p) internal pure returns (string memory j) {
        j = string.concat('    { "symbol": "', p.symbol, '", "address": "', vm.toString(p.product));
        j = string.concat(j, '", "adapter": "', vm.toString(p.adapter), '", "underlying": "', vm.toString(p.underlying));
        j = string.concat(j, '", "underlyingSymbol": "', p.underlyingSymbol, '", "isLong": ');
        j = string.concat(j, p.isLong ? "true" : "false", ', "targetLeverage": ', vm.toString(p.targetLeverage / 1e18), " }");
    }

    function _kv(string memory k, string memory v, bool quoted) internal pure returns (string memory) {
        return quoted ? string.concat('  "', k, '": "', v, '",\n') : string.concat('  "', k, '": ', v, ",\n");
    }

    function _log(Deployment memory d, Roles memory r) internal pure {
        console2.log("Timelock (admin of everything):", address(d.timelock));
        console2.log("Factory / registry:", address(d.factory));
        console2.log("Rebalancer:", address(d.rebalancer));
        console2.log("NAVCalculator:", address(d.nav));
        console2.log("ProjectTokenHooks:", address(d.hooks));
        console2.log("Guardian:", r.guardian);
        console2.log("Products:", d.products.length);
    }
}
