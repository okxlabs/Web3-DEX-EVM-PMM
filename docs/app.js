/**
 * EIP-712 Signature Debug Tool for PMM Protocol
 * Adapted from signOrderRFQ.js for browser usage
 */

// Constants matching the Solidity contract
const DOMAIN_NAME = "OnChain Labs PMM Protocol";
const DOMAIN_VERSION = "1.0";

const ORDER_RFQ_TYPE_STRING = 
    "OrderRFQ(" +
    "uint256 rfqId," +
    "uint256 expiry," +
    "address makerAsset," +
    "address takerAsset," +
    "address makerAddress," +
    "uint256 makerAmount," +
    "uint256 takerAmount," +
    "bool usePermit2," +
    "bytes permit2Signature," +
    "bytes32 permit2Witness," +
    "string permit2WitnessType" +
    ")";

const EIP712_DOMAIN_TYPE_STRING = 
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

// Example order for testing
const EXAMPLE_ORDER = {
    chainId: 1,
    verifyingContract: "0x1234567890123456789012345678901234567890",
    order: {
        rfqId: "4262300009041366528",
        expiry: Math.floor(Date.now() / 1000) + 3600,
        makerAsset: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
        takerAsset: "0xdac17f958d2ee523a2206206994597c13d831ec7",
        makerAddress: "0xd68e2150cd2da77decaeb01ab630c864ad612aaa",
        makerAmount: "1000000000000000",
        takerAmount: "3198469",
        usePermit2: false,
        permit2Signature: "0x",
        permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
        permit2WitnessType: ""
    },
    privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    permit2DomainSeparator: "0x0000000000000000000000000000000000000000000000000000000000000000"
};

/**
 * Calculate the domain separator
 */
function calculateDomainSeparator(chainId, verifyingContract) {
    const domainTypeHash = ethers.keccak256(ethers.toUtf8Bytes(EIP712_DOMAIN_TYPE_STRING));
    const nameHash = ethers.keccak256(ethers.toUtf8Bytes(DOMAIN_NAME));
    const versionHash = ethers.keccak256(ethers.toUtf8Bytes(DOMAIN_VERSION));
    
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [domainTypeHash, nameHash, versionHash, chainId, verifyingContract]
    );
    
    return {
        domainTypeHash,
        domainSeparator: ethers.keccak256(encoded)
    };
}

/**
 * Calculate the struct hash for OrderRFQ
 * Returns both the raw encoded data and the hash
 */
function calculateStructHash(order) {
    const typeHash = ethers.keccak256(ethers.toUtf8Bytes(ORDER_RFQ_TYPE_STRING));
    
    // Ensure permit2Signature is properly formatted
    let permit2SigBytes = order.permit2Signature;
    if (!permit2SigBytes || permit2SigBytes === "0x" || permit2SigBytes === "") {
        permit2SigBytes = "0x";
    }
    
    // Hash the dynamic types as per Solidity contract
    const permit2SignatureHash = ethers.keccak256(permit2SigBytes);
    const permit2WitnessTypeHash = ethers.keccak256(ethers.toUtf8Bytes(order.permit2WitnessType || ""));
    
    const structData = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "uint256", "uint256", "address", "address", "address", "uint256", "uint256", "bool", "bytes32", "bytes32", "bytes32"],
        [
            typeHash,
            order.rfqId,
            order.expiry,
            order.makerAsset,
            order.takerAsset,
            order.makerAddress,
            order.makerAmount,
            order.takerAmount,
            order.usePermit2,
            permit2SignatureHash,
            order.permit2Witness,
            permit2WitnessTypeHash
        ]
    );
    
    return {
        typeHash,
        structData,
        structHash: ethers.keccak256(structData)
    };
}

/**
 * Calculate the final EIP-712 digest
 */
function calculateDigest(domainSeparator, structHash) {
    return ethers.keccak256(ethers.concat([
        "0x1901",
        domainSeparator,
        structHash
    ]));
}

/**
 * Sign the digest with a private key
 */
function signDigest(privateKey, digest) {
    const wallet = new ethers.Wallet(privateKey);
    const sig = wallet.signingKey.sign(digest);
    
    // Reconstruct signature as r + s + v (65 bytes)
    const signature = ethers.concat([sig.r, sig.s, ethers.toBeHex(sig.v, 1)]);
    
    return {
        signature: ethers.hexlify(signature),
        r: sig.r,
        s: sig.s,
        v: sig.v,
        signerAddress: wallet.address
    };
}

/**
 * Recover address from signature
 */
function recoverAddress(digest, signature) {
    try {
        // Extract r, s, v from 65-byte signature
        const r = signature.slice(0, 66);
        const s = "0x" + signature.slice(66, 130);
        const v = parseInt(signature.slice(130, 132), 16);
        
        return ethers.recoverAddress(digest, { r, s, v });
    } catch (e) {
        return "Error: " + e.message;
    }
}

/**
 * Sign Permit2 with witness
 */
function signPermit2WithWitness({ permit, spender, witness, witnessTypeString, privateKey, permit2DomainSeparator }) {
    const wallet = new ethers.Wallet(privateKey);
    
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
    const sig = wallet.signingKey.sign(digest);
    const signature = ethers.concat([sig.r, sig.s, ethers.toBeHex(sig.v, 1)]);

    return {
        signature: ethers.hexlify(signature),
        r: sig.r,
        s: sig.s,
        v: sig.v,
        digest,
        structHash
    };
}

/**
 * Parse signature into r, s, v components
 */
function parseSignature(signature) {
    if (!signature || signature === "0x" || signature.length < 132) {
        return { r: "-", s: "-", v: "-" };
    }
    
    try {
        const r = signature.slice(0, 66);
        const s = "0x" + signature.slice(66, 130);
        const v = parseInt(signature.slice(130, 132), 16);
        return { r, s, v };
    } catch (e) {
        return { r: "Error", s: "Error", v: "Error" };
    }
}

/**
 * Main function to generate all signature data
 */
function generateSignatureData(input) {
    const { chainId, verifyingContract, order, privateKey, permit2DomainSeparator } = input;
    
    // Calculate domain separator
    const { domainTypeHash, domainSeparator } = calculateDomainSeparator(chainId, verifyingContract);
    
    // Calculate struct hash
    const { typeHash, structData, structHash } = calculateStructHash(order);
    
    // Calculate digest
    const digest = calculateDigest(domainSeparator, structHash);
    
    // Sign the digest
    const { signature, r, s, v, signerAddress } = signDigest(privateKey, digest);
    
    // Recover address for verification
    const recoveredAddress = recoverAddress(digest, signature);
    
    // Permit2 data
    let permit2Data = {
        witness: order.permit2Witness,
        witnessType: order.permit2WitnessType,
        signature: order.permit2Signature,
        sigR: "-",
        sigS: "-",
        sigV: "-"
    };
    
    // If usePermit2 and we're in sign mode with valid witnessType
    const permit2Mode = document.querySelector('input[name="permit2Mode"]:checked')?.value || "sign";
    
    if (order.usePermit2 && permit2Mode === "sign" && order.permit2WitnessType && permit2DomainSeparator && permit2DomainSeparator !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
        try {
            const permit2Result = signPermit2WithWitness({
                permit: {
                    permitted: {
                        token: order.makerAsset,
                        amount: order.makerAmount
                    },
                    nonce: order.rfqId,
                    deadline: order.expiry
                },
                spender: verifyingContract,
                witness: order.permit2Witness,
                witnessTypeString: order.permit2WitnessType,
                privateKey: privateKey,
                permit2DomainSeparator: permit2DomainSeparator
            });
            
            permit2Data.signature = permit2Result.signature;
            permit2Data.sigR = permit2Result.r;
            permit2Data.sigS = permit2Result.s;
            permit2Data.sigV = permit2Result.v;
        } catch (e) {
            console.error("Permit2 signing error:", e);
        }
    } else if (permit2Mode === "debug" && order.permit2Signature && order.permit2Signature !== "0x") {
        // Debug mode - parse existing signature
        const parsed = parseSignature(order.permit2Signature);
        permit2Data.sigR = parsed.r;
        permit2Data.sigS = parsed.s;
        permit2Data.sigV = parsed.v;
    }
    
    return {
        // Main outputs in checklist order
        structData,
        structHash,
        domainSeparator,
        digest,
        signature,
        sigR: r,
        sigS: s,
        sigV: v,
        
        // Permit2 outputs
        permit2Witness: permit2Data.witness,
        permit2WitnessType: permit2Data.witnessType,
        permit2Signature: permit2Data.signature,
        permit2SigR: permit2Data.sigR,
        permit2SigS: permit2Data.sigS,
        permit2SigV: permit2Data.sigV,
        
        // Debug info
        typeHash,
        domainTypeHash,
        signerAddress,
        recoveredAddress
    };
}

/**
 * Update the UI with results
 */
function updateUI(results) {
    // Hide error
    document.getElementById("errorDisplay").classList.add("hidden");
    
    // Main outputs
    document.getElementById("structDataOutput").textContent = results.structData;
    document.getElementById("structHashOutput").textContent = results.structHash;
    document.getElementById("domainSeparatorOutput").textContent = results.domainSeparator;
    document.getElementById("digestOutput").textContent = results.digest;
    document.getElementById("signatureOutput").textContent = results.signature;
    
    // Signature breakdown
    document.getElementById("sigR").textContent = results.sigR;
    document.getElementById("sigS").textContent = results.sigS;
    document.getElementById("sigV").textContent = results.sigV;
    
    // Permit2 outputs
    document.getElementById("permit2WitnessOutput").textContent = results.permit2Witness || "-";
    document.getElementById("permit2WitnessTypeOutput").textContent = results.permit2WitnessType || "-";
    document.getElementById("permit2SignatureOutput").textContent = results.permit2Signature || "-";
    document.getElementById("permit2SigR").textContent = results.permit2SigR || "-";
    document.getElementById("permit2SigS").textContent = results.permit2SigS || "-";
    document.getElementById("permit2SigV").textContent = results.permit2SigV || "-";
    
    // Debug info
    document.getElementById("typeHashOutput").textContent = results.typeHash;
    document.getElementById("domainTypeHashOutput").textContent = results.domainTypeHash;
    document.getElementById("signerAddressOutput").textContent = results.signerAddress;
    document.getElementById("recoveredAddressOutput").textContent = results.recoveredAddress;
}

/**
 * Show error message
 */
function showError(message) {
    const errorDisplay = document.getElementById("errorDisplay");
    errorDisplay.textContent = message;
    errorDisplay.classList.remove("hidden");
}

/**
 * Clear all outputs
 */
function clearOutputs() {
    const outputs = [
        "structDataOutput", "structHashOutput", "domainSeparatorOutput",
        "digestOutput", "signatureOutput", "sigR", "sigS", "sigV",
        "permit2WitnessOutput", "permit2WitnessTypeOutput", "permit2SignatureOutput",
        "permit2SigR", "permit2SigS", "permit2SigV",
        "typeHashOutput", "domainTypeHashOutput", "signerAddressOutput", "recoveredAddressOutput"
    ];
    
    outputs.forEach(id => {
        document.getElementById(id).textContent = "-";
    });
    
    document.getElementById("errorDisplay").classList.add("hidden");
}

/**
 * Toggle collapsible section
 */
function toggleCollapsible(header) {
    const content = header.nextElementSibling;
    const chevron = header.querySelector(".chevron");
    
    if (content.style.display === "block") {
        content.style.display = "none";
        chevron.textContent = "▼";
    } else {
        content.style.display = "block";
        chevron.textContent = "▲";
    }
}

/**
 * Copy text to clipboard
 */
async function copyToClipboard(text) {
    try {
        await navigator.clipboard.writeText(text);
        return true;
    } catch (e) {
        console.error("Copy failed:", e);
        return false;
    }
}

// Event listeners
document.addEventListener("DOMContentLoaded", () => {
    // Generate button
    document.getElementById("generateBtn").addEventListener("click", () => {
        try {
            const jsonInput = document.getElementById("jsonInput").value.trim();
            if (!jsonInput) {
                showError("Please enter order JSON");
                return;
            }
            
            const input = JSON.parse(jsonInput);
            
            // Validate required fields
            if (!input.chainId) throw new Error("Missing chainId");
            if (!input.verifyingContract) throw new Error("Missing verifyingContract");
            if (!input.order) throw new Error("Missing order object");
            if (!input.privateKey) throw new Error("Missing privateKey");
            
            const results = generateSignatureData(input);
            updateUI(results);
        } catch (e) {
            showError("Error: " + e.message);
            console.error(e);
        }
    });
    
    // Load example button
    document.getElementById("loadExampleBtn").addEventListener("click", () => {
        document.getElementById("jsonInput").value = JSON.stringify(EXAMPLE_ORDER, null, 2);
    });
    
    // Clear button
    document.getElementById("clearBtn").addEventListener("click", () => {
        document.getElementById("jsonInput").value = "";
        clearOutputs();
    });
    
    // Copy buttons
    document.querySelectorAll(".copy-btn").forEach(btn => {
        btn.addEventListener("click", async () => {
            const targetId = btn.dataset.target;
            const text = document.getElementById(targetId).textContent;
            
            if (text && text !== "-") {
                const success = await copyToClipboard(text);
                const originalText = btn.textContent;
                btn.textContent = success ? "Copied!" : "Failed";
                setTimeout(() => {
                    btn.textContent = originalText;
                }, 1500);
            }
        });
    });
});

// Make toggleCollapsible globally available
window.toggleCollapsible = toggleCollapsible;
