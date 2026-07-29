import { Wallet, ethers } from "ethers";

const abi = ethers.AbiCoder.defaultAbiCoder();

export const PMM_DOMAIN_NAME = "OKX Labs PMM Protocol";
export const PMM_DOMAIN_VERSION = "1.2";
export const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

export const ORDER_RFQ_FIELDS = Object.freeze([
  { name: "rfqId", type: "uint256" },
  { name: "expiry", type: "uint256" },
  { name: "makerAsset", type: "address" },
  { name: "takerAsset", type: "address" },
  { name: "makerAddress", type: "address" },
  { name: "makerAmount", type: "uint256" },
  { name: "takerAmount", type: "uint256" },
  { name: "usePermit2", type: "bool" },
  { name: "allowedSender", type: "address" },
  { name: "confidenceT", type: "uint256" },
  { name: "confidenceWeight", type: "uint256" },
  { name: "confidenceCap", type: "uint256" },
  { name: "permit2Signature", type: "bytes" },
  { name: "permit2Witness", type: "bytes32" },
  { name: "permit2WitnessType", type: "string" },
]);

export const ORDER_RFQ_TYPES = Object.freeze({ OrderRFQ: ORDER_RFQ_FIELDS });
export const ORDER_RFQ_TYPE_STRING =
  "OrderRFQ(uint256 rfqId,uint256 expiry,address makerAsset,address takerAsset," +
  "address makerAddress,uint256 makerAmount,uint256 takerAmount,bool usePermit2," +
  "address allowedSender,uint256 confidenceT,uint256 confidenceWeight,uint256 confidenceCap," +
  "bytes permit2Signature,bytes32 permit2Witness,string permit2WitnessType)";
export const ORDER_RFQ_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes(ORDER_RFQ_TYPE_STRING));

export const EXAMPLE_WITNESS_TYPEHASH = ethers.keccak256(
  ethers.toUtf8Bytes("ExampleWitness(address user)")
);
export const WITNESS_TYPE_STRING =
  "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)";
export const TOKEN_PERMISSIONS_TYPEHASH = ethers.keccak256(
  ethers.toUtf8Bytes("TokenPermissions(address token,uint256 amount)")
);
export const CONSIDERATION_TYPEHASH = ethers.keccak256(
  ethers.toUtf8Bytes("Consideration(address token,uint256 amount,address counterparty)")
);
export const CONSIDERATION_WITNESS_TYPE_STRING =
  "Consideration witness)Consideration(address token,uint256 amount,address counterparty)" +
  "TokenPermissions(address token,uint256 amount)";

export async function signOrderRFQ({ privateKey, verifyingContract, chainId, order }) {
  const wallet = new Wallet(privateKey);
  return wallet.signTypedData(
    {
      name: PMM_DOMAIN_NAME,
      version: PMM_DOMAIN_VERSION,
      chainId,
      verifyingContract,
    },
    ORDER_RFQ_TYPES,
    order
  );
}

export function calculateWitness(witnessData, witnessTypehash = EXAMPLE_WITNESS_TYPEHASH) {
  return ethers.keccak256(abi.encode(["bytes32", "address"], [witnessTypehash, witnessData.user]));
}

export function calculateWitnessConsideration(
  consideration,
  witnessTypehash = CONSIDERATION_TYPEHASH
) {
  return ethers.keccak256(
    abi.encode(
      ["bytes32", "address", "uint256", "address"],
      [
        witnessTypehash,
        consideration.token,
        consideration.amount,
        consideration.counterparty,
      ]
    )
  );
}

export async function signPermit2WithWitness({
  permit,
  spender,
  witness,
  witnessTypeString,
  privateKey,
  permit2DomainSeparator,
}) {
  const permitTypehash = ethers.keccak256(
    ethers.toUtf8Bytes(
      `PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,${witnessTypeString}`
    )
  );
  const tokenPermissionsHash = ethers.keccak256(
    abi.encode(
      ["bytes32", "address", "uint256"],
      [TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount]
    )
  );
  const structHash = ethers.keccak256(
    abi.encode(
      ["bytes32", "bytes32", "address", "uint256", "uint256", "bytes32"],
      [permitTypehash, tokenPermissionsHash, spender, permit.nonce, permit.deadline, witness]
    )
  );
  const digest = ethers.keccak256(
    ethers.concat(["0x1901", permit2DomainSeparator, structHash])
  );
  return new Wallet(privateKey).signingKey.sign(digest).serialized;
}
