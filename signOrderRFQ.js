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

  // OrderRFQ typehash from Solidity - must match exactly
  const ORDER_RFQ_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes(
    "OrderRFQ(uint256 rfqId,uint256 expiry,address makerAsset,address takerAsset,address makerAddress,uint256 makerAmount,uint256 takerAmount,bool usePermit2,bytes permit2Signature,bytes32 permit2Witness,string permit2WitnessType)"
  ));

  // Domain separator calculation matching Solidity
  const EIP712_DOMAIN_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
  ));
  
  const domainSeparator = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes32", "bytes32", "bytes32", "uint256", "address"],
    [
      EIP712_DOMAIN_TYPEHASH,
      ethers.keccak256(ethers.toUtf8Bytes(domain.name)),
      ethers.keccak256(ethers.toUtf8Bytes(domain.version)),
      domain.chainId,
      domain.verifyingContract
    ]
  ));

  // Struct hash calculation matching Solidity OrderRFQLib.hash()
  const structHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes32", "uint256", "uint256", "address", "address", "address", "uint256", "uint256", "bool", "bytes32", "bytes32", "bytes32"],
    [
      ORDER_RFQ_TYPEHASH,
      order.rfqId,
      order.expiry,
      order.makerAsset,
      order.takerAsset,
      order.makerAddress,
      order.makerAmount,
      order.takerAmount,
      order.usePermit2,
      ethers.keccak256(order.permit2Signature), // Hashed like in Solidity
      order.permit2Witness,
      ethers.keccak256(ethers.toUtf8Bytes(order.permit2WitnessType)) // Hashed like in Solidity
    ]
  ));

  // Final digest calculation matching ECDSA.toTypedDataHash
  const digest = ethers.keccak256(ethers.concat([
    "0x1901",
    domainSeparator,
    structHash
  ]));

  // Sign the digest directly (EIP-712 signature, no Ethereum message prefix)
  // Use signingKey.sign() to sign the raw digest without any prefixes
  const sig = wallet.signingKey.sign(digest);
  
  // Reconstruct signature as r + s + v to match Solidity abi.encodePacked(r, s, v)
  const rearrangedSignature = ethers.concat([sig.r, sig.s, ethers.toBeHex(sig.v, 1)]);
  
  return ethers.hexlify(rearrangedSignature);
}

export const EXAMPLE_WITNESS_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes("ExampleWitness(address user)"));
export const WITNESS_TYPE_STRING = "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)"
export const TOKEN_PERMISSIONS_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes("TokenPermissions(address token,uint256 amount)"));

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
 * @param {object} permit - Permit2 PermitTransferFrom object with { permitted: { token, amount }, nonce, deadline }
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

  // Sign the digest directly (EIP-712 signature, no Ethereum message prefix)
  // Use _signingKey().sign() to sign the raw digest without any prefixes
  const sig = wallet.signingKey.sign(digest);
  
  // Reconstruct signature as r + s + v to match Solidity abi.encodePacked(r, s, v)
  const rearrangedSignature = ethers.concat([sig.r, sig.s, ethers.toBeHex(sig.v, 1)]);
  
  return ethers.hexlify(rearrangedSignature);
}