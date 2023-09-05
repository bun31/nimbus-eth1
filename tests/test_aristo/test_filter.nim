# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records distributed backend access test.
##

import
  std/[sequtils, sets, strutils],
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_debug, aristo_desc, aristo_filter, aristo_get,
    aristo_merge, aristo_persistent, aristo_transcode],
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/aristo_desc/desc_backend,
  ../../nimbus/db/aristo/aristo_filter/[
    filter_desc, filter_fifos, filter_helpers, filter_scheduler],
  ./test_helpers

type
  LeafQuartet =
    array[0..3, seq[LeafTiePayload]]

  DbTriplet =
    array[0..2, AristoDbRef]

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

proc fifosImpl[T](be: T): seq[seq[(QueueID,FilterRef)]] =
  var lastChn = -1
  for (qid,val) in be.walkFifoBE:
    let chn = (qid.uint64 shr 62).int
    while lastChn < chn:
      lastChn.inc
      result.add newSeq[(QueueID,FilterRef)](0)
    result[^1].add (qid,val)

proc fifos(be: BackendRef): seq[seq[(QueueID,FilterRef)]] =
  ## Wrapper
  case be.kind:
  of BackendMemory:
    return be.MemBackendRef.fifosImpl
  of BackendRocksDB:
    return be.RdbBackendRef.fifosImpl
  else:
    discard
  check be.kind == BackendMemory or be.kind == BackendRocksDB

func flatten(a: seq[seq[(QueueID,FilterRef)]]): seq[(QueueID,FilterRef)] =
  for w in a:
    result &= w

proc fList(be: BackendRef): seq[(QueueID,FilterRef)] =
  case be.kind:
  of BackendMemory:
    return be.MemBackendRef.walkFilBe.toSeq.mapIt((it.qid, it.filter))
  of BackendRocksDB:
    return be.RdbBackendRef.walkFilBe.toSeq.mapIt((it.qid, it.filter))
  else:
    discard
  check be.kind == BackendMemory or be.kind == BackendRocksDB

func ppFil(w: FilterRef): string =
  func pp(w: HashKey): string =
    let n = w.to(HashID).UInt256
    if n == 0: "£ø" else: "£" & $n
  "(" & w.fid.pp & "," & w.src.pp & "->" & w.trg.pp & ")"

func pp(qf: (QueueID,FilterRef)): string =
  "(" & qf[0].pp & "," & (if qf[1].isNil: "ø" else: qf[1].ppFil) & ")"

proc pp(q: openArray[(QueueID,FilterRef)]): string =
  "{" & q.mapIt(it.pp).join(",") & "}"

proc pp(q: seq[seq[(QueueID,FilterRef)]]): string =
  result = "["
  for w in q:
    if w.len == 0:
      result &= "ø"
    else:
      result &= w.mapIt(it.pp).join(",")
    result &= ","
  if result[^1] == ',':
    result[^1] = ']'
  else:
    result &= "]"

# -------------------------

proc dump(pfx: string; dx: varargs[AristoDbRef]): string =
  proc dump(db: AristoDbRef): string =
    db.pp & "\n    " & db.backend.pp(db) & "\n"
  if 0 < dx.len:
    result = "\n   "
  var
    pfx = pfx
    qfx = ""
  if pfx.len == 0:
    (pfx,qfx) = ("[","]")
  elif 1 < dx.len:
    pfx = pfx & "#"
  for n in 0 ..< dx.len:
    let n1 = n + 1
    result &= pfx
    if 1 < dx.len:
      result &= $n1
    result &= qfx & "\n    " & dx[n].dump
    if n1 < dx.len:
      result &= "   ==========\n   "

proc dump(dx: varargs[AristoDbRef]): string =
  "".dump dx

proc dump(w: DbTriplet): string =
  "db".dump(w[0], w[1], w[2])

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

iterator quadripartite(td: openArray[ProofTrieData]): LeafQuartet =
  ## ...
  var collect: seq[seq[LeafTiePayload]]

  for w in td:
    let lst = w.kvpLst.mapRootVid VertexID(1)

    if lst.len < 8:
      if 2 < collect.len:
        yield [collect[0], collect[1], collect[2], lst]
        collect.setLen(0)
      else:
        collect.add lst
    else:
      if collect.len == 0:
        let a = lst.len div 4
        yield [lst[0 ..< a], lst[a ..< 2*a], lst[2*a ..< 3*a], lst[3*a .. ^1]]
      else:
        if collect.len == 1:
          let a = lst.len div 3
          yield [collect[0], lst[0 ..< a], lst[a ..< 2*a], lst[a .. ^1]]
        elif collect.len == 2:
          let a = lst.len div 2
          yield [collect[0], collect[1], lst[0 ..< a], lst[a .. ^1]]
        else:
          yield [collect[0], collect[1], collect[2], lst]
        collect.setLen(0)

proc dbTriplet(w: LeafQuartet; rdbPath: string): Result[DbTriplet,AristoError] =
  let db = block:
    let rc = newAristoDbRef(BackendRocksDB,rdbPath)
    xCheckRc rc.error == 0
    rc.value

  # Fill backend
  block:
    let report = db.merge w[0]
    if report.error != AristoError(0):
      db.finish(flush=true)
      check report.error == 0
      return err(report.error)
    let rc = db.stow(persistent=true)
    if rc.isErr:
      check rc.error == (0,0)
      return

  let dx = [db, db.copyCat.value, db.copyCat.value]

  # Clause (9) from `aristo/README.md` example
  for n in 0 ..< dx.len:
    let report = dx[n].merge w[n+1]
    if report.error != AristoError(0):
      db.finish(flush=true)
      check (n, report.error) == (n,0)
      return err(report.error)

  return ok dx

# ----------------------

proc cleanUp(dx: DbTriplet) =
  dx[0].finish(flush=true)

proc isDbEq(a, b: FilterRef; db: AristoDbRef; noisy = true): bool =
  ## Verify that argument filter `a` has the same effect on the
  ## physical/unfiltered backend of `db` as argument filter `b`.
  if a.isNil:
    return b.isNil
  if b.isNil:
    return false
  if unsafeAddr(a[]) != unsafeAddr(b[]):
    if a.src != b.src or
       a.trg != b.trg or
       a.vGen != b.vGen:
      return false

    # Void entries may differ unless on physical backend
    var (aTab, bTab) = (a.sTab, b.sTab)
    if aTab.len < bTab.len:
      aTab.swap bTab
    for (vid,aVtx) in aTab.pairs:
      let bVtx = bTab.getOrVoid vid
      bTab.del vid

      if aVtx != bVtx:
        if aVtx.isValid and bVtx.isValid:
          return false
        # The valid one must match the backend data
        let rc = db.getVtxUBE vid
        if rc.isErr:
          return false
        let vtx = if aVtx.isValid: aVtx else: bVtx
        if vtx != rc.value:
          return false

      elif not vid.isValid and not bTab.hasKey vid:
        let rc = db.getVtxUBE vid
        if rc.isOk:
          return false # Exists on backend but missing on `bTab[]`
        elif rc.error != GetKeyNotFound:
          return false # general error

    if 0 < bTab.len:
      noisy.say "***", "not dbEq:", "bTabLen=", bTab.len
      return false

    # Similar for `kMap[]`
    var (aMap, bMap) = (a.kMap, b.kMap)
    if aMap.len < bMap.len:
      aMap.swap bMap
    for (vid,aKey) in aMap.pairs:
      let bKey = bMap.getOrVoid vid
      bMap.del vid

      if aKey != bKey:
        if aKey.isValid and bKey.isValid:
          return false
        # The valid one must match the backend data
        let rc = db.getKeyUBE vid
        if rc.isErr:
          return false
        let key = if aKey.isValid: aKey else: bKey
        if key != rc.value:
          return false

      elif not vid.isValid and not bMap.hasKey vid:
        let rc = db.getKeyUBE vid
        if rc.isOk:
          return false # Exists on backend but missing on `bMap[]`
        elif rc.error != GetKeyNotFound:
          return false # general error

    if 0 < bMap.len:
      noisy.say "***", "not dbEq:", " bMapLen=", bMap.len
      return false

  true

proc isEq(a, b: FilterRef; db: AristoDbRef; noisy = true): bool =
  ## ..
  if a.src != b.src:
    noisy.say "***", "not isEq:", " a.src=", a.src.pp, " b.src=", b.src.pp
    return
  if a.trg != b.trg:
    noisy.say "***", "not isEq:", " a.trg=", a.trg.pp, " b.trg=", b.trg.pp
    return
  if a.vGen != b.vGen:
    noisy.say "***", "not isEq:", " a.vGen=", a.vGen.pp, " b.vGen=", b.vGen.pp
    return
  if a.sTab.len != b.sTab.len:
    noisy.say "***", "not isEq:",
      " a.sTab.len=", a.sTab.len,
      " b.sTab.len=", b.sTab.len
    return
  if a.kMap.len != b.kMap.len:
    noisy.say "***", "not isEq:",
      " a.kMap.len=", a.kMap.len,
      " b.kMap.len=", b.kMap.len
    return
  for (vid,aVtx) in a.sTab.pairs:
    if b.sTab.hasKey vid:
      let bVtx = b.sTab.getOrVoid vid
      if aVtx != bVtx:
        noisy.say "***", "not isEq:",
          " vid=", vid.pp,
          " aVtx=", aVtx.pp(db),
          " bVtx=", bVtx.pp(db)
        return
    else:
      noisy.say "***", "not isEq:",
        " vid=", vid.pp,
        " aVtx=", aVtx.pp(db),
        " bVtx=n/a"
      return
  for (vid,aKey) in a.kMap.pairs:
    if b.kMap.hasKey vid:
      let bKey = b.kMap.getOrVoid vid
      if aKey != bkey:
        noisy.say "***", "not isEq:",
          " vid=", vid.pp,
          " aKey=", aKey.pp,
          " bKey=", bKey.pp
        return
    else:
      noisy.say "*** not eq:",
        " vid=", vid.pp,
        " aKey=", aKey.pp,
        " bKey=n/a"
      return

  true

# ----------------------

proc checkBeOk(
    dx: DbTriplet;
    relax = false;
    forceCache = false;
    noisy = true;
      ): bool =
  ## ..
  for n in 0 ..< dx.len:
    let
      cache = if forceCache: true else: not dx[n].top.dirty
      rc = dx[n].checkBE(relax=relax, cache=cache)
    xCheckRc rc.error == (0,0):
      noisy.say "***", "db check failed", " n=", n, " cache=", cache

  true

proc checkFilterTrancoderOk(
    dx: DbTriplet;
    noisy = true;
      ): bool =
  ## ..
  for n in 0 ..< dx.len:
    if dx[n].roFilter.isValid:
      let data = block:
        let rc = dx[n].roFilter.blobify()
        xCheckRc rc.error == 0:
          noisy.say "***", "db serialisation failed",
            " n=", n, " error=", rc.error
        rc.value

      let dcdRoundTrip = block:
        let rc = data.deblobify FilterRef
        xCheckRc rc.error == 0:
          noisy.say "***", "db de-serialisation failed",
            " n=", n, " error=", rc.error
        rc.value

      let roFilterExRoundTrip = dx[n].roFilter.isEq(dcdRoundTrip, dx[n], noisy)
      xCheck roFilterExRoundTrip:
        noisy.say "***", "checkFilterTrancoderOk failed",
          "\n   roFilter=", dx[n].roFilter.pp(dx[n]),
          "\n   dcdRoundTrip=", dcdRoundTrip.pp(dx[n])

  true

# -------------------------

func to(fid: FilterID; T: type HashKey): T =
  fid.uint64.to(HashID).to(T)


proc storeFilter(
    be: BackendRef;
    filter: FilterRef;
      ): bool =
  ## ..
  let instr = block:
    let rc = be.store filter
    xCheckRc rc.error == 0
    rc.value

  # Update database
  let txFrame = be.putBegFn()
  be.putFilFn(txFrame, instr.put)
  be.putFqsFn(txFrame, instr.scd.state)
  let done = be.putEndFn txFrame
  xCheck done == 0

  be.filters.state = instr.scd.state
  true

proc storeFilter(
    be: BackendRef;
    serial: int;
      ): bool =
  ## Variant of `storeFilter()`
  let fid = FilterID(serial)
  be.storeFilter FilterRef(
    fid: fid,
    src: fid.to(HashKey),
    trg: (fid-1).to(HashKey))


proc fetchDelete(
    be: BackendRef;
    backStep: int;
    filter: var FilterRef;
      ): bool =
  ## ...
  # let filter = block:

  let
    instr = block:
      let rc = be.fetch(backStep = backStep)
      xCheckRc rc.error == 0
      rc.value
    qid = be.le instr.fil.fid
    inx = be.filters[qid]
  xCheck backStep == inx + 1

  # Update database
  let txFrame = be.putBegFn()
  be.putFilFn(txFrame, instr.put)
  be.putFqsFn(txFrame, instr.scd.state)
  let done = be.putEndFn txFrame
  xCheck done == 0

  be.filters.state = instr.scd.state
  filter = instr.fil

  # Verify that state was properly installed
  let rc = be.getFqsFn()
  xCheckRc rc.error == 0
  xCheck rc.value == be.filters.state

  true


proc validateFifo(
   be: BackendRef;
   serial: int;
     ): bool =
  func to(key: HashKey; T: type uint64): T =
    key.to(HashID).UInt256.truncate(uint64)

  var lastTrg = serial.uint64
  ## Verify filter setup
  ##
  ## Example
  ## ::
  ##      QueueID |  FilterID  |         HashKey
  ##        qid   | filter.fid | filter.src -> filter.trg
  ##      --------+------------+--------------------------
  ##        %4    |    @654    |   £654 -> £653
  ##        %3    |    @653    |   £653 -> £652
  ##        %2    |    @652    |   £652 -> £651
  ##        %1    |    @651    |   £651 -> £650
  ##        %a    |    @650    |   £650 -> £649
  ##        %9    |    @649    |   £649 -> £648
  ##              |            |
  ##        %1:2  |    @648    |   £648 -> £644
  ##        %1:1  |    @644    |   £644 -> £640
  ##        %1:a  |    @640    |   £640 -> £636
  ##        %1:9  |    @636    |   £636 -> £632
  ##        %1:8  |    @632    |   £632 -> £628
  ##        %1:7  |    @628    |   £628 -> £624
  ##        %1:6  |    @624    |   £624 -> £620
  ##              |            |
  ##        %2:1  |    @620    |   £620 -> £600
  ##        %2:a  |    @600    |   £600 -> £580
  ##        ..    |    ..      |   ..
  ##
  var
    inx = 0
    lastFid = FilterID(serial+1)
  for chn,fifo in be.fifos:
    for (qid,filter) in fifo:

      # Check filter objects
      xCheck chn == (qid.uint64 shr 62).int
      xCheck filter != FilterRef(nil)
      xCheck filter.src.to(uint64) == lastTrg
      lastTrg = filter.trg.to(uint64)

      # Check random access
      xCheck qid == be.filters[inx]
      xCheck inx == be.filters[qid]

      # Check access by queue ID (all end up at `qid`)
      for fid in filter.fid ..< lastFid:
        xCheck qid == be.le fid

      inx.inc
      lastFid = filter.fid

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testDistributedAccess*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var n = 0
  for w in list.quadripartite:
    n.inc

    # Resulting clause (11) filters from `aristo/README.md` example
    # which will be used in the second part of the tests
    var
      c11Filter1 = FilterRef(nil)
      c11Filter3 = FilterRef(nil)

    # Work through clauses (8)..(11) from `aristo/README.md` example
    block:

      # Clause (8) from `aristo/README.md` example
      let
        dx = block:
          let rc = dbTriplet(w, rdbPath)
          xCheckRc rc.error == 0
          rc.value
        (db1, db2, db3) = (dx[0], dx[1], dx[2])
      defer:
        dx.cleanUp()

      when false: # or true:
        noisy.say "*** testDistributedAccess (1)", "n=", n, dx.dump

      # Clause (9) from `aristo/README.md` example
      block:
        let rc = db1.stow(persistent=true)
        xCheckRc rc.error == (0,0)
      xCheck db1.roFilter == FilterRef(nil)
      xCheck db2.roFilter == db3.roFilter

      block:
        let rc = db2.stow(persistent=false)
        xCheckRc rc.error == (0,0):
          noisy.say "*** testDistributedAccess (3)", "n=", n, "db2".dump db2
      xCheck db1.roFilter == FilterRef(nil)
      xCheck db2.roFilter != db3.roFilter

      # Clause (11) from `aristo/README.md` example
      block:
        let rc = db2.ackqRwMode()
        xCheckRc rc.error == 0
      block:
        let rc = db2.stow(persistent=true)
        xCheckRc rc.error == (0,0)
      xCheck db2.roFilter == FilterRef(nil)

      # Check/verify backends
      block:
        let ok = dx.checkBeOk(noisy=noisy)
        xCheck ok:
          noisy.say "*** testDistributedAccess (4)", "n=", n, "db3".dump db3
      block:
        let ok = dx.checkFilterTrancoderOk(noisy=noisy)
        xCheck ok

      # Capture filters from clause (11)
      c11Filter1 = db1.roFilter
      c11Filter3 = db3.roFilter

      # Clean up
      dx.cleanUp()

    # ----------

    # Work through clauses (12)..(15) from `aristo/README.md` example
    block:
      let
        dy = block:
          let rc = dbTriplet(w, rdbPath)
          xCheckRc rc.error == 0
          rc.value
        (db1, db2, db3) = (dy[0], dy[1], dy[2])
      defer:
        dy.cleanUp()

      # Build clause (12) from `aristo/README.md` example
      block:
        let rc = db2.ackqRwMode()
        xCheckRc rc.error == 0
      block:
        let rc = db2.stow(persistent=true)
        xCheckRc rc.error == (0,0)
      xCheck db2.roFilter == FilterRef(nil)
      xCheck db1.roFilter == db3.roFilter

      # Clause (13) from `aristo/README.md` example
      block:
        let rc = db1.stow(persistent=false)
        xCheckRc rc.error == (0,0)

      # Clause (14) from `aristo/README.md` check
      let c11Fil1_eq_db1RoFilter = c11Filter1.isDbEq(db1.roFilter, db1, noisy)
      xCheck c11Fil1_eq_db1RoFilter:
        noisy.say "*** testDistributedAccess (7)", "n=", n,
          "\n   c11Filter1=", c11Filter3.pp(db1),
          "db1".dump(db1)

      # Clause (15) from `aristo/README.md` check
      let c11Fil3_eq_db3RoFilter = c11Filter3.isDbEq(db3.roFilter, db3, noisy)
      xCheck c11Fil3_eq_db3RoFilter:
        noisy.say "*** testDistributedAccess (8)", "n=", n,
          "\n   c11Filter3=", c11Filter3.pp(db3),
          "db3".dump(db3)

      # Check/verify backends
      block:
        let ok = dy.checkBeOk(noisy=noisy)
        xCheck ok
      block:
        let ok = dy.checkFilterTrancoderOk(noisy=noisy)
        xCheck ok

      when false: # or true:
        noisy.say "*** testDistributedAccess (9)", "n=", n, dy.dump

  true


proc testFilterFifo*(
    noisy = true;
    layout = QidSlotLyo;
    sampleSize = QidSample;
    reorgPercent = 40;
    rdbPath = "";
      ): bool =
  var
    debug = false # or true
  let
    db = if 0 < rdbPath.len:
      let rc = newAristoDbRef(BackendRocksDB,rdbPath,layout.to(QidLayoutRef))
      xCheckRc rc.error == 0
      rc.value
    else:
      BackendMemory.newAristoDbRef(layout.to(QidLayoutRef))
    be = db.backend

  defer: db.finish(flush=true)

  proc show(serial = 0; exec: seq[QidAction] = @[]) =
    var s = ""
    if 0 < serial:
      s &= " n=" & $serial
    s &= " len=" & $be.filters.len
    if 0 < exec.len:
      s &= " exec=" & exec.pp
    s &= "" &
      "\n   state=" & be.filters.state.pp &
      #"\n    list=" & be.fList.pp &
      "\n    fifo=" & be.fifos.pp &
      "\n"
    noisy.say "***", s

  if debug:
    noisy.say "***", "sampleSize=", sampleSize,
     " ctx=", be.filters.ctx.q, " stats=", be.filters.ctx.stats

  # -------------------

  for n in 1 .. sampleSize:
    let storeFilterOK = be.storeFilter(serial=n)
    xCheck storeFilterOK
    #show(n)
    let validateFifoOk = be.validateFifo(serial=n)
    xCheck validateFifoOk

  # -------------------

  # Squash some entries on the fifo
  block:
    var
      filtersLen = be.filters.len
      nDel = (filtersLen * reorgPercent) div 100
      filter: FilterRef

    # Extract and delete leading filters, use squashed filters extract
    let fetchDeleteOk = be.fetchDelete(nDel, filter)
    xCheck fetchDeleteOk
    xCheck be.filters.len + nDel == filtersLen

    # Push squashed filter
    let storeFilterOK = be.storeFilter filter
    xCheck storeFilterOK

  #show sampleSize

  # -------------------

  # Continue adding items
  for n in sampleSize + 1 .. 2 * sampleSize:
    let storeFilterOK = be.storeFilter(serial=n)
    xCheck storeFilterOK
    #show(n)
    let validateFifoOk = be.validateFifo(serial=n)
    xCheck validateFifoOk

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
