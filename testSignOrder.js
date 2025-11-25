import { signOrderRFQ, calculateWitness, WITNESS_TYPE_STRING, signPermit2WithWitness } from "./signOrderRFQ.js";
import { ethers } from "ethers";

const currentTime = Math.floor(Date.now() / 1000);
const expiry = currentTime + 90;

const MAKER_ADDRESS = "YOUR_MAKER_ADDRESS";
const privateKey = "YOUR_PRIVATE_KEY";

// Contract addresses
const VERIFYING_CONTRACT = "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853";
const PERMIT2_DOMAIN_SEPARATOR = "0x8a6e6e19bdfb3db3409910416b47c2f8fc28b49488d6555c7fceaa4479135bc3";

// Token addresses
const MAKER_ASSET = "0x111111111117dC0aa78b770fA6A738034120C302";
const TAKER_ASSET = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

const MAKER_AMOUNT = ethers.parseUnits("0.001", 18);
const TAKER_AMOUNT = ethers.parseUnits("0.001", 18);

const sig = await signOrderRFQ({
    privateKey: privateKey,
    // PMM settlement contract (`pool` as adapter's perspective)
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
});

const sig2 = await signOrderRFQ({
    privateKey: privateKey,
    // PMM settlement contract (`pool` as adapter's perspective)
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
});

const sig3 = await signOrderRFQ({
    privateKey: privateKey,
    // PMM settlement contract (`pool` as adapter's perspective)
    verifyingContract: VERIFYING_CONTRACT,
    chainId: 31337,
    order: {
        rfqId: 3,
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
                nonce: 3,
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
});

console.log("Signature 1:", sig);
console.log("Signature 2:", sig2);
console.log("Signature 3:", sig3);