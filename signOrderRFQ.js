import { Wallet, ethers } from "ethers";

/**
 * Sign an OrderRFQ-typed struct and return the signature string
 *
 * @param {string} privateKey - Signer's private key (EOA)
 * @param {string} verifyingContract - Address of the contract used for signature verification
 * @param {number} chainId - Current chain ID
 * @param {object} order - Order object containing fields like rfqId, expiration, etc.
 * @returns {Promise<string>} - EIP-712 signature string
 */
export async function signOrderRFQ({ privateKey, verifyingContract, chainId, order }) {
  const wallet = new Wallet(privateKey);

  const domain = {
    name: "OKX Lab PMM Protocol",
    version: "1.0",
    chainId,
    verifyingContract,
  };

  const types = {
    OrderRFQ: [
      { name: "rfqId", type: "uint256" },
      { name: "expiry", type: "uint256" },
      { name: "makerAsset", type: "address" },
      { name: "takerAsset", type: "address" },
      { name: "makerAddress", type: "address" },
      { name: "makerAmount", type: "uint256" },
      { name: "takerAmount", type: "uint256" },
      { name: "usePermit2", type: "bool" },
    ],
  };

  const signature = await wallet.signTypedData(domain, types, order);
  return signature;
}
