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
      { name: "permit2Signature", type: "bytes" },
      { name: "permit2Witness", type: "bytes32" },
      { name: "permit2WitnessType", type: "string" },
    ],
  };

  const signature = await wallet.signTypedData(domain, types, order);
  return signature;
}

// Example Witness Type Hash and String (matching the Solidity implementation)
export const EXAMPLE_WITNESS_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes("ExampleWitness(address user)"));
export const WITNESS_TYPE_STRING = "ExampleWitness witness)ExampleWitness(address user)";

/**
 * Calculate permit2 witness hash from witness data
 *
 * @param {object} witnessData - Witness data object (e.g., { user: address })
 * @param {string} witnessTypehash - Keccak256 hash of the witness type string
 * @returns {string} - Witness hash as bytes32
 */
export function calculateWitness(witnessData, witnessTypehash = EXAMPLE_WITNESS_TYPEHASH) {
  // For ExampleWitness struct: { user: address }
  const encodedWitness = ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes32", "address"],
    [witnessTypehash, witnessData.user]
  );
  return ethers.keccak256(encodedWitness);
}

/**
 * Sign Permit2 with witness support
 *
 * @param {object} permit - Permit2 PermitTransferFrom object
 * @param {string} spender - Spender address (usually the PMM contract)
 * @param {string} witness - Witness hash (bytes32)
 * @param {string} witnessTypeString - Full witness type string for EIP-712
 * @param {string} privateKey - Signer's private key
 * @param {string} permit2DomainSeparator - Permit2 contract's domain separator
 * @returns {Promise<string>} - Permit2 signature
 */
export async function signPermit2WithWitness({
  permit,
  spender,
  witness,
  witnessTypeString,
  privateKey,
  permit2DomainSeparator
}) {
  const wallet = new Wallet(privateKey);
  
  const TOKEN_PERMISSIONS_TYPEHASH = ethers.keccak256(
    ethers.toUtf8Bytes("TokenPermissions(address token,uint256 amount)")
  );

  // Construct the full type hash for PermitWitnessTransferFrom
  const PERMIT_WITNESS_TRANSFER_FROM_TYPEHASH = ethers.keccak256(
    ethers.toUtf8Bytes(
      `PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,${witnessTypeString}`
    )
  );

  // Encode the TokenPermissions struct
  const tokenPermissionsHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "address", "uint256"],
      [TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount]
    )
  );

  // Encode the main struct
  const structHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "bytes32", "address", "uint256", "uint256", "bytes32"],
      [
        PERMIT_WITNESS_TRANSFER_FROM_TYPEHASH,
        tokenPermissionsHash,
        spender,
        permit.nonce,
        permit.deadline,
        witness
      ]
    )
  );

  // Create the final digest
  const digest = ethers.keccak256(
    ethers.concat([
      "0x1901",
      permit2DomainSeparator,
      structHash
    ])
  );

  // Sign the digest
  const signature = await wallet.signMessage(ethers.getBytes(digest));
  return signature;
}

/**
 * Helper function to create permit2 signature for an order
 * 
 * @param {string} privateKey - Signer's private key
 * @param {string} makerAsset - Token address to permit
 * @param {string} makerAmount - Amount to permit (as BigInt or string)
 * @param {string} spender - Address that will spend the tokens (PMM contract)
 * @param {number} expiry - Expiration timestamp
 * @param {object} witnessData - Witness data object (e.g., { user: address })
 * @param {number} nonce - Permit2 nonce (default: 0)
 * @param {string} permit2DomainSeparator - Permit2 contract's domain separator
 * @returns {Promise<{signature: string, witnessHash: string}>} - Permit2 signature and witness hash
 */
export async function createPermit2SignatureForOrder({
  privateKey,
  makerAsset,
  makerAmount,
  spender,
  expiry,
  witnessData,
  nonce = 0,
  permit2DomainSeparator
}) {
  // Calculate witness hash
  const witnessHash = calculateWitness(witnessData);
  
  // Create permit2 data structure
  const permit2Data = {
    permitted: {
      token: makerAsset,
      amount: makerAmount
    },
    nonce: nonce,
    deadline: expiry
  };

  // Calculate permit2 signature
  const signature = await signPermit2WithWitness({
    permit: permit2Data,
    spender: spender,
    witness: witnessHash,
    witnessTypeString: WITNESS_TYPE_STRING,
    privateKey: privateKey,
    permit2DomainSeparator: permit2DomainSeparator
  });

  return {
    signature,
    witnessHash
  };
}
