import assert from "node:assert/strict";
import { Wallet, ethers } from "ethers";
import {
  CONSIDERATION_WITNESS_TYPE_STRING,
  ORDER_RFQ_FIELDS,
  ORDER_RFQ_TYPEHASH,
  ORDER_RFQ_TYPE_STRING,
  ORDER_RFQ_TYPES,
  PERMIT2_ADDRESS,
  PMM_DOMAIN_NAME,
  PMM_DOMAIN_VERSION,
  calculateWitnessConsideration,
  signOrderRFQ,
  signPermit2WithWitness,
} from "./signOrderRFQ.js";

const CHAIN_ID = 31337n;
const PMM_PROTOCOL = `0x${"44".repeat(20)}`;
const ALLOWED_SENDER = `0x${"66".repeat(20)}`;
const MAKER_ASSET = `0x${"77".repeat(20)}`;
const TAKER_ASSET = `0x${"88".repeat(20)}`;

function permit2DomainSeparator() {
  const abi = ethers.AbiCoder.defaultAbiCoder();
  return ethers.keccak256(
    abi.encode(
      ["bytes32", "bytes32", "uint256", "address"],
      [
        ethers.keccak256(
          ethers.toUtf8Bytes(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
          )
        ),
        ethers.keccak256(ethers.toUtf8Bytes("Permit2")),
        CHAIN_ID,
        PERMIT2_ADDRESS,
      ]
    )
  );
}

function orderDigest(order) {
  return ethers.TypedDataEncoder.hash(
    {
      name: PMM_DOMAIN_NAME,
      version: PMM_DOMAIN_VERSION,
      chainId: CHAIN_ID,
      verifyingContract: PMM_PROTOCOL,
    },
    ORDER_RFQ_TYPES,
    order
  );
}

async function main() {
  const maker = Wallet.createRandom();
  const consideration = {
    token: MAKER_ASSET,
    amount: 1_000_000n,
    counterparty: ALLOWED_SENDER,
  };
  const witness = calculateWitnessConsideration(consideration);
  const permit = {
    permitted: { token: MAKER_ASSET, amount: consideration.amount },
    nonce: 123456n,
    deadline: 2_000_000_000n,
  };
  const permit2Signature = await signPermit2WithWitness({
    permit,
    spender: PMM_PROTOCOL,
    witness,
    witnessTypeString: CONSIDERATION_WITNESS_TYPE_STRING,
    privateKey: maker.privateKey,
    permit2DomainSeparator: permit2DomainSeparator(),
  });
  const permitDigest = ethers.TypedDataEncoder.hash(
    { name: "Permit2", chainId: CHAIN_ID, verifyingContract: PERMIT2_ADDRESS },
    {
      TokenPermissions: [
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
      ],
      Consideration: [
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "counterparty", type: "address" },
      ],
      PermitWitnessTransferFrom: [
        { name: "permitted", type: "TokenPermissions" },
        { name: "spender", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "witness", type: "Consideration" },
      ],
    },
    {
      permitted: permit.permitted,
      spender: PMM_PROTOCOL,
      nonce: permit.nonce,
      deadline: permit.deadline,
      witness: consideration,
    }
  );
  assert.equal(ethers.recoverAddress(permitDigest, permit2Signature), maker.address);

  const order = {
    rfqId: permit.nonce,
    expiry: permit.deadline,
    makerAsset: MAKER_ASSET,
    takerAsset: TAKER_ASSET,
    makerAddress: maker.address,
    makerAmount: consideration.amount,
    takerAmount: 2_000_000n,
    usePermit2: true,
    allowedSender: ALLOWED_SENDER,
    confidenceT: 0n,
    confidenceWeight: 0n,
    confidenceCap: 0n,
    permit2Signature,
    permit2Witness: witness,
    permit2WitnessType: CONSIDERATION_WITNESS_TYPE_STRING,
  };
  const signature = await signOrderRFQ({
    privateKey: maker.privateKey,
    verifyingContract: PMM_PROTOCOL,
    chainId: CHAIN_ID,
    order,
  });

  assert.equal(PMM_DOMAIN_VERSION, "1.2");
  assert.equal(ORDER_RFQ_FIELDS.length, 15);
  assert.deepEqual(ORDER_RFQ_FIELDS[8], { name: "allowedSender", type: "address" });
  assert.equal(
    ORDER_RFQ_TYPEHASH,
    ethers.keccak256(ethers.toUtf8Bytes(ORDER_RFQ_TYPE_STRING))
  );
  assert.equal(ethers.dataLength(permit2Signature), 65);
  assert.equal(ethers.dataLength(signature), 65);
  assert.equal(ethers.recoverAddress(orderDigest(order), signature), maker.address);

  console.log("OrderRFQ signing self-check passed");
  console.log("  EIP-712 domain version: 1.2");
  console.log("  allowedSender field: verified");
  console.log("  Permit2 witness signature: verified");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
