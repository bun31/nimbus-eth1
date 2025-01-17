# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sequtils, sets, tables],
  eth/common,
  results,
  ./kvt_desc

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersKeys*(db: KvtDbRef): int =
  ## Maximum number of ley/value entries on the cache layers. This is an upper
  ## bound for the number of effective key/value mappings held on the cache
  ## layers as there might be duplicate entries for the same key on different
  ## layers.
  db.stack.mapIt(it.delta.sTab.len).foldl(a + b, db.top.delta.sTab.len)

# ------------------------------------------------------------------------------
# Public functions: get function
# ------------------------------------------------------------------------------

func layersHasKey*(db: KvtDbRef; key: openArray[byte]): bool =
  ## Return `true` id the argument key is cached.
  ##
  if db.top.delta.sTab.hasKey @key:
    return true

  for w in db.rstack:
    if w.delta.sTab.hasKey @key:
      return true


func layersGet*(db: KvtDbRef; key: openArray[byte]): Result[Blob,void] =
  ## Find an item on the cache layers. An `ok()` result might contain an
  ## empty value if it is stored on the cache  that way.
  ##
  if db.top.delta.sTab.hasKey @key:
    return ok(db.top.delta.sTab.getOrVoid @key)

  for w in db.rstack:
    if w.delta.sTab.hasKey @key:
      return ok(w.delta.sTab.getOrVoid @key)

  err()

# ------------------------------------------------------------------------------
# Public functions: put function
# ------------------------------------------------------------------------------

func layersPut*(db: KvtDbRef; key: openArray[byte]; data: openArray[byte]) =
  ## Store a (potentally empty) value on the top layer
  db.top.delta.sTab[@key] = @data

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func layersCc*(db: KvtDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  let layers = if db.stack.len <= level: db.stack & @[db.top]
               else:                     db.stack[0 .. level]

  # Set up initial layer (bottom layer)
  result = LayerRef(delta: LayerDeltaRef(sTab: layers[0].delta.sTab))

  # Consecutively merge other layers on top
  for n in 1 ..< layers.len:
    for (key,val) in layers[n].delta.sTab.pairs:
      result.delta.sTab[key] = val

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator layersWalk*(
    db: KvtDbRef;
    seen: var HashSet[Blob];
      ): tuple[key: Blob, data: Blob] =
  ## Walk over all key-value pairs on the cache layers. Note that
  ## entries are unsorted.
  ##
  ## The argument `seen` collects a set of all visited vertex IDs including
  ## the one with a zero vertex which are othewise skipped by the iterator.
  ## The `seen` argument must not be modified while the iterator is active.
  ##
  for (key,val) in db.top.delta.sTab.pairs:
    yield (key,val)
    seen.incl key

  for w in db.rstack:
    for (key,val) in w.delta.sTab.pairs:
      if key notin seen:
        yield (key,val)
        seen.incl key

iterator layersWalk*(
    db: KvtDbRef;
      ): tuple[key: Blob, data: Blob] =
  ## Variant of `layersWalk()`.
  var seen: HashSet[Blob]
  for (key,val) in db.layersWalk seen:
    yield (key,val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
