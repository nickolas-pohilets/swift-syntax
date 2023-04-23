//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftBasicFormat
import SwiftParser
import SwiftSyntaxBuilder
import SwiftSyntax

import XCTest
import _SwiftSyntaxTestSupport

fileprivate func assertFormatted(
  source: String,
  expected: String,
  file: StaticString = #file,
  line: UInt = #line
) {
  assertStringsEqualWithDiff(Parser.parse(source: source).formatted().description, expected, file: file, line: line)
}

final class BasicFormatTest: XCTestCase {
  func testNotIndented() {
    assertFormatted(
      source: """
        func foo() {
        someFunc(a: 1,
        b: 1)
        }
        """,
      expected: """
        func foo() {
            someFunc(a: 1,
                b: 1)
        }
        """
    )
  }

  func testPartialIndent() {
    assertFormatted(
      source: """
        func foo() {
        someFunc(a: 1,
                 b: 1)
        }
        """,
      expected: """
        func foo() {
            someFunc(a: 1,
                     b: 1)
        }
        """
    )
  }

  func testPartialIndentNested() {
    assertFormatted(
      source: """
        func outer() {
        func inner() {
        someFunc(a: 1,
                 b: 1)
        }
        }
        """,
      expected: """
        func outer() {
            func inner() {
                someFunc(a: 1,
                         b: 1)
            }
        }
        """
    )
  }

  func testAlreadyIndented() {
    let source = """
      func foo() {
        someFunc(a: 1,
                 b: 1)
      }
      """

    assertFormatted(source: source, expected: source)
  }

  func testAlreadyIndentedWithComment() {
    let source = """
      func foo() {
        // ABC
        someFunc(a: 1,
                 b: 1)
      }
      """

    assertFormatted(source: source, expected: source)
  }

  func testAlreadyIndentedWithComment2() {
    assertFormatted(
      source: """
        func foo() {
        // ABC
          someFunc(a: 1,
                   b: 1)
        }
        """,
      expected: """
        func foo() {
            // ABC
              someFunc(a: 1,
                       b: 1)
        }
        """
    )
  }

  func testClosureIndentationArgBefore() {
    assertFormatted(
      source: """
        someFunc(arg2: 1,
            closure: { arg in indented() })
        """,
      expected: """
        someFunc(arg2: 1,
            closure: { arg in
                indented()
            })
        """
    )
  }

  func testClosureIndentationAfter() {
    assertFormatted(
      source: """
        someFunc(closure: { arg in indented() },
            arg2: 1)
        """,
      expected: """
        someFunc(closure: { arg in
                indented()
            },
            arg2: 1)
        """
    )
  }

  func testLineWrappingInsideIndentedBlock() {
    assertFormatted(
      source: """
        public init?(errorCode: Int) {
          guard errorCode > 0 else { return nil }
          self.code = errorCode
        }
        """,
      expected: """
        public init?(errorCode: Int) {
          guard errorCode > 0 else {
              return nil
          }
          self.code = errorCode
        }
        """
    )
  }

  func testCustomIndentationInBlockThatDoesntHaveNewline() {
    assertFormatted(
      source: """
        extension MyType {func buildSyntax(format: Format) -> Syntax {
          return Syntax(buildTest(format: format))
        }}
        """,
      expected: """
        extension MyType {
            func buildSyntax(format: Format) -> Syntax {
              return Syntax(buildTest(format: format))
            }
        }
        """
    )
  }
}