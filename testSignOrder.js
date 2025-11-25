import { signOrderRFQ } from "./signOrderRFQ.js";
import { ethers } from "ethers";

const currentTime = Math.floor(Date.now() / 1000);
const expiry = currentTime + 90;
const sig = await signOrderRFQ({
    // foundry local test account
    privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    // PMM settlement contract (`pool` as adapter's perspective)
    verifyingContract: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
    chainId: 31337,
    order: {
        rfqId: 1,
        expiry: expiry,
        makerAsset: "0x111111111117dC0aa78b770fA6A738034120C302",
        takerAsset: "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
        makerAddress: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        // 100000000000000000000
        makerAmount: ethers.parseUnits("100", 18),
        // 500000000000000000
        takerAmount: ethers.parseUnits("0.5", 18),
        usePermit2: true,
        permit2Signature: "0x",
        permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
        permit2WitnessType: ""
    },
});

console.log("Signature:", sig);
