import "dotenv/config";
import { ethers } from "ethers";
import { calculateWitness, calculateWitnessConsideration, signOrderRFQ, signPermit2WithWitness, WITNESS_TYPE_STRING } from "./signOrderRFQ.js";

const currentTime = Math.floor(Date.now() / 1000);
const expiry = currentTime + 1000*60 * 60 * 24 * 30;
const privateKey = process.env.PK;
const MAKER_ADDRESS = new ethers.Wallet(privateKey).address;


const VERIFYING_CONTRACT = "0x1Ef032a3c471a99CC31578c8007F256D95E89896";
const PERMIT2_DOMAIN_SEPARATOR = "0x8a6e6e19bdfb3db3409910416b47c2f8fc28b49488d6555c7fceaa4479135bc3";

const MAKER_ASSET = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const TAKER_ASSET = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";

const MAKER_AMOUNT = 100;
const TAKER_AMOUNT = 90;

const chainId = 42161;

const rfqId = Math.floor(Math.random() * 10000000000000);

// Order 1: usePermit2: false
const order1 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: chainId,
    order: {
        rfqId: rfqId,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: false,
        confidenceT: 0,
        confidenceWeight: 0,
        confidenceCap: 0,
        permit2Signature: "0x",
        permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
        permit2WitnessType: ""
    },
};

// Order 2: usePermit2: true, no witness
const order2 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: chainId,
    order: {
        rfqId: rfqId,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: true,
        confidenceT: 0,
        confidenceWeight: 0,
        confidenceCap: 0,
        permit2Signature: "0x",
        permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
        permit2WitnessType: ""
    },
};

// Order 3: usePermit2: true, with witness
const order3 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: chainId,
    order: {
        rfqId: rfqId,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: true,
        confidenceT: 0,
        confidenceWeight: 0,
        confidenceCap: 0,
        permit2Signature: await signPermit2WithWitness({
            permit: {
                permitted: {
                    token: MAKER_ASSET,
                    amount: MAKER_AMOUNT
                },
                nonce: rfqId,
                deadline: expiry
            },
            spender: VERIFYING_CONTRACT,
            witness: calculateWitness({ user: MAKER_ADDRESS }),
            witnessTypeString: WITNESS_TYPE_STRING,
            privateKey: privateKey,
            permit2DomainSeparator: PERMIT2_DOMAIN_SEPARATOR
        }),
        permit2Witness: calculateWitness({ user: MAKER_ADDRESS }),
        permit2WitnessType: WITNESS_TYPE_STRING
    },
};
const TAKER_ADDRESS = "0x1111111111111111111111111111111111111111";
const CONSIDERATION = {
    token: MAKER_ASSET,
    amount: MAKER_AMOUNT,
    counterparty: TAKER_ADDRESS
};
const CONSIDERATION_TYPE_STRING_STUB = "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";
// Order 4: usePermit2: true, with witness
const order4 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: chainId,
    order: {
        rfqId: rfqId,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: true,
        confidenceT: 0,
        confidenceWeight: 0,
        confidenceCap: 0,
        permit2Signature: await signPermit2WithWitness({
            permit: {
                permitted: {
                    token: MAKER_ASSET,
                    amount: MAKER_AMOUNT
                },
                nonce: rfqId,
                deadline: expiry
            },
            spender: VERIFYING_CONTRACT,
            witness: calculateWitnessConsideration(CONSIDERATION),
            witnessTypeString: CONSIDERATION_TYPE_STRING_STUB,
            privateKey: privateKey,
            permit2DomainSeparator: PERMIT2_DOMAIN_SEPARATOR
        }),
        permit2Witness: calculateWitnessConsideration(CONSIDERATION),
        permit2WitnessType: CONSIDERATION_TYPE_STRING_STUB
    },
};

// console.log("Signature 1:", await signOrderRFQ(order1));
// console.log("Signature 2:", await signOrderRFQ(order2));
// console.log("Signature 3:", await signOrderRFQ(order3));
console.log("CONSIDERATION:", CONSIDERATION);
console.log("order4:", order4);
const order4Signature = await signOrderRFQ(order4);
console.log("Signature 4:", order4Signature);

// send tx to fill order (optional)
// Requirements:
// - export RPC_URL=https://arb1.arbitrum.io/rpc (or your node)
// - export TAKER_PK=0x...
// - export SEND_TX=1
const sendTx = async () => {
  const rpcUrl = process.env.RPC_URL || "https://arb1.arbitrum.io/rpc";
  const takerPk = process.env.PK;
  if (!takerPk) throw new Error("missing env: TAKER_PK");

  const provider = new ethers.JsonRpcProvider(rpcUrl, chainId);
  const taker = new ethers.Wallet(takerPk, provider);

  const pmmAbi = [
    "function fillOrderRFQTo((uint256 rfqId,uint256 expiry,address makerAsset,address takerAsset,address makerAddress,uint256 makerAmount,uint256 takerAmount,bool usePermit2,uint256 confidenceT,uint256 confidenceWeight,uint256 confidenceCap,bytes permit2Signature,bytes32 permit2Witness,string permit2WitnessType) order, bytes signature, uint256 flagsAndAmount, address target) returns (uint256,uint256,bytes32)",
  ];

  const pmm = new ethers.Contract(VERIFYING_CONTRACT, pmmAbi, taker);

  const flagsAndAmount = BigInt(order4.order.takerAmount);
  const target = taker.address;

  const tx = await pmm.fillOrderRFQTo(order4.order, order4Signature, flagsAndAmount, target);
  console.log("fill tx:", tx.hash);
  await tx.wait();
}
sendTx();
// console.log("permit2Signature (Order 3):", order3.order.permit2Signature);