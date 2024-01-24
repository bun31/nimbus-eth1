# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[typetraits],
  json_rpc/rpcserver, stint, web3/conversions,
  eth/p2p,
  ../[transaction, vm_state, constants, vm_types],
  ../db/state_db,
  rpc_types, rpc_utils,
  ../core/tx_pool,
  ../common/common,
  ../utils/utils,
  ../beacon/web3_eth_conv,
  ./filters,
  ../core/executor/process_block,
  ../db/ledger,
  ../../stateless/[witness_verification, witness_types],
  ./p2p

type
  BlockHeader = eth_types.BlockHeader
  ReadOnlyStateDB = state_db.ReadOnlyStateDB

proc getBlockWitness*(
    com: CommonRef,
    blockHeader: BlockHeader,
    statePostExecution: bool): (KeccakHash, BlockWitness, WitnessFlags)
    {.raises: [CatchableError].} =

  let
    chainDB = com.db
    blockHash = chainDB.getBlockHash(blockHeader.blockNumber)
    blockBody = chainDB.getBlockBody(blockHash)
    vmState = BaseVMState.new(blockHeader, com)
    flags = if vmState.fork >= FKSpurious: {wfEIP170} else: {}
  vmState.generateWitness = true # Enable saving witness data

  var dbTx = vmState.com.db.beginTransaction()
  defer: dbTx.dispose()

  # Execute the block of transactions and collect the keys of the touched account state
  let processBlockResult = processBlock(vmState, blockHeader, blockBody)
  doAssert processBlockResult == ValidationResult.OK

  let mkeys = vmState.stateDB.makeMultiKeys()

  if statePostExecution:
    result = (vmState.stateDB.rootHash, vmState.buildWitness(mkeys), flags)
  else:
    # Reset state to what it was before executing the block of transactions
    let initialState = BaseVMState.new(blockHeader, com)
    result = (initialState.stateDB.rootHash, initialState.buildWitness(mkeys), flags)

  dbTx.rollback()


proc getBlockProofs*(
    accDB: ReadOnlyStateDB,
    witnessRoot: KeccakHash,
    witness: BlockWitness,
    flags: WitnessFlags): seq[ProofResponse] {.raises: [RlpError].} =

  if witness.len() == 0:
    return @[]

  let verifyWitnessResult = verifyWitness(witnessRoot, witness, flags)
  doAssert verifyWitnessResult.isOk()

  var blockProofs = newSeqOfCap[ProofResponse](verifyWitnessResult.value().len())

  for address, account in verifyWitnessResult.value():
    var slots = newSeqOfCap[UInt256](account.storage.len())

    for slotKey, _ in account.storage:
      slots.add(slotKey)

    blockProofs.add(getProof(accDB, address, slots))

  return blockProofs

proc setupExpRpc*(com: CommonRef, server: RpcServer) =

  let chainDB = com.db

  proc getStateDB(header: BlockHeader): ReadOnlyStateDB =
    ## Retrieves the account db from canonical head
    # we don't use accounst_cache here because it's only read operations
    let ac = newAccountStateDB(chainDB, header.stateRoot, com.pruneTrie)
    result = ReadOnlyStateDB(ac)

  server.rpc("exp_getWitnessByBlockNumber") do(quantityTag: BlockTag, statePostExecution: bool) -> seq[byte]:
    ## Returns the block witness for a block by block number or tag.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## statePostExecution: bool which indicates whether to return the witness based on the state before or after executing the block.
    ## Returns seq[byte]

    let
      blockHeader = chainDB.headerFromTag(quantityTag)
      (_, witness, _) = getBlockWitness(com, blockHeader, statePostExecution)

    return witness

  server.rpc("exp_getProofsByBlockNumber") do(quantityTag: BlockTag, statePostExecution: bool) -> seq[ProofResponse]:
    ## Returns the block proofs for a block by block number or tag.
    ##
    ## quantityTag: integer of a block number, or the string "earliest", "latest" or "pending", as in the default block parameter.
    ## statePostExecution: bool which indicates whether to return the proofs based on the state before or after executing the block.
    ## Returns seq[ProofResponse]

    let
      blockHeader = chainDB.headerFromTag(quantityTag)
      (witnessRoot, witness, flags) = getBlockWitness(com, blockHeader, statePostExecution)

    let accDB = if statePostExecution:
      getStateDB(blockHeader)
    else:
      getStateDB(chainDB.getBlockHeader(blockHeader.parentHash))

    return getBlockProofs(accDB, witnessRoot, witness, flags)