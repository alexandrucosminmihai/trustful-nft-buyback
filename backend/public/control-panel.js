function castToType(valueStr, typeStr) {
    if (typeStr.includes("int")) {
        return parseInt(valueStr);
    } else if (typeStr == "bool") {
        valueStr = valueStr.toLowerCase();
        if (valueStr == "false") {
            return false;
        }
        return true;
    }

    valueStr = valueStr.replace(/\"/g, '');

    return valueStr;
}

function populateTableWithObject(table, obj) {
    // Delete the old rows.
    const numTableRows = table.rows.length;
    for (let iRow = numTableRows - 1; iRow >= 1; --iRow) {
        table.deleteRow(iRow);
    }

    // Add the new rows.
    for (const [infoName, infoValue] of Object.entries(obj)) {
        const infoRow = table.insertRow(-1);
        
        const nameColumn = infoRow.insertCell(-1);
        nameColumn.textContent = infoName;
        const valueColumn = infoRow.insertCell(-1);
        valueColumn.textContent = infoValue;
    }
}

function createFormFromABIFunction(ABIEntry, contract, account) {
    if (ABIEntry["type"] != "function") {
        throw "ABI entry is not a function.";
    }

    const functionId = `function-${ABIEntry["name"]}`;

    const form = document.createElement("form");
    form.setAttribute("id", `form-${functionId}`);
    
    const rowInputsParentDiv = document.createElement("div");
    rowInputsParentDiv.setAttribute("class", "row-inputs-parent-div");
    rowInputsParentDiv.setAttribute("id", `row-inputs-parent-div-${functionId}`);
    form.appendChild(rowInputsParentDiv);

    // Create the button, but set the onclick function later.
    const functionButtonDiv = document.createElement("div");
    functionButtonDiv.setAttribute("class", "row-input-div");
    functionButtonDiv.setAttribute("id", `row-input-div-${functionId}-button`);
    rowInputsParentDiv.appendChild(functionButtonDiv);
    
    const functionButton = document.createElement("input");
    functionButton.setAttribute("type", "button");
    functionButton.setAttribute("id", `${functionId}-button`);
    functionButton.setAttribute("value", ABIEntry["name"]);
    functionButtonDiv.appendChild(functionButton);

    // Create the fields for the contract function arguments.
    const inputFields = [];
    const functionInputs = [...ABIEntry["inputs"]];
    // Add the value field if the function is payable.
    if (ABIEntry["stateMutability"] == "payable") {
        const valueInput = {
            "name": "value",
            "type": "wei"
        }
        functionInputs.unshift(valueInput);
    }
    for (let iInput = 0; iInput < functionInputs.length; ++iInput) {
        const functionInput = functionInputs[iInput];
        const inputId = `${functionId}-input${iInput}`;
        
        const inputDiv = document.createElement("div");
        inputDiv.setAttribute("class", "row-input-div");
        inputDiv.setAttribute("id", `row-input-div-${inputId}`);
        rowInputsParentDiv.appendChild(inputDiv);

        const input = document.createElement("input");
        input.setAttribute("type", "text");
        input.setAttribute("id", inputId);
        input.setAttribute("placeholder", `${functionInput["name"]}(${functionInput["type"]})`);
        inputFields.push(input);
        inputDiv.appendChild(input);
    }

    // Create an output textarea.
    const resultTextareaDiv = document.createElement("div");
    resultTextareaDiv.setAttribute("class", "row-input-div");
    resultTextareaDiv.setAttribute("id", `row-input-div-${functionId}-result`);
    rowInputsParentDiv.appendChild(resultTextareaDiv);

    const resultTextarea = document.createElement("textarea");
    resultTextarea.setAttribute("id", `${functionId}-result`);
    resultTextarea.setAttribute("rows", "1");
    resultTextarea.setAttribute("cols", "50");
    resultTextarea.textContent = "(result will be displayed here)";
    resultTextareaDiv.appendChild(resultTextarea);

    // The onclick function.
    functionButton.onclick = async () => {
        let contractFunctionObj = contract.methods[ABIEntry["name"]];
        const functionArgs = [];
        let value = null;

        for (let iInput = 0; iInput < inputFields.length; ++iInput) {
            let inputFieldValue = inputFields[iInput].value;
            const inputMetadata = functionInputs[iInput];

            if (inputMetadata["type"] == "wei") {
                value = parseInt(inputFieldValue);
                continue;
            }

            inputFieldValue = inputFieldValue.replace(/\s+/g, '');

            let inputValue = null;
            if (inputMetadata["type"].endsWith("[]")) {
                inputFieldValue = inputFieldValue.replace(/[\[\]]/g, '');

                inputValues = inputFieldValue.split(",");
                inputValue = []
                for (let iInputValue = 0; iInputValue < inputValues.length; ++iInputValue) {
                    inputValue.push(castToType(inputValues[iInputValue], inputMetadata["type"].substring(0, inputMetadata["type"].length - 2)));
                }
            } else {
                inputValue = castToType(inputFieldValue, inputMetadata["type"]);
            }

            functionArgs.push(inputValue);
        }
        
        contractFunctionObj = contractFunctionObj(...functionArgs);

        let result;
        try {
            if (ABIEntry["stateMutability"] == "payable") {
                result = await contractFunctionObj.send({
                    from: account,
                    value: value.toString()
                });
            } else if (ABIEntry["stateMutability"] == "pure" || ABIEntry["stateMutability"] == "view") {
                result = await contractFunctionObj.call({
                    from: account
                });
            } else {
                result = await contractFunctionObj.send({
                    from: account
                });
            }
            result = JSON.stringify(result);
        } catch (error) {
            result = `Error: ${error.message}`;
        }

        resultTextarea.value = result;
    }

    return form;
}

(
    async () => {
        const CHAIN_ID = "0x4"  // "0x1" = mainnet "0x4" = Rinkeby
        const CONTRACT_ADDRESS = "0x4D2Bec7cbCfACf30DB0aD4a2C51aeA196F42B241";
        const ABI_JSON_PATH = "/BuybackNFT_ABI.json";

        const ABI_JSON_RESPONSE = await fetch(ABI_JSON_PATH);
        const ABI = await ABI_JSON_RESPONSE.json();
        
        const connectFunction = async () => {
            if (window.ethereum) {
                // Make sure the user's wallet is on the correct chain.
                try {
                    await window.ethereum.request(
                        {
                            method: 'wallet_switchEthereumChain',
                            params: [
                                {
                                    chainId: CHAIN_ID
                                }
                            ]
                        }
                    )
                } catch (error) {
                    alert("Your wallet must be on the Ethereum blockchain in order to mint.");
                    window.location.reload();
                }

                await window.ethereum.send('eth_requestAccounts');
                window.web3 = new Web3(window.ethereum);
                contract = new web3.eth.Contract(ABI, CONTRACT_ADDRESS);
                const accounts = await web3.eth.getAccounts();
                account = accounts[0];

                const logs = document.getElementById("logs");

                // ==================== Get general information from the blockchain ====================
                logs.textContent = "Loading data from blockchain..."
                const generalInfo = {};
                generalInfo["totalSupply"] = parseInt(await contract.methods.getTotalSupply().call({from: account}));
                generalInfo["idLastMinted"] = parseInt(await contract.methods.getIdLastMinted().call({from: account}));
                generalInfo["numBuybackable"] = parseInt(await contract.methods.getNumBuybackable().call({from: account}));
                generalInfo["numResellable"] = parseInt(await contract.methods.getNumResellableIds().call({from: account}));
                
                generalInfo["mintingAllowed"] = await contract.methods.isMintingAllowed().call({from: account});
                generalInfo["walletMintLimit"] = parseInt(await contract.methods.getWalletMintLimit().call({from: account}));
                generalInfo["mintPrice"] = parseInt(await contract.methods.getMintPriceWei().call({from: account}));

                generalInfo["whitelistMintingAllowed"] = await contract.methods.isWhitelistMintingAllowed().call({from: account});
                generalInfo["whitelistWalletMintLimit"] = parseInt(await contract.methods.getWalletWhitelistMintLimit().call({from: account}));

                generalInfo["resellingAllowed"] = await contract.methods.isResellingAllowed().call({from: account});
                generalInfo["resellPrice"] = parseInt(await contract.methods.getResellPriceWei().call({from: account}));

                generalInfo["buybackPrice"] = parseInt(await contract.methods.getBuybackPriceWei().call({from: account}));

                
                // ==================== Display the general information ====================
                document.getElementById('contract-address').textContent = CONTRACT_ADDRESS;
                document.getElementById('connected-wallet-address').textContent = account;

                tableGeneralInfo = document.getElementById('table-general-info');
                populateTableWithObject(tableGeneralInfo, generalInfo);
                logs.textContent = "Ok (displayed general info)";


                // ==================== User information ====================
                const userInfoButton = document.getElementById('user-info-button');
                userInfoButton.onclick = async () => {
                    const userInfoAddressInput = document.getElementById('user-info-address');
                    const userInfoAddress = userInfoAddressInput.value;

                    try {
                        // Get the information about the user.
                        const userInfo = {};
                        userInfo["address"] = userInfoAddress;
                        userInfo["numMinted"] = parseInt(await contract.methods.getNumMintedByAddress(userInfoAddress).call({from: account}));
                        userInfo["numOwned"] = parseInt(await contract.methods.balanceOf(userInfoAddress).call({from: account}));
                        const merkleProofResponse = await fetch(`/proof/${userInfoAddress}`);
                        const merkleProofObj = await merkleProofResponse.json();
                        if ("errorMessage" in merkleProofObj) {
                            userInfo["isWhitelisted"] = false;
                        } else {
                            const merkleProof = merkleProofObj["proof"];
                            userInfo["isWhitelisted"] = await contract.methods.isWhitelisted(userInfoAddress, merkleProof).call({from: account});
                        }

                        // Display the information about the user.
                        tableUserInfo = document.getElementById('table-user-info');
                        populateTableWithObject(tableUserInfo, userInfo);
                        logs.textContent = "Ok (displayed user info)";
                    } catch (error) {
                        logs.textContent = error.message;
                    }
                }

                // ==================== All the contract functions ====================
                const allFunctionsDiv = document.getElementById('all-functions-div');
                for (let iABIEntry = 0; iABIEntry < ABI.length; ++iABIEntry) {
                    const ABIEntry = ABI[iABIEntry];
                    if (ABIEntry["type"] != "function") {
                        continue;
                    }

                    const functionForm = createFormFromABIFunction(ABIEntry, contract, account);
                    allFunctionsDiv.appendChild(functionForm);
                }
            } else {
                alert('Please install MetaMask and switch to the Ethereum network.')
            }
        }
        await connectFunction();
    }
)();