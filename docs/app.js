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

// Deployed contract addresses from DEPLOYMENT.md
const DEPLOYED_CONTRACTS = {
    1: "0x0bdf246b4aef9cfe4dd6eef153a1b645ac4bcbb6",      // Ethereum Mainnet
    42161: "0x1ef032a3c471a99cc31578c8007f256d95e89896",  // Arbitrum One
    8453: "0xed97b4331fff9dc8c40936532a04ac1400f273a5",   // Base
    56: "0x9ff547bbb813a0e5d53742c7a5f7370dcea214a3"      // BNB Chain
};

const CHAIN_NAMES = {
    1: "Ethereum Mainnet",
    42161: "Arbitrum One",
    8453: "Base",
    56: "BNB Chain"
};

// Permit2 domain separators (Permit2 address: 0x000000000022D473030F116dDEE9F6B43aC78BA3)
const PERMIT2_DOMAIN_SEPARATORS = {
    1: "0x866a5aba21966af95d6c7ab78eb2b2fc913915c28be3b9aa07cc04ff903e3f28",      // Ethereum Mainnet
    42161: "0x8a6e6e19bdfb3db3409910416b47c2f8fc28b49488d6555c7fceaa4479135bc3",  // Arbitrum One
    8453: "0x3b6f35e4fce979ef8eac3bcdc8c3fc38fe7911bb0c69c8fe72bf1fd1a17e6f07",   // Base
    56: "0x4142cc3c823f819c467fa4437d637fe20589a31dfcd1da2ff22292c9ed9344e7"      // BNB Chain
};

// Witness type strings (for reference)
const EXAMPLE_WITNESS_TYPE_STRING = "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)";
const CONSIDERATION_TYPE_STRING = "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)";

/**
 * Generate permit2WitnessType string from witness struct definition
 * 
 * EIP-712 Standard requires:
 * 1. Main struct field declaration: "{StructName} witness)"
 * 2. All struct definitions in ALPHABETICAL order
 * 
 * Format: "{StructName} witness){StructDef1}{StructDef2}..." (alphabetically sorted)
 * 
 * For Permit2, we always need TokenPermissions(address token,uint256 amount)
 */
function generatePermit2WitnessType(witnessStruct) {
    const { name, fields } = witnessStruct;
    
    // Build witness struct definition: "StructName(type1 name1,type2 name2,...)"
    const fieldList = fields.map(f => `${f.type} ${f.name}`).join(",");
    const witnessStructDef = `${name}(${fieldList})`;
    
    // TokenPermissions is always required for Permit2
    const tokenPermissionsDef = "TokenPermissions(address token,uint256 amount)";
    
    // Collect all struct definitions (witness struct + TokenPermissions)
    const structDefs = [witnessStructDef, tokenPermissionsDef];
    
    // Sort alphabetically per EIP-712 standard
    structDefs.sort();
    
    // Format: "{Name} witness){sorted struct definitions}"
    return `${name} witness)${structDefs.join("")}`;
}

/**
 * Calculate witness hash from witness struct definition and values
 */
function calculateWitnessFromStruct(witnessStruct) {
    const { name, fields, values } = witnessStruct;
    
    // Build the struct type string: "{Name}({type1} {name1},{type2} {name2},...)"
    const fieldList = fields.map(f => `${f.type} ${f.name}`).join(",");
    const structTypeString = `${name}(${fieldList})`;
    
    // Calculate typehash
    const typeHash = ethers.keccak256(ethers.toUtf8Bytes(structTypeString));
    
    // Build encoding types and values
    const encodeTypes = ["bytes32"];
    const encodeValues = [typeHash];
    
    for (const field of fields) {
        encodeTypes.push(field.type);
        encodeValues.push(values[field.name]);
    }
    
    // Encode and hash
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(encodeTypes, encodeValues);
    return ethers.keccak256(encoded);
}

// Get current timestamp + 30 days for expiry
function getDefaultExpiry() {
    return Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60;
}

// Generate random rfqId
function generateRfqId() {
    return Math.floor(Math.random() * 10000000000000).toString();
}

// Example private key (Foundry default account #0)
const EXAMPLE_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

// Get makerAddress from private key
function getMakerAddress(privateKey) {
    try {
        const wallet = new ethers.Wallet(privateKey);
        return wallet.address;
    } catch (e) {
        return "0x0000000000000000000000000000000000000000";
    }
}

// Example orders matching testSignOrder.js
function getExampleOrders() {
    const expiry = getDefaultExpiry();
    const rfqId = generateRfqId();
    const makerAddress = getMakerAddress(EXAMPLE_PRIVATE_KEY);
    
    // Arbitrum assets
    const MAKER_ASSET = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";  // USDC on Arbitrum
    const TAKER_ASSET = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";  // USDT on Arbitrum
    const MAKER_AMOUNT = "100";
    const TAKER_AMOUNT = "90";
    
    return {
        // Order 1: usePermit2: false
        order1: {
            chainId: 42161,
            verifyingContract: DEPLOYED_CONTRACTS[42161],
            order: {
                rfqId: rfqId,
                expiry: expiry,
                makerAsset: MAKER_ASSET,
                takerAsset: TAKER_ASSET,
                makerAddress: makerAddress,
                makerAmount: MAKER_AMOUNT,
                takerAmount: TAKER_AMOUNT,
                usePermit2: false,
                permit2Signature: "0x",
                permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
                permit2WitnessType: ""
            },
            privateKey: EXAMPLE_PRIVATE_KEY,
            permit2DomainSeparator: PERMIT2_DOMAIN_SEPARATORS[42161]
        },
        
        // Order 2: usePermit2: true, no witness
        order2: {
            chainId: 42161,
            verifyingContract: DEPLOYED_CONTRACTS[42161],
            order: {
                rfqId: rfqId,
                expiry: expiry,
                makerAsset: MAKER_ASSET,
                takerAsset: TAKER_ASSET,
                makerAddress: makerAddress,
                makerAmount: MAKER_AMOUNT,
                takerAmount: TAKER_AMOUNT,
                usePermit2: true,
                permit2Signature: "0x",
                permit2Witness: "0x0000000000000000000000000000000000000000000000000000000000000000",
                permit2WitnessType: ""
            },
            privateKey: EXAMPLE_PRIVATE_KEY,
            permit2DomainSeparator: PERMIT2_DOMAIN_SEPARATORS[42161]
        },
        
        // Order 3: usePermit2: true, with ExampleWitness
        // Generated permit2WitnessType (EIP-712 alphabetical order: E < T):
        // "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)"
        order3: {
            chainId: 42161,
            verifyingContract: DEPLOYED_CONTRACTS[42161],
            order: {
                rfqId: rfqId,
                expiry: expiry,
                makerAsset: MAKER_ASSET,
                takerAsset: TAKER_ASSET,
                makerAddress: makerAddress,
                makerAmount: MAKER_AMOUNT,
                takerAmount: TAKER_AMOUNT,
                usePermit2: true,
                permit2Signature: "TO_BE_SIGNED",
                permit2Witness: "TO_BE_CALCULATED",
                permit2WitnessType: "TO_BE_GENERATED"
            },
            privateKey: EXAMPLE_PRIVATE_KEY,
            permit2DomainSeparator: PERMIT2_DOMAIN_SEPARATORS[42161],
            witnessStruct: {
                name: "ExampleWitness",
                fields: [
                    { type: "address", name: "user" }
                ],
                values: {
                    user: makerAddress
                }
            },
            _expectedWitnessType: "ExampleWitness witness)ExampleWitness(address user)TokenPermissions(address token,uint256 amount)"
        },
        
        // Order 4: usePermit2: true, with Consideration witness
        // Generated permit2WitnessType (EIP-712 alphabetical order: C < T):
        // "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)"
        order4: {
            chainId: 42161,
            verifyingContract: DEPLOYED_CONTRACTS[42161],
            order: {
                rfqId: rfqId,
                expiry: expiry,
                makerAsset: MAKER_ASSET,
                takerAsset: TAKER_ASSET,
                makerAddress: makerAddress,
                makerAmount: MAKER_AMOUNT,
                takerAmount: TAKER_AMOUNT,
                usePermit2: true,
                permit2Signature: "TO_BE_SIGNED",
                permit2Witness: "TO_BE_CALCULATED",
                permit2WitnessType: "TO_BE_GENERATED"
            },
            privateKey: EXAMPLE_PRIVATE_KEY,
            permit2DomainSeparator: PERMIT2_DOMAIN_SEPARATORS[42161],
            witnessStruct: {
                name: "Consideration",
                fields: [
                    { type: "address", name: "token" },
                    { type: "uint256", name: "amount" },
                    { type: "address", name: "counterparty" }
                ],
                values: {
                    token: MAKER_ASSET,
                    amount: MAKER_AMOUNT,
                    counterparty: "0x1111111111111111111111111111111111111111"
                }
            },
            _expectedWitnessType: "Consideration witness)Consideration(address token,uint256 amount,address counterparty)TokenPermissions(address token,uint256 amount)"
        }
    };
}

/**
 * Calculate ExampleWitness hash
 */
function calculateExampleWitness(user) {
    const EXAMPLE_WITNESS_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes("ExampleWitness(address user)"));
    const encodedWitness = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address"],
        [EXAMPLE_WITNESS_TYPEHASH, user]
    );
    return ethers.keccak256(encodedWitness);
}

/**
 * Calculate Consideration witness hash
 */
function calculateConsiderationWitness(consideration) {
    const CONSIDERATION_TYPEHASH = ethers.keccak256(ethers.toUtf8Bytes("Consideration(address token,uint256 amount,address counterparty)"));
    const encodedWitness = ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "address", "uint256", "address"],
        [CONSIDERATION_TYPEHASH, consideration.token, consideration.amount, consideration.counterparty]
    );
    return ethers.keccak256(encodedWitness);
}

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
    if (!permit2SigBytes || permit2SigBytes === "0x" || permit2SigBytes === "" || permit2SigBytes === "TO_BE_SIGNED") {
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
 * Process input and auto-fill makerAddress if needed
 */
function processInput(input) {
    const processed = JSON.parse(JSON.stringify(input));
    
    // Auto-derive makerAddress from privateKey
    if (processed.privateKey) {
        const derivedAddress = getMakerAddress(processed.privateKey);
        if (!processed.order.makerAddress || 
            processed.order.makerAddress === "0x0000000000000000000000000000000000000000" ||
            processed.order.makerAddress === "") {
            processed.order.makerAddress = derivedAddress;
        }
    }
    
    // Auto-fill verifyingContract based on chainId
    if (!processed.verifyingContract && processed.chainId && DEPLOYED_CONTRACTS[processed.chainId]) {
        processed.verifyingContract = DEPLOYED_CONTRACTS[processed.chainId];
    }
    
    // Handle witness calculation from witnessStruct
    if (processed.witnessStruct) {
        // Generate permit2WitnessType from struct definition
        if (processed.order.permit2WitnessType === "TO_BE_GENERATED" || !processed.order.permit2WitnessType) {
            processed.order.permit2WitnessType = generatePermit2WitnessType(processed.witnessStruct);
        }
        
        // Calculate permit2Witness from struct
        if (processed.order.permit2Witness === "TO_BE_CALCULATED" || !processed.order.permit2Witness || 
            processed.order.permit2Witness === "0x0000000000000000000000000000000000000000000000000000000000000000") {
            processed.order.permit2Witness = calculateWitnessFromStruct(processed.witnessStruct);
        }
    }
    
    // Legacy support: handle old exampleWitness/consideration format
    if (processed.order.permit2Witness === "TO_BE_CALCULATED") {
        if (processed.exampleWitness) {
            processed.order.permit2Witness = calculateExampleWitness(processed.exampleWitness.user);
            if (!processed.order.permit2WitnessType || processed.order.permit2WitnessType === "TO_BE_GENERATED") {
                processed.order.permit2WitnessType = EXAMPLE_WITNESS_TYPE_STRING;
            }
        } else if (processed.consideration) {
            processed.order.permit2Witness = calculateConsiderationWitness(processed.consideration);
            if (!processed.order.permit2WitnessType || processed.order.permit2WitnessType === "TO_BE_GENERATED") {
                processed.order.permit2WitnessType = CONSIDERATION_TYPE_STRING;
            }
        }
    }
    
    return processed;
}

/**
 * Main function to generate all signature data
 */
function generateSignatureData(rawInput) {
    // Process input (auto-fill makerAddress, verifyingContract, witness)
    const input = processInput(rawInput);
    
    const { chainId, verifyingContract, order, privateKey, permit2DomainSeparator, consideration } = input;
    
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
    
    // Build the full order with auto-filled values
    const fullOrder = {
        rfqId: order.rfqId,
        expiry: order.expiry,
        makerAsset: order.makerAsset,
        takerAsset: order.takerAsset,
        makerAddress: order.makerAddress,
        makerAmount: order.makerAmount,
        takerAmount: order.takerAmount,
        usePermit2: order.usePermit2,
        permit2Signature: order.permit2Signature,
        permit2Witness: order.permit2Witness,
        permit2WitnessType: order.permit2WitnessType
    };
    
    // Permit2 data
    let permit2Data = {
        witness: order.permit2Witness,
        witnessType: order.permit2WitnessType,
        signature: order.permit2Signature,
        sigR: "-",
        sigS: "-",
        sigV: "-"
    };
    
    // Sign Permit2 if usePermit2 with valid witnessType
    if (order.usePermit2 && order.permit2WitnessType && permit2DomainSeparator && 
        permit2DomainSeparator !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
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
            
            // Update fullOrder with signed permit2Signature
            fullOrder.permit2Signature = permit2Result.signature;
        } catch (e) {
            console.error("Permit2 signing error:", e);
        }
    }
    
    return {
        // Full order (first in output)
        fullOrder,
        fullOrderJson: JSON.stringify(fullOrder, null, 2),
        
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
        recoveredAddress,
        chainName: CHAIN_NAMES[chainId] || `Chain ${chainId}`,
        verifyingContract
    };
}

/**
 * Update the UI with results
 */
function updateUI(results) {
    // Hide error
    document.getElementById("errorDisplay").classList.add("hidden");
    
    // Full order output
    document.getElementById("fullOrderOutput").textContent = results.fullOrderJson;
    
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
    document.getElementById("chainNameOutput").textContent = results.chainName;
    document.getElementById("contractAddressOutput").textContent = results.verifyingContract;
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
        "fullOrderOutput",
        "structDataOutput", "structHashOutput", "domainSeparatorOutput",
        "digestOutput", "signatureOutput", "sigR", "sigS", "sigV",
        "permit2WitnessOutput", "permit2WitnessTypeOutput", "permit2SignatureOutput",
        "permit2SigR", "permit2SigS", "permit2SigV",
        "typeHashOutput", "domainTypeHashOutput", "signerAddressOutput", "recoveredAddressOutput",
        "chainNameOutput", "contractAddressOutput"
    ];
    
    outputs.forEach(id => {
        const el = document.getElementById(id);
        if (el) el.textContent = "-";
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
    const examples = getExampleOrders();
    
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
            if (!input.order) throw new Error("Missing order object");
            if (!input.privateKey) throw new Error("Missing privateKey");
            
            const results = generateSignatureData(input);
            updateUI(results);
        } catch (e) {
            showError("Error: " + e.message);
            console.error(e);
        }
    });
    
    // Helper to clean example for display (remove internal fields like _expectedWitnessType)
    function cleanExampleForDisplay(example) {
        const clean = JSON.parse(JSON.stringify(example));
        delete clean._expectedWitnessType;
        return clean;
    }
    
    // Example buttons
    document.getElementById("loadExample1Btn").addEventListener("click", () => {
        document.getElementById("jsonInput").value = JSON.stringify(cleanExampleForDisplay(examples.order1), null, 2);
    });
    
    document.getElementById("loadExample2Btn").addEventListener("click", () => {
        document.getElementById("jsonInput").value = JSON.stringify(cleanExampleForDisplay(examples.order2), null, 2);
    });
    
    document.getElementById("loadExample3Btn").addEventListener("click", () => {
        document.getElementById("jsonInput").value = JSON.stringify(cleanExampleForDisplay(examples.order3), null, 2);
    });
    
    document.getElementById("loadExample4Btn").addEventListener("click", () => {
        document.getElementById("jsonInput").value = JSON.stringify(cleanExampleForDisplay(examples.order4), null, 2);
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

// Export for testing
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        calculateDomainSeparator,
        calculateStructHash,
        calculateDigest,
        signDigest,
        generateSignatureData,
        getExampleOrders,
        DEPLOYED_CONTRACTS,
        CHAIN_NAMES
    };
}
