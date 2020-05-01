{.used.}

import
  os, unittest, strutils, random,
  stew/ranges/ptr_arith, testutils,
  ../faststreams, ../faststreams/textio

setCurrentDir getAppDir()

proc bytes(s: string): seq[byte] =
  result = newSeqOfCap[byte](s.len)
  for c in s: result.add byte(c)

proc str(bytes: openarray[byte]): string =
  result = newStringOfCap(bytes.len)
  for b in bytes:
    result.add b.char

proc countLines(s: InputStream): Natural =
  for s in lines(s):
    inc result

const
  asciiTableFile = "files" / "ascii_table.txt"
  asciiTableContents = slurp(asciiTableFile)

procSuite "input stream":
  template emptyInputTests(suiteName, setupCode: untyped) =
    suite suiteName & " empty inputs":
      setup setupCode

      test "input is not readable with read":
        check not input.readable
        expect Defect:
          echo "This read should not complete: ", input.read

      test "input is not readable with read(n)":
        check not input.readable(10)
        expect Defect:
          echo "This read should not complete: ", input.read(10)

      test "next returns none":
        check input.next.isNone

  emptyInputTests "unsafeMemoryInput":
    var str = ""
    var input = unsafeMemoryInput(str)

  emptyInputTests "fileInput":
    var input = memFileInput("files" / "empty_file")

  emptyInputTests "memFileInput":
    var input = fileInput("files" / "empty_file")

  template asciiTableFileTest(name: string, body: untyped) =
    test name & " of ascii table with regular pageSize":
      var input {.inject.} = fileInput(asciiTableFile)
      try:
        body
      finally:
        close input

    test name & " of ascii table with pageSize = 10":
      var input {.inject.} = fileInput(asciiTableFile, pageSize = 10)
      try:
        body
      finally:
        close input

    test name & " of ascii table with pageSize = 1":
      var input {.inject.} = fileInput(asciiTableFile, pageSize = 1)
      try:
        body
      finally:
        close input

  asciiTableFileTest "count lines":
    check countLines(input) == 34

  asciiTableFileTest "mixed read types":
    randomize(10000)

    var fileContents = ""

    while true:
      let r = rand(100)
      if r < 20:
        let readSize = 1 + rand(10)

        var buf = newSeq[byte](readSize)
        let bytesRead = input.readIntoEx(buf)
        fileContents.add buf.toOpenArray(0, bytesRead - 1).str

        if bytesRead < buf.len:
          break

      elif r < 50:
        let readSize = 6 + rand(10)

        if input.readable(readSize):
          fileContents.add input.read(readSize).str
        else:
          while input.readable:
            fileContents.add input.read.char
          break

      else:
        if input.readable:
          fileContents.add input.read.char

      # You can uncomment this to get earlier failure in the test:
      when false:
        require fileContents == asciiTableContents[0 ..< fileContents.len]

    check fileContents == asciiTableContents

  test "missing file input":
    const fileName = "there-is-no-such-faststreams-file"

    check not fileExists(fileName)
    expect CatchableError: discard fileInput(fileName)

    check not fileExists(fileName)
    expect CatchableError: discard memFileInput(fileName)

    check not fileExists(fileName)

  test "simple":
    var input = repeat("1234 5678 90AB CDEF\n", 1000)
    var stream = unsafeMemoryInput(input)

    check:
      (stream.read(4) == "1234".toOpenArrayByte(0, 3))

