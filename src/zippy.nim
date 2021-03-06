import zippy/buffer, zippy/zippyexception, zippy/tree

export zippyexception

const
  codeLengthOrder = [
    16.int8, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
  ]

  baseLengths = [
    3.uint16, 4, 5, 6, 7, 8, 9, 10, # 257 - 264
    11, 13, 15, 17,                 # 265 - 268
    19, 23, 27, 31,                 # 269 - 273
    35, 43, 51, 59,                 # 274 - 276
    67, 83, 99, 115,                # 278 - 280
    131, 163, 195, 227,             # 281 - 284
    258                             # 285
  ]

  baseLengthsExtraBits = [
    0.int8, 0, 0, 0, 0, 0, 0, 0,    # 257 - 264
    1, 1, 1, 1,                     # 265 - 268
    2, 2, 2, 2,                     # 269 - 273
    3, 3, 3, 3,                     # 274 - 276
    4, 4, 4, 4,                     # 278 - 280
    5, 5, 5, 5,                     # 281 - 284
    0                               # 285
  ]

  baseDistance = [
    1.uint16, 2, 3, 4,              # 0-3
    5, 7,                           # 4-5
    9, 13,                          # 6-7
    17, 25,                         # 8-9
    33, 49,                         # 10-11
    65, 97,                         # 12-13
    129, 193,                       # 14-15
    257, 385,                       # 16-17
    513, 769,                       # 18-19
    1025, 1537,                     # 20-21
    2049, 3073,                     # 22-23
    4097, 6145,                     # 24-25
    8193, 12289,                    # 26-27
    16385, 24577                    # 28-29
  ]

  baseDistanceExtraBits = [
    0.int8, 0, 0, 0,                # 0-3
    1, 1,                           # 4-5
    2, 2,                           # 6-7
    3, 3,                           # 8-9
    4, 4,                           # 10-11
    5, 5,                           # 12-13
    6, 6,                           # 14-15
    7, 7,                           # 16-17
    8, 8,                           # 18-19
    9, 9,                           # 20-21
    10, 10,                         # 22-23
    11, 11,                         # 24-25
    12, 12,                         # 26-27
    13, 13                          # 28-29
  ]

{.push checks: off.}

template failUncompress() =
  raise newException(
    ZippyException, "Invalid buffer, unable to uncompress"
  )

func buildHuffmanAlphabet(codeLengths: seq[uint8]): seq[uint16] =
  if codeLengths.len - 1 > high(uint16).int:
    failUncompress()

  var blCount: array[16, uint16]
  for i in 0 ..< codeLengths.len:
    let codeLength = codeLengths[i]
    if codeLength > 15:
      failUncompress()
    inc blCount[codeLength]

  blCount[0] = 0

  var nextCode: array[16, uint16]
  for bits in 1 ..< nextCode.len:
    nextCode[bits] = (nextCode[bits - 1] + blCount[bits - 1]) shl 1

  result.setLen(codeLengths.len)
  for n in 0 ..< codeLengths.len:
    let len = codeLengths[n]
    if len != 0:
      result[n] = nextCode[len]
      inc nextCode[len]

func buildHuffmanTree(lengths: seq[uint8], alphabet: seq[uint16]): Node =
  result = Node()
  for i, length in lengths:
    if length == 0:
      continue
    result.insert(alphabet[i], length.uint8, i.uint16)

const
  fixedCodeLengths = block:
    var lengths = newSeq[uint8](288)
    for i in 0 ..< lengths.len:
      if i <= 143:
        lengths[i] = 8
      elif i <= 255:
        lengths[i] = 9
      elif i <= 279:
        lengths[i] = 7
      else:
        lengths[i] = 8
    lengths

  fixedDistanceLengths = block:
    var lengths = newSeq[uint8](32)
    for i in 0 ..< lengths.len:
      lengths[i] = 5
    lengths

  fixedAlphabet = buildHuffmanAlphabet(fixedCodeLengths)
  fixedDistAlphabet = buildHuffmanAlphabet(fixedDistanceLengths)

let
  fixedLiteralTree = buildHuffmanTree(fixedCodeLengths, fixedAlphabet)
  fixedDistanceTree = buildHuffmanTree(fixedDistanceLengths, fixedDistAlphabet)

func decodeHuffman(
  b: var Buffer,
  tree: Node
): uint16 =
  var node = tree
  while node.left != nil or node.right != nil:
    var bit = b.readBits(1)
    node = if bit != 0: node.right else: node.left
  return node.symbol

func inflateNoCompression(b: var Buffer, dst: var seq[uint8]) =
  b.skipRemainingBitsInCurrentByte()
  let len = b.readBits(16).int
  b.skipBits(16) # nlen
  let pos = dst.len
  dst.setLen(pos + len) # Make room for the bytes to be copied to
  b.readBytes(dst[pos].addr, len)

proc inflateBlock(b: var Buffer, dst: var seq[uint8], fixedCodes: bool) =
  func decode(
    b: var Buffer,
    dst: var seq[uint8],
    literalTree: Node,
    distanceTree: Node
  ) =
    while true:
      let symbol = decodeHuffman(b, literalTree)
      if symbol <= 255:
        dst.add(symbol.uint8)
      elif symbol == 256:
        break
      else:
        let
          lengthIndex = symbol - 257
          totalLength = baseLengths[lengthIndex] +
            b.readBits(baseLengthsExtraBits[lengthIndex])
          distCode = decodeHuffman(b, distanceTree)
        if distCode >= 30:
          failUncompress()
        let totalDist = baseDistance[distCode] +
          b.readBits(baseDistanceExtraBits[distCode])

        var pos = dst.len - totalDist.int
        if pos < 0:
          failUncompress()

        for i in 0 ..< totalLength.int:
          dst.add(dst[pos])
          inc pos

  if fixedCodes:
    decode(
      b,
      dst,
      fixedLiteralTree,
      fixedDistanceTree
    )
  else:
    let
      hlit = b.readBits(5).int + 257
      hdist = b.readBits(5).int + 1
      hclen = b.readBits(4).int + 4

    var codeLengths = newSeq[uint8](19)
    for i in 0 ..< hclen.int:
      codeLengths[codeLengthOrder[i]] = b.readBits(3).uint8

    let
      codes = buildHuffmanAlphabet(codeLengths)
      tree = buildHuffmanTree(codeLengths, codes)

    var unpacked: seq[uint8]
    while unpacked.len < hlit + hdist:
      let symbol = decodeHuffman(b, tree)
      if symbol <= 15:
        unpacked.add(symbol.uint8)
      elif symbol == 16:
        let prev = unpacked[unpacked.len - 1]
        for i in 0 ..< b.readBits(2).int + 3:
          unpacked.add(prev)
      elif symbol == 17:
        unpacked.setLen(unpacked.len + b.readBits(3).int + 3)
      elif symbol == 18:
        unpacked.setLen(unpacked.len + b.readBits(7).int + 11)
      else:
        raise newException(ZippyException, "Invalid symbol")

    let
      literalLengths = unpacked[0 ..< hlit]
      distanceLengths = unpacked[hlit ..< unpacked.len]
      literalAlphabet = buildHuffmanAlphabet(literalLengths)
      distanceAlphabet = buildHuffmanAlphabet(distanceLengths)
      literalTree = buildHuffmanTree(literalLengths, literalAlphabet)
      distanceTree = buildHuffmanTree(distanceLengths, distanceAlphabet)

    decode(
      b,
      dst,
      literalTree,
      distanceTree
    )

proc inflate(b: var Buffer, dst: var seq[uint8]) =
  var finalBlock: bool
  while not finalBlock:
    let
      bfinal = b.readBits(1)
      btype = b.readBits(2)
    if bfinal > 0:
      finalBlock = true

    case btype:
    of 0: # No compression
      inflateNoCompression(b, dst)
    of 1: # Compressed with fixed Huffman codes
      inflateBlock(b, dst, true)
    of 2: # Compressed with dynamic Huffman codes
      inflateBlock(b, dst, false)
    else:
      raise newException(ZippyException, "Invalid block header")

proc uncompress*(src: seq[uint8], dst: var seq[uint8]) =
  ## Uncompresses src into dst. This resizes dst as needed and starts writing
  ## at dst index 0.

  var b = initBuffer(src)
  let
    cmf = b.readBits(8)
    flg = b.readBits(8)
    cm = cmf and 0b00001111
    cinfo = cmf shr 4

  if cm != 8: # DEFLATE
    raise newException(ZippyException, "Unsupported compression method")
  if cinfo > 7:
    raise newException(ZippyException, "Invalid compression info")
  if ((cmf.uint16 * 256) + flg.uint16) mod 31 != 0:
    raise newException(ZippyException, "Invalid header")
  if (flg and 0b00100000) != 0: # FDICT
    raise newException(ZippyException, "Preset dictionary is not yet supported")

  inflate(b, dst)

proc uncompress*(src: seq[uint8]): seq[uint8] {.inline.} =
  ## Uncompresses src and returns the uncompressed data seq.
  uncompress(src, result)

template uncompress*(src: string): string =
  cast[string](uncompress(cast[seq[uint8]](src)))

{.pop.}
