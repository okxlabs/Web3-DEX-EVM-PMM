import { signOrderRFQ, calculateWitness, WITNESS_TYPE_STRING, signPermit2WithWitness } from "./signOrderRFQ.js";

const currentTime = Math.floor(Date.now() / 1000);
const expiry = currentTime + 90;

const MAKER_ADDRESS = "YOUR_ADDRESS";
const privateKey = "YOUR_PRIVATE_KEY";

const VERIFYING_CONTRACT = "0x5C1c902e7E04DE98b49aCd3De68E12BEE2d7908D";
const PERMIT2_DOMAIN_SEPARATOR = "0x8a6e6e19bdfb3db3409910416b47c2f8fc28b49488d6555c7fceaa4479135bc3";

const MAKER_ASSET = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1";
const TAKER_ASSET = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";

const MAKER_AMOUNT = 400000000000000;
const TAKER_AMOUNT = 1000;

const rfqId = 3312;

// Order 1: usePermit2: false
const order1 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: 31337,
    order: {
        rfqId: 1,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: false,
        permit2Signature: "0x",
        permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
        permit2WitnessType: ""
    },
};

// Order 2: usePermit2: true, no witness
const order2 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: 31337,
    order: {
        rfqId: 2,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: true,
        permit2Signature: "0x",
        permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
        permit2WitnessType: ""
    },
};

// Order 3: usePermit2: true, with witness
const order3 = {
    privateKey: privateKey,
    verifyingContract: VERIFYING_CONTRACT,
    chainId: 42161,
    order: {
        rfqId: rfqId,
        expiry: expiry,
        makerAsset: MAKER_ASSET,
        takerAsset: TAKER_ASSET,
        makerAddress: MAKER_ADDRESS,
        makerAmount: MAKER_AMOUNT,
        takerAmount: TAKER_AMOUNT,
        usePermit2: true,
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

console.log("Signature 1:", await signOrderRFQ(order1));
console.log("Signature 2:", await signOrderRFQ(order2));
console.log("Signature 3:", await signOrderRFQ(order3));
console.log("permit2Signature (Order 3):", order3.order.permit2Signature);