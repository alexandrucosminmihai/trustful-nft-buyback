"use strict"

const fs = require("fs")

// Web server framework.
const express = require("express")

// Merkle tree based whitelist utilities.
const {MerkleTree} = require("merkletreejs")
const keccak256 = require("keccak256")


const WHITELIST_PATH = "private/whitelist.json"

// Load the whitelist from disk and create the associated Merkle tree.
const whitelist = JSON.parse(fs.readFileSync(WHITELIST_PATH))
const whitelistHashes = whitelist.map(address => keccak256(address))
const merkleTree = new MerkleTree(whitelistHashes, keccak256, {sortPairs: true})
const merkleTreeRoot = merkleTree.getRoot().toString("hex")
console.log(`whitelist=\n${whitelist}`)
console.log(`merkle tree=\n${merkleTree.toString()}`)



// Web server.
const port = 3000
const app = express()

app.get("/", (req, res) => {
  res.send("Use /proof/&ltwallet_address&gt")
})

app.get("/proof/:walletAddress", (req, res) => {
  const walletAddress = req.params.walletAddress
  const walletAddressHash = keccak256(walletAddress)
  const merkleProof = merkleTree.getHexProof(walletAddressHash)

  if (merkleProof.length == 0) {
    res.status(400).json(
      {
        errorMessage: "Bad address or address not found on the whitelist."
      }
    )
    return
  }
  
  res.json(
    {
      proof: merkleProof
    }
  )
})

app.listen(port, () => {
  console.log(`API server listening on port ${port}`)
})
