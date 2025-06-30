import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";


module.exports = buildModule("PropertyTokenModule", (m) => {
  // Parameters
  const initialOwner = m.getAccount(0);
  const baseURI = m.getParameter("baseURI", "https://api.realtychain.com/metadata/");
  
  // Deploy PropertyToken first (without propertyVault address)
  const propertyToken = m.contract("PropToken", [
    baseURI,
    "0x0000000000000000000000000000000000000000", // Temporary address
    initialOwner
  ]);

  return { propertyToken };
});