import { activeChain } from "./chains";
import { CORE_TOKENS } from "./constants";
import { getDeployment, isDeployed, isSet } from "./deployments";
import { ENV } from "./env";

export const deployment = getDeployment(activeChain.id);
export const deployed = isDeployed(deployment);

/** USDG: from the deployment file, falling back to the canonical mainnet address. */
export const quoteToken = isSet(deployment.quoteToken) ? deployment.quoteToken : CORE_TOKENS.USDG.address;

/** Token features need the env var AND a deployed hooks contract (isActive() is checked at runtime). */
export const tokenFeaturesConfigured = !!ENV.projectToken && isSet(deployment.projectTokenHooks);

export { activeChain, ENV };
