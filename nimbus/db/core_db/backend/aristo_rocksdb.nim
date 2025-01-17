# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  results,
  ../../aristo,
  ../../aristo/aristo_persistent as use_ari,
  ../../aristo/[aristo_desc, aristo_walk/persistent, aristo_tx],
  ../../kvt,
  ../../kvt/kvt_persistent as use_kvt,
  ../base,
  ./aristo_db,
  ./aristo_db/[common_desc, handlers_aristo],
  ../../opts

include
  ./aristo_db/aristo_replicate

const
  # Expectation messages
  aristoFail = "Aristo/RocksDB init() failed"
  kvtFail = "Kvt/RocksDB init() failed"

# Annotation helper(s)
{.pragma: rlpRaise, gcsafe, raises: [AristoApiRlpError].}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newAristoRocksDbCoreDbRef*(path: string, opts: DbOptions): CoreDbRef =
  let
    adb = AristoDbRef.init(use_ari.RdbBackendRef, path, opts).expect aristoFail
    gdb = adb.guestDb().valueOr: GuestDbRef(nil)
    kdb = KvtDbRef.init(use_kvt.RdbBackendRef, path, gdb).expect kvtFail
  AristoDbRocks.create(kdb, adb)

# ------------------------------------------------------------------------------
# Public aristo iterators
# ------------------------------------------------------------------------------

iterator aristoReplicateRdb*(dsc: CoreDxMptRef): (Blob,Blob) {.rlpRaise.} =
  ## Instantiation for `VoidBackendRef`
  for k,v in aristoReplicate[use_ari.RdbBackendRef](dsc):
    yield (k,v)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
