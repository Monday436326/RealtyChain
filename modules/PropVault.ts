import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

module.exports = buildModule("PropVaultModule", (m) => {
  // Import PropertyToken from previous module
  const { propertyToken } = m.useModule(require("./PropToken"));
  
  // Parameters - these should be configured per network
  const initialOwner = m.getAccount(0);
  const ethUsdPriceFeed = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
  const vrfCoordinator = "0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625";
  const functionsRouter = "0xb83E47C2bC239B3bf370bc41e1459A34b41238D0";
  const donId = "0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";
  
  // Deploy PropertyVault
  const propertyVault = m.contract("PropVault", [
    propertyToken,
    ethUsdPriceFeed,
    vrfCoordinator,
    functionsRouter,
    donId,
    initialOwner
  ]);

  return { propertyToken, propertyVault };
});