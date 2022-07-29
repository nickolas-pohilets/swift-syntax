import SwiftSyntax
import _SwiftSyntaxTestSupport
import XCTest

public class SyntaxComparisonTests: XCTestCase {
  public func testSame() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    XCTAssertNil(actual.findFirstDifference(baseline: expected))

    let matcher = try SubtreeMatcher("struct A { func f() { } }")
    try XCTAssertNil(matcher.findFirstDifference(baseline: expected))
  }

  public func testDifferentType() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    let actual = Syntax(makeBody())

    let diff = try XCTUnwrap(actual.findFirstDifference(baseline: expected))
    XCTAssertEqual(diff.reason, .nodeType)
    XCTAssertTrue(Syntax(diff.baseline).is(FunctionDeclSyntax.self))
    XCTAssertTrue(Syntax(diff.node).is(CodeBlockSyntax.self))
  }

  public func testDifferentTokenKind() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f"), keyword: SyntaxFactory.makeClassKeyword()))

    func expectations(_ diff: TreeDifference?, file: StaticString = #filePath, line: UInt = #line) throws {
      let diff = try XCTUnwrap(diff, file: file, line: line)
      XCTAssertEqual(diff.reason, .token)
      XCTAssertEqual(Syntax(diff.baseline).as(TokenSyntax.self)?.tokenKind, .classKeyword)
      XCTAssertEqual(Syntax(diff.node).as(TokenSyntax.self)?.tokenKind, .funcKeyword)
    }

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    try expectations(actual.findFirstDifference(baseline: expected))

    let matcher = try SubtreeMatcher("struct A { #^FUNC^#func f() { } }")
    try expectations(matcher.findFirstDifference(baseline: expected))
  }

  public func testDifferentTokenText() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    func expectations(_ diff: TreeDifference?, file: StaticString = #filePath, line: UInt = #line) throws {
      let diff = try XCTUnwrap(diff, file: file, line: line)
      XCTAssertEqual(diff.reason, .token)
      XCTAssertEqual(Syntax(diff.baseline).as(TokenSyntax.self)?.tokenKind, .identifier("f"))
      XCTAssertEqual(Syntax(diff.node).as(TokenSyntax.self)?.tokenKind, .identifier("g"))
    }

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("g")))
    try expectations(actual.findFirstDifference(baseline: expected))

    let matcher = try SubtreeMatcher("struct A { #^FUNC^#func g() { } }")
    try expectations(matcher.findFirstDifference(afterMarker: "FUNC", baseline: expected))
  }

  public func testDifferentTrivia() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f"), indent: 2))
    func expectations(_ diff: TreeDifference?, file: StaticString = #filePath, line: UInt = #line) throws {
      let diff = try XCTUnwrap(diff, file: file, line: line)
      XCTAssertEqual(diff.reason, .trivia)
      XCTAssertEqual(diff.baseline.leadingTrivia, .spaces(2))
      XCTAssertEqual(diff.node.leadingTrivia, [])
    }

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    XCTAssertNil(actual.findFirstDifference(baseline: expected))
    try expectations(actual.findFirstDifference(baseline: expected, includeTrivia: true))

    let matcher = try SubtreeMatcher("struct A {func f() { }}")
    try XCTAssertNil(matcher.findFirstDifference(baseline: expected))
    try expectations(matcher.findFirstDifference(baseline: expected, includeTrivia: true))
  }

  public func testDifferentPresence() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f"), body: SyntaxFactory.makeBlankCodeBlock()))
    func expectations(_ diff: TreeDifference?, file: StaticString = #filePath, line: UInt = #line) throws {
      let diff = try XCTUnwrap(diff, file: file, line: line)
      XCTAssertEqual(diff.reason, .presence)
      XCTAssertTrue(diff.baseline.isMissing)
      XCTAssertFalse(diff.node.isMissing)
    }

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    try expectations(actual.findFirstDifference(baseline: expected))

    let matcher = try SubtreeMatcher("struct A { func f() { } }")
    try expectations(matcher.findFirstDifference(baseline: expected))
  }

  public func testMissingNode() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f"), body: makeBody(statementCount: 1)))
    func expectations(_ diff: TreeDifference?, file: StaticString = #filePath, line: UInt = #line) throws {
      let diff = try XCTUnwrap(diff, file: file, line: line)
      XCTAssertEqual(diff.reason, .missingNode)
    }

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    try expectations(actual.findFirstDifference(baseline: expected))

    let matcher = try SubtreeMatcher("struct A { func f() { } }")
    try expectations(matcher.findFirstDifference(baseline: expected))
  }

  public func testAdditionalNode() throws {
    let expected = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    func expectations(_ diff: TreeDifference?, file: StaticString = #filePath, line: UInt = #line) throws {
      let diff = try XCTUnwrap(diff, file: file, line: line)
      XCTAssertEqual(diff.reason, .additionalNode)
    }

    let actual = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f"), body: makeBody(statementCount: 1)))
    try expectations(actual.findFirstDifference(baseline: expected))

    let matcher = try SubtreeMatcher("""
      struct A {
        func f() {
          0
        }
      }
      """)
    try expectations(matcher.findFirstDifference(baseline: expected))
  }

  public func testMultipleSubtreeMatches() throws {
    let expectedFunc = Syntax(makeFunc(identifier: SyntaxFactory.makeIdentifier("f")))
    let expectedBody = Syntax(makeBody())

    let matcher = try SubtreeMatcher("""
      struct A {
        #^FUNC^#
        let member = 1

        func f() #^BODY^#{
          0
        }
      }
      """)
    let funcDiff = try XCTUnwrap(matcher.findFirstDifference(afterMarker: "FUNC", baseline: expectedFunc))
    XCTAssertEqual(funcDiff.reason, .additionalNode)

    let bodyDiff = try XCTUnwrap(matcher.findFirstDifference(afterMarker: "BODY", baseline: expectedBody))
    XCTAssertEqual(bodyDiff.reason, .additionalNode)
  }

  /// Generates a `FunctionDeclSyntax` with the given `identifier`, `keyword`,
  /// and `body` with some optional leading indentation (which applied only to
  /// the start, not the entire body).
  private func makeFunc(identifier: TokenSyntax, keyword: TokenSyntax = SyntaxFactory.makeFuncKeyword(),
                        body: CodeBlockSyntax? = nil, indent: Int = 0) -> FunctionDeclSyntax {
    let funcBody: CodeBlockSyntax
    if let body {
      funcBody = body
    } else {
      funcBody = makeBody()
    }
    let emptySignature = SyntaxFactory.makeFunctionSignature(input: SyntaxFactory.makeParameterClause(leftParen: SyntaxFactory.makeLeftParenToken(),
                                                                                                      parameterList: SyntaxFactory.makeFunctionParameterList([]),
                                                                                                      rightParen: SyntaxFactory.makeRightParenToken()),
                                                             asyncOrReasyncKeyword: nil, throwsOrRethrowsKeyword: nil, output: nil)
    let fd = SyntaxFactory.makeFunctionDecl(attributes: nil, modifiers: nil,
                                            funcKeyword: keyword, identifier: identifier, genericParameterClause: nil,
                                            signature: emptySignature, genericWhereClause: nil, body: funcBody)
    if indent > 0 {
      return fd.withLeadingTrivia(.spaces(indent))
    }
    return fd
  }

  /// Creates a `CodeBlockSyntax` that consists of `statementCount` integer
  /// literals with increasing values. Ie. `makeBody(statementCount: 2)`
  /// generates:
  /// ```
  /// {
  ///   0
  ///   1
  /// }
  /// ```
  private func makeBody(statementCount: Int = 0) -> CodeBlockSyntax {
    var items = [CodeBlockItemSyntax]()
    for i in 0..<statementCount {
      let literal = SyntaxFactory.makeIntegerLiteralExpr(digits: SyntaxFactory.makeIntegerLiteral(String(i)))
      items.append(SyntaxFactory.makeCodeBlockItem(item: Syntax(literal), semicolon: nil, errorTokens: nil))
    }
    let block = SyntaxFactory.makeCodeBlockItemList(items)
    return SyntaxFactory.makeCodeBlock(leftBrace: SyntaxFactory.makeLeftBraceToken(),
                                       statements: block,
                                       rightBrace: SyntaxFactory.makeRightBraceToken())
  }
}
