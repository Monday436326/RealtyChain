import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

module.exports = buildModule("CrossChainManagerModule", (m) => {
  // Import contracts from previous modules
  const { propertyToken, propertyVault } = m.useModule(require("./PropVault"));
  
  // Parameters
  const initialOwner = m.getAccount(0);
  const ccipRouter = "0xD0daae2231E9CB96b94C8512223533293C3693Bf";
  
  // Deploy CrossChainManager
  const crossChainManager = m.contract("CrossChainManager", [
    ccipRouter,
    propertyToken,
    propertyVault,
    initialOwner
  ]);

  return { propertyToken, propertyVault, crossChainManager };
});