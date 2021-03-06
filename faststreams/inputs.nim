import
  os, memfiles, options,
  stew/[ptrops, ranges/ptr_arith],
  async_backend, buffers

export
  options, CloseBehavior

type
  InputStream* = ref object of RootObj
    vtable*: ptr InputStreamVTable # This is nil for unsafe memory inputs
    buffers*: PageBuffers          # This is nil for unsafe memory inputs
    span*: PageSpan
    spanEndPos*: Natural
    closeFut*: Future[void]        # This is nil before `close` is called
    when debugHelpers:
      name*: string

  LayeredInputStream* = ref object of InputStream
    source*: InputStream
    allowWaitFor*: bool

  InputStreamHandle* = object
    s*: InputStream

  AsyncInputStream* {.borrow: `.`.} = distinct InputStream

  ReadSyncProc* = proc (s: InputStream, dst: pointer, dstLen: Natural): Natural
                       {.nimcall, gcsafe, raises: [IOError, Defect].}

  ReadAsyncProc* = proc (s: InputStream, dst: pointer, dstLen: Natural): Future[Natural]
                        {.nimcall, gcsafe, raises: [IOError, Defect].}

  CloseSyncProc* = proc (s: InputStream)
                        {.nimcall, gcsafe, raises: [IOError, Defect].}

  CloseAsyncProc* = proc (s: InputStream): Future[void]
                         {.nimcall, gcsafe, raises: [IOError, Defect].}

  GetLenSyncProc* = proc (s: InputStream): Option[Natural]
                         {.nimcall, gcsafe, raises: [IOError, Defect].}

  InputStreamVTable* = object
    readSync*: ReadSyncProc
    readAsync*: ReadAsyncProc
    closeSync*: CloseSyncProc
    closeAsync*: CloseAsyncProc
    getLenSync*: GetLenSyncProc

  MemFileInputStream = ref object of InputStream
    file: MemFile

  FileInputStream = ref object of InputStream
    file: File

template Sync*(s: InputStream): InputStream = s
template Async*(s: InputStream): AsyncInputStream = AsyncInputStream(s)

template Sync*(s: AsyncInputStream): InputStream = InputStream(s)
template Async*(s: AsyncInputStream): AsyncInputStream = s

proc disconnectInputDevice(s: InputStream) =
  # TODO
  # Document the behavior that closeAsync is preferred
  if s.vtable != nil:
    if s.vtable.closeAsync != nil:
      s.closeFut = s.vtable.closeAsync(s)
    elif s.vtable.closeSync != nil:
      s.vtable.closeSync(s)
    s.vtable = nil

template disconnectInputDevice(s: AsyncInputStream) =
  disconnectInputDevice InputStream(s)

proc preventFurtherReading(s: InputStream) =
  s.vtable = nil
  s.span = default(PageSpan)

template preventFurtherReading(s: AsyncInputStream) =
  preventFurtherReading InputStream(s)

template makeHandle*(sp: InputStream): InputStreamHandle =
  let s = sp
  InputStreamHandle(s: s)

proc close*(s: InputStream,
            behavior = dontWaitAsyncClose)
           {.raises: [IOError, Defect].} =
  ## Closes the stream. Any resources associated with the stream
  ## will be released and no further reading will be possible.
  ##
  ## If the underlying input device requires asynchronous closing
  ## and `behavior` is set to `waitAsyncClose`, this proc will use
  ## `waitFor` to block until the async operation completes.
  s.disconnectInputDevice()
  s.preventFurtherReading()
  if s.closeFut != nil:
    fsTranslateErrors "Stream closing failed":
      if behavior == waitAsyncClose:
        waitFor s.closeFut
      else:
        asyncCheck s.closeFut

template close*(sp: AsyncInputStream) =
  ## Starts the asychronous closing of the stream and returns a future that
  ## tracks the closing operation.
  let s = InputStream sp
  disconnectInputDevice(s)
  preventFurtherReading(s)
  if s.closeFut != nil:
    await s.closeFut

template closeNoWait*(sp: AsyncInputStream|InputStream) =
  ## Close the stream without waiting even if's async.
  ## This operation will use `asyncCheck` internally to detect unhandled
  ## errors from the closing operation.
  close(InputStream(s), dontWaitAsyncClose)

# TODO
# The destructors are currently disabled because they seem to cause
# mysterious segmentation faults related to corrupted GC internal
# data structures.
#[
proc `=destroy`*(h: var InputStreamHandle) {.raises: [Defect].} =
  if h.s != nil:
    if h.s.vtable != nil and h.s.vtable.closeSync != nil:
      try:
        h.s.vtable.closeSync(h.s)
      except IOError:
        # Since this is a destructor, there is not much we can do here.
        # If the user wanted to handle the error, they would have called
        # `close` manually.
        discard # TODO
    # TODO ATTENTION!
    # Uncommenting the following line will lead to a GC heap corruption.
    # Most likely this leads to Nim collecting some object prematurely.
    # h.s = nil
    # We work-around the problem through more indirect incapacitatation
    # of the stream object:
    h.s.preventFurtherReading()
]#

converter implicitDeref*(h: InputStreamHandle): InputStream =
  ## Any `InputStreamHandle` value can be implicitly converted to an
  ## `InputStream` or an `AsyncInputStream` value.
  h.s

template vtableAddr*(vtable: InputStreamVTable): ptr InputStreamVTable =
  # This is a simple work-around for the somewhat broken side
  # effects analysis of Nim - reading from global let variables
  # is considered a side-effect.
  {.noSideEffect.}:
    unsafeAddr vtable

let memFileInputVTable = InputStreamVTable(
  closeSync: proc (s: InputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    try:
      close MemFileInputStream(s).file
    except OSError as err:
      raise newException(IOError, "Failed to close file", err)
  ,
  getLenSync: proc (s: InputStream): Option[Natural]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    some s.span.len
)

proc memFileInput*(filename: string, mappedSize = -1, offset = 0): InputStreamHandle
                  {.raises: [IOError, OSError].} =
  ## Creates an input stream for reading the contents of a memory-mapped file.
  ##
  ## Using this API will provide better performance than `fileInput`,
  ## but this comes at a cost of higher address space usage which may
  ## be problematic when working with extremely large files.
  ##
  ## All parameters are forwarded to Nim's memfiles.open function:
  ##
  ## ``filename``
  ##  The name of the file to read.
  ##
  ## ``mappedSize`` and ``offset``
  ##  can be used to map only a slice of the file.
  ##
  ## ``offset`` must be multiples of the PAGE SIZE of your OS
  ##  (usually 4K or 8K, but is unique to your OS)

  # Nim's memfiles module will fail to map an empty file,
  # but we don't consider this a problem. The stream will
  # be in non-readable state from the start.
  let fileSize = getFileSize(filename)
  if fileSize == 0:
    return makeHandle InputStream()

  let
    memFile = memfiles.open(filename,
                            mode = fmRead,
                            mappedSize = mappedSize,
                            offset = offset)
    head = cast[ptr byte](memFile.mem)
    mappedSize = memFile.size

  makeHandle MemFileInputStream(
    vtable: vtableAddr memFileInputVTable,
    span: PageSpan(
      startAddr: head,
      endAddr: offset(head, mappedSize)),
    file: memFile)

proc readableNow*(s: InputStream): bool =
  (not s.span.atEnd) or (s.buffers != nil and s.buffers.len > 1)

template readableNow*(s: AsyncInputStream): bool =
  readableNow InputStream(s)

# TODO: The pure async interface should be moved in a separate module
#       to make FastStreams more light-weight when the async back-end
#       is not used (e.g. in Confutils)
#
#       The problem is that the `async` macro will pull the entire
#       event loop right now.

proc readOnce*(sp: AsyncInputStream): Future[Natural] {.async.} =
  let s = InputStream(sp)
  fsAssert s.buffers != nil and s.vtable != nil

  result = await s.vtable.readAsync(s, nil, 0)

  if s.buffers.eofReached:
    disconnectInputDevice(s)

  if result > 0 and s.span.len == 0:
    s.buffers.nextReadableSpan(s.span)
    s.spanEndPos += s.span.len

proc timeoutToNextByteImpl(s: AsyncInputStream,
                           deadline: Future): Future[bool] {.async.} =
  let readFut = s.readOnce
  await readFut or deadline
  if not readFut.finished:
    readFut.cancel()
    return true
  else:
    return false

template timeoutToNextByte*(sp: AsyncInputStream, deadline: Future): bool =
  let s = sp
  if readableNow(s):
    true
  else:
    await timeoutToNextByteImpl(s, deadline)

template timeoutToNextByte*(sp: AsyncInputStream, timeout: Duration): bool =
  let s = sp
  if readableNow(s):
    true
  else:
    await timeoutToNextByteImpl(s, sleepAsync(timeout))

proc closeAsync*(s: AsyncInputStream) {.async.} =
  close s

# TODO: End of purely async interface

func flipPage(s: InputStream) =
  fsAssert s.buffers != nil and s.buffers.len > 1
  discard s.buffers.popFirst
  s.span = obtainReadableSpan s.buffers[0]
  s.spanEndPos += s.span.len

func getBestContiguousRunway(s: InputStream): Natural =
  result = s.span.len
  if result == 0:
    if s.buffers != nil and s.buffers.len > 1:
      flipPage s
      result = s.span.len

template withReadableRange*(sp: InputStream|AsyncInputStream,
                            rangeLen: Natural,
                            rangeStreamVarName, blk: untyped) =
  let s = InputStream sp

  let vtable = s.vtable
  s.vtable = nil

  try:
    let `rangeStreamVarName` {.inject.} = s
    blk
  finally:
    s.vtable = vtable

func totalUnconsumedBytes*(s: InputStream): Natural =
  ## Returns the number of bytes that are currently sitting within the stream
  ## buffers and that can be consumed with `read` or `advance`.
  let
    localRunway = s.span.len
    runwayInBuffers = if s.buffers == nil: 0
                      else: s.buffers.totalBufferedBytes

  if localRunway == 0 and runwayInBuffers > 0:
    flipPage s

  localRunway + runwayInBuffers

template totalUnconsumedBytes*(s: AsyncInputStream): Natural =
  ## Alias for InputStream.totalUnconsumedBytes
  totalUnconsumedBytes InputStream(s)

let fileInputVTable = InputStreamVTable(
  readSync: proc (s: InputStream, dst: pointer, dstLen: Natural): Natural
                 {.nimcall, gcsafe, raises: [IOError, Defect].} =
    let file = FileInputStream(s).file
    implementSingleRead(s.buffers, dst, dstLen,
                        {partialReadIsEof},
                        readStartAddr, readLen):
      file.readBuffer(readStartAddr, readLen)
  ,
  getLenSync: proc (s: InputStream): Option[Natural]
                   {.nimcall, gcsafe, raises: [IOError, Defect].} =
    let
      s = FileInputStream(s)
      runway = s.totalUnconsumedBytes

    let preservedPos = getFilePos(s.file)
    setFilePos(s.file, 0, fspEnd)
    let endPos = getFilePos(s.file)
    setFilePos(s.file, preservedPos)

    some Natural(endPos - preservedPos + runway)
  ,
  closeSync: proc (s: InputStream)
                  {.nimcall, gcsafe, raises: [IOError, Defect].} =
    try:
      close FileInputStream(s).file
    except OSError as err:
      raise newException(IOError, "Failed to close file", err)
)

proc fileInput*(filename: string,
                offset = 0,
                pageSize = defaultPageSize): InputStreamHandle
               {.raises: [IOError, OSError].} =
  ## Creates an input stream for reading the contents of a file
  ## through Nim's `io` module.
  ##
  ## Parameters:
  ##
  ## ``filename``
  ##  The name of the file to read.
  ##
  ## ``offset``
  ##  Initial position in the file where reading should start.
  ##
  let file = system.open(filename, fmRead)

  if offset != 0:
    setFilePos(file, offset)

  makeHandle FileInputStream(
    vtable: vtableAddr fileInputVTable,
    buffers: initPageBuffers(pageSize),
    file: file)

proc unsafeMemoryInput*(mem: openarray[byte]): InputStreamHandle =
  let head = unsafeAddr mem[0]

  makeHandle InputStream(
    span: PageSpan(
      startAddr: head,
      endAddr: offset(head, mem.len)),
    spanEndPos: mem.len)

proc unsafeMemoryInput*(str: string): InputStreamHandle =
  unsafeMemoryInput str.toOpenArrayByte(0, str.len - 1)

proc len*(s: InputStream): Option[Natural] {.raises: [Defect, IOError].} =
  if s.vtable == nil:
    some s.totalUnconsumedBytes
  elif s.vtable.getLenSync != nil:
    s.vtable.getLenSync(s)
  else:
    none Natural

template len*(s: AsyncInputStream): Option[Natural] =
  len InputStream(s)

func memoryInput*(buffers: PageBuffers): InputStreamHandle =
  var span = if buffers.len == 0: default(PageSpan)
             else: obtainReadableSpan buffers.queue[0]

  makeHandle InputStream(buffers: buffers,
                         span: span,
                         spanEndPos: span.len)

func memoryInput*(data: openarray[byte]): InputStreamHandle =
  let
    buffers = initPageBuffers(data.len)
    page = buffers.addWritablePage(data.len)
    pageSpan = page.fullSpan

  copyMem(pageSpan.startAddr, unsafeAddr data[0], data.len)

  makeHandle InputStream(buffers: buffers,
                         span: pageSpan,
                         spanEndPos: data.len)

func memoryInput*(data: openarray[char]): InputStreamHandle =
  memoryInput charsToBytes(data)

proc resetBuffers*(s: InputStream, buffers: PageBuffers) =
  # This should be used only on safe memory input streams
  fsAssert s.vtable == nil and s.buffers != nil and buffers.len > 0
  s.buffers = buffers
  s.span = obtainReadableSpan buffers.queue[0]
  s.spanEndPos = s.span.len

proc continueAfterRead(s: InputStream, bytesRead: Natural): bool =
  # Please note that this is extracted into a proc only to reduce the code
  # that ends up inlined into async procs by `bufferMoreDataImpl`.
  # The inlining itself is required to support the await-free operation of
  # the `readable` APIs.

  # The read might have been incomplete which signals the EOF of the stream.
  # If this is the case, we disconnect the input device which prevents any
  # further attempts to read from it:
  if s.buffers.eofReached:
    disconnectInputDevice(s)

  if bytesRead > 0:
    s.buffers.nextReadableSpan(s.span)
    s.spanEndPos += s.span.len
    return true
  else:
    return false

template bufferMoreDataImpl(s, awaiter, readOp: untyped): bool =
  # This template is always called when the current page has been
  # completely exhausted. It should produce `true` if more data was
  # successfully buffered, so reading can continue.
  #
  # The vtable will be `nil` for a memory stream and `vtable.readOp`
  # will be `nil` for a memFile. If we've reached here, this is the
  # end of the memory buffer, so we can signal EOF:
  if s.buffers == nil or s.vtable == nil or s.vtable.readOp == nil:
    false
  else:
    # There might be additional pages in our buffer queue. If so, we
    # just jump to the next one:
    if s.buffers.len > 1:
      flipPage s
      true
    else:
      # We ask our input device to populate our page queue with newly
      # read pages. The state of the queue afterwards will tell us if
      # the read was successful. In `continueAfterRead`, we examine if
      # EOF was reached, but please note that some data might have been
      # read anyway:
      continueAfterRead(s, awaiter s.vtable.readOp(s, nil, 0))

proc bufferMoreDataSync(s: InputStream): bool =
  # This proc exists only to avoid inlining of the code of
  # `bufferMoreDataImpl` into `readable` (which in turn is
  # a template inlined in the user code).
  bufferMoreDataImpl(s, noAwait, readSync)

template readable*(sp: InputStream): bool =
  ## Checks whether reading more data from the stream is possible.
  ##
  ## If there is any unconsumed data in the stream buffers, the
  ## operation returns `true` immediately. You can call `read`
  ## or `peek` afterwards to consume or examine the next byte
  ## in the stream.
  ##
  ## If the stream buffers are empty, the operation may block
  ## until more data becomes available. The end of the stream
  ## may be reached at this point, which will be indicated by
  ## a `false` return value. Any attempt to call `read` or
  ## `peek` afterwards is considered a `Defect`.
  ##
  ## Please note that this API is intended for stream consumers
  ## who need to consume the data one byte at a time. A typical
  ## usage will be the following:
  ##
  ## ```nim
  ## while stream.readable:
  ##   case stream.peek.char
  ##   of '"':
  ##     parseString(stream)
  ##   of '0'..'9':
  ##     parseNumber(stream)
  ##   of '\':
  ##     discard stream.read # skip the slash
  ##     let escapedChar = stream.read
  ## ```
  ##
  ## Even though the user code consumes the data one byte at a time,
  ## in the majority of cases this consist of simply incrementing a
  ## pointer within the stream buffers. Only when the stream buffers
  ## are exhausted, a new read operation will be executed throught
  ## the stream input device which may repopulate the buffers with
  ## fresh data. See `Stream Pages` for futher discussion of this.

  # This is a template, because we want the pointer check to be
  # inlined at the call sites. Only if it fails, we call into the
  # larger non-inlined proc:
  let s = sp
  hasRunway(s.span) or bufferMoreDataSync(s)

template readable*(sp: AsyncInputStream): bool =
  ## Async version of `readable`.
  ## The intended API usage is the same. Instead of blocking, an async
  ## stream will use `await` while waiting for more data.
  let s = InputStream sp
  if hasRunway(s.span):
    true
  else:
    bufferMoreDataImpl(s, fsAwait, readAsync)

func continueAfterReadN(s: InputStream,
                        runwayBeforeRead, bytesRead: Natural) =
  if runwayBeforeRead == 0 and bytesRead > 0:
    s.buffers.nextReadableSpan(s.span)
    s.spanEndPos += s.span.len

template readableNImpl(s, n, awaiter, readOp: untyped): bool =
  let runway = totalUnconsumedBytes(s)
  if runway >= n:
    true
  elif s.buffers == nil or s.vtable == nil or s.vtable.readOp == nil:
    false
  else:
    var
      res = false
      bytesRead = Natural 0
      bytesDeficit = n - runway

    while true:
      bytesRead += awaiter s.vtable.readOp(s, nil, bytesDeficit)

      if s.buffers.eofReached:
        disconnectInputDevice(s)
        res = bytesRead >= bytesDeficit
        break

      if bytesRead >= bytesDeficit:
        res = true
        break

    continueAfterReadN(s, runway, bytesRead)
    res

proc readable*(s: InputStream, n: int): bool =
  ## Checks whether reading `n` bytes from the input stream is possible.
  ##
  ## If there is enough unconsumed data in the stream buffers, the
  ## operation will return `true` immediately. You can use `read`,
  ## `peek`, `read(n)` or `peek(n)` afterwards to consume up to the
  ## number of verified bytes. Please note that consuming more bytes
  ## will be considered a `Defect`.
  ##
  ## If the stream buffers do not contain enough data, the operation
  ## may block until more data becomes available. The end of the stream
  ## may be reached at this point, which will be indicated by a `false`
  ## return value. Please note that the stream might still contain some
  ## unconsumed bytes after `readable(n)` returned false. You can use
  ## `totalUnconsumedBytes` or a combination of `readable` and `read`
  ## to consume the remaining bytes if desired.
  ##
  ## If possible, prefer consuming the data one byte at a time. This
  ## ensures the most optimal usage of the stream buffers. Even after
  ## calling `readable(n)`, it's still preferrable to continue with
  ## `read` instead of `read(n)` because the later may require the
  ## resulting bytes to be copied to a freshly allocated sequence.
  ##
  ## In the situation where the consumed bytes need to be copied to
  ## an existing external buffer, `readInto` will provide the best
  ## performance instead.
  ##
  ## Just like `readable`, this operation will invoke reads on the
  ## stream input device only when necessary. See `Stream Pages`
  ## for futher discussion of this.
  readableNImpl(s, n, noAwait, readSync)

template readable*(sp: AsyncInputStream, np: int): bool =
  ## Async version of `readable(n)`.
  ## The intended API usage is the same. Instead of blocking, an async
  ## stream will use `await` while waiting for more data.
  let
    s = InputStream sp
    n = np

  readableNImpl(s, n, fsAwait, readAsync)

when false:
  func flipPagePeek(s: InputStream): byte =
    flipPage s
    result = s.span.startAddr[]

func flipPageRead(s: InputStream): byte =
  flipPage s
  result = s.span.startAddr[]
  bumpPointer s.span

template peek*(sp: InputStream): byte =
  let s = sp
  if hasRunway(s.span):
    s.span.startAddr[]
  else:
    flipPage s
    s.span.startAddr[]

template peek*(s: AsyncInputStream): byte =
  peek InputStream(s)

template read*(sp: InputStream): byte =
  let s = sp
  if hasRunway(s.span):
    let res = s.span.startAddr[]
    bumpPointer(s.span)
    res
  else:
    flipPageRead s

template read*(s: AsyncInputStream): byte =
  read InputStream(s)

proc peekAt*(s: InputStream, pos: int): byte {.inline.} =
  # TODO implement page flipping
  let peekHead = offset(s.span.startAddr, pos)
  fsAssert cast[uint](peekHead) < cast[uint](s.span.endAddr)
  return peekHead[]

template peekAt*(s: AsyncInputStream, pos: int): byte =
  peekAt InputStream(s), pos

proc advance*(s: InputStream) =
  if hasRunway(s.span):
    bumpPointer s.span
  else:
    flipPage s

proc advance*(s: InputStream, n: Natural) =
  # TODO This is silly, implement it properly
  for i in 0 ..< n:
    advance s

template advance*(s: AsyncInputStream) =
  advance InputStream(s)

template advance*(s: AsyncInputStream, n: Natural) =
  advance InputStream(s), n

proc drainBuffersInto*(s: InputStream, dstAddr: ptr byte, dstLen: Natural): Natural =
  var
    dst = dstAddr
    remainingBytes = dstLen
    runway = s.span.len

  if runway >= remainingBytes:
    copyMem(dst, s.span.startAddr, remainingBytes)
    s.span.bumpPointer remainingBytes
    return dstLen
  elif runway > 0:
    copyMem(dst, s.span.startAddr, runway)
    dst = offset(dst, runway)
    remainingBytes -= runway

  if s.buffers != nil:
    # Since we reached the end of the current page,
    # we have to do the equivalent of `flipPage`:

    # TODO: what if the page was extended?
    if s.buffers.len > 0:
      discard s.buffers.popFirst()

    for page in consumePages(s.buffers):
      let
        pageStart = page.readableStart
        pageLen = page.writtenTo - page.consumedTo

      # There are two possible scenarios ahead:
      # 1) We'll either stop at this page in which case our span will
      #    point to the end of the page (so, it's fully consumed)
      # 2) We are going to copy the entire page to the destination
      #    buffer and we'll continue (so, it's fully consumed again)
      page.consumedTo = page.writtenTo

      if pageLen > remainingBytes:
        # This page has enough data to fill the rest of the buffer:
        copyMem(dst, pageStart, remainingBytes)

        # This page is partially consumed now and we must set our
        # span to point to its remaining contents:
        s.span = PageSpan(startAddr: offset(pageStart, remainingBytes),
                          endAddr: page.readableEnd)

        # We also need to know how much our position in the stream
        # has advanced:
        let bytesDrainedFromBuffers = dstLen - runway
        s.spanEndPos += bytesDrainedFromBuffers + s.span.len

        # We return the length of the buffer, which means that is
        # has been fully populated:
        return dstLen
      else:
        copyMem(dst, pageStart, pageLen)
        remainingBytes -= pageLen
        dst = offset(dst, pageLen)

  # We've completerly drained the current span and all the buffers,
  # so we set the span to a pristine state that will trigger a new
  # read on the next interaction with the stream.
  s.span = default(PageSpan)

  # We failed to populate the entire buffer
  return dstLen - remainingBytes

template readIntoExImpl(s: InputStream,
                        dst: ptr byte, dstLen: Natural,
                        awaiter, readOp: untyped): Natural =
  var bytesRead = drainBuffersInto(s, dst, dstLen)

  while bytesRead < dstLen:
    let
      bytesDeficit = dstLen - bytesRead
      adjustedDst = offset(dst, bytesRead)

    bytesRead += awaiter s.vtable.readOp(s, adjustedDst, bytesDeficit)

    if s.buffers.eofReached:
      disconnectInputDevice(s)
      break

  s.spanEndPos += bytesRead
  bytesRead

proc readIntoEx*(s: InputStream, dst: var openarray[byte]): int =
  ## Read data into the destination buffer.
  ##
  ## Returns the number of bytes that were successfully
  ## written to the buffer. The function will return a
  ## number smaller than the buffer length only if EOF
  ## was reached before the buffer was fully populated.
  let dstAddr = addr dst[0]
  let dstLen = dst.len
  readIntoExImpl(s, dstAddr, dstLen, noAwait, readSync)

proc readInto*(s: InputStream, target: var openarray[byte]): bool =
  ## Read data into the destination buffer.
  ##
  ## Returns `false` if EOF was reached before the buffer
  ## was fully populated. if you need precise information
  ## regarding the number of bytes read, see `readIntoEx`.
  s.readIntoEx(target) == target.len

template readIntoEx*(sp: AsyncInputStream, dst: var openarray[byte]): int =
  let s = sp
  # BEWARE! `openArrayToPair` here is needed to avoid
  # double evaluation of the `dst` expression:
  let (dstAddr, dstLen) = openArrayToPair(dst)
  readIntoExImpl(s, dstAddr, dstLen, fsAwait, readAsync)

template readInto*(sp: AsyncInputStream, dst: var openarray[byte]): bool =
  ## Asynchronously read data into the destination buffer.
  ##
  ## Returns `false` if EOF was reached before the buffer
  ## was fully populated. if you need precise information
  ## regarding the number of bytes read, see `readIntoEx`.
  ##
  ## If there are enough bytes already buffered by the stream,
  ## the expression will complete immediately.
  ## Otherwise, it will await more bytes to become available.

  let s = sp
  # BEWARE! `openArrayToPair` here is needed to avoid
  # double evaluation of the `dst` expression:
  let (dstAddr, dstLen) = openArrayToPair(dst)
  readIntoExImpl(s, dstAddr, dstLen, fsAwait, readAsync) == dstLen

when defined(windows):
  proc alloca(n: int): ptr byte {.importc, header: "<malloc.h>".}
else:
  proc alloca(n: int): ptr byte {.importc, header: "<alloca.h>".}

template allocHeapMem(tmpSeq: var seq[byte], n, _: Natural): ptr byte =
  tmpSeq.setLen(n)
  addr tmpSeq[0]

template allocStackMem(tmpSeq: var seq[byte], _, n: Natural): ptr byte =
  alloca(n)

template readNImpl(sp: InputStream,
                   np: Natural,
                   allocMem: untyped): openarray[byte] =
  let
    s = sp
    n = np
    runway = getBestContiguousRunway(s)

  # Since Nim currently doesn't allow the `makeOpenArray` calls bellow
  # to appear in different branches of an if statement, the code must
  # be written in this branch-free linear fashion. The `dataCopy` seq
  # may remain empty in the case where we use stack memory or return
  # an `openarray` from the existing span.
  var tmpSeq: seq[byte]
  var startAddr: ptr byte

  if n > runway:
    startAddr = allocMem(tmpSeq, n, np)
    let drained {.used.} = drainBuffersInto(s, startAddr, n)
    fsAssert drained == n
  else:
    startAddr = s.span.startAddr
    bumpPointer s.span, n

  makeOpenArray(startAddr, n)

template read*(sp: InputStream, np: static Natural): openarray[byte] =
  const n = np
  when n < maxStackUsage:
    readNImpl(sp, n, allocStackMem)
  else:
    readNImpl(sp, n, allocHeapMem)

template read*(s: InputStream, n: Natural): openarray[byte] =
  readNImpl(s, n, allocHeapMem)

template read*(s: AsyncInputStream, n: Natural): openarray[byte] =
  read InputStream(s), n

proc lookAheadMatch*(s: InputStream, data: openarray[byte]): bool =
  for i in 0 ..< data.len:
    if s.peekAt(i) != data[i]:
      return false

  return true

template lookAheadMatch*(s: AsyncInputStream, data: openarray[byte]): bool =
  lookAheadMatch InputStream(s)

proc next*(s: InputStream): Option[byte] =
  if readable(s):
    result = some read(s)

template next*(sp: AsyncInputStream): Option[byte] =
  let s = sp
  if readable(s):
    some read(s)
  else:
    none byte

proc pos*(s: InputStream): int {.inline.} =
  s.spanEndPos - s.span.len

template pos*(s: AsyncInputStream): int =
  pos InputStream(s)

when false:
  # Obsolete APIs for removal
  proc bufferPos(s: InputStream, pos: int): ptr byte =
    let offsetFromEnd = pos - s.spanEndPos
    fsAssert offsetFromEnd < 0
    result = offset(s.span.endAddr, offsetFromEnd)
    fsAssert result >= s.bufferStart

  proc `[]`*(s: InputStream, pos: int): byte {.inline.} =
    s.bufferPos(pos)[]

  proc rewind*(s: InputStream, delta: int) =
    s.head = offset(s.head, -delta)
    fsAssert s.head >= s.bufferStart

  proc rewindTo*(s: InputStream, pos: int) {.inline.} =
    s.head = s.bufferPos(pos)

