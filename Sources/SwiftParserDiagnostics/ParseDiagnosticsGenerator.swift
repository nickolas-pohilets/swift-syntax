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

import SwiftDiagnostics
@_spi(Diagnostics) import SwiftParser
@_spi(RawSyntax) import SwiftSyntax

fileprivate func getTokens(between first: TokenSyntax, and second: TokenSyntax) -> [TokenSyntax] {
  var first = first
  if first.presence == .missing {
    let nextPresentToken = first.nextToken(viewMode: .sourceAccurate)
    guard let nextPresentToken else {
      return []
    }
    first = nextPresentToken
  }
  precondition(first.presence == .present)

  var second = second
  if second.presence == .missing {
    let previousPresentToken = second.previousToken(viewMode: .sourceAccurate)
    guard let previousPresentToken else {
      return []
    }
    second = previousPresentToken
  }
  precondition(second.presence == .present)

  var tokens: [TokenSyntax] = []
  var currentToken = first

  while currentToken != second {
    tokens.append(currentToken)
    guard let nextToken = currentToken.nextToken(viewMode: .sourceAccurate) else {
      assertionFailure("second Token must occur after first Token")
      return tokens
    }
    currentToken = nextToken
  }
  tokens.append(second)
  return tokens
}

fileprivate extension TokenSyntax {
  /// Assuming this token is a `poundAvailableKeyword` or `poundUnavailableKeyword`
  /// returns the opposite keyword.
  var negatedAvailabilityKeyword: TokenSyntax {
    switch self.tokenKind {
    case .poundAvailableKeyword:
      return self.with(\.tokenKind, .poundUnavailableKeyword)
    case .poundUnavailableKeyword:
      return self.with(\.tokenKind, .poundAvailableKeyword)
    default:
      preconditionFailure("The availability token of an AvailabilityConditionSyntax should always be #available or #unavailable")
    }
  }
}

fileprivate extension DiagnosticSeverity {
  func matches(_ lexerErorSeverity: SwiftSyntax.TokenDiagnostic.Severity) -> Bool {
    switch (self, lexerErorSeverity) {
    case (.error, .error):
      return true
    case (.warning, .warning):
      return true
    default:
      return false
    }
  }
}

public class ParseDiagnosticsGenerator: SyntaxAnyVisitor {
  private var diagnostics: [Diagnostic] = []

  /// IDs of nodes for which we already generated diagnostics in a parent's visit
  /// method and that should thus not be visited.
  private var handledNodes: [SyntaxIdentifier] = []

  /// When set to `true`, no more diagnostics will be emitted.
  /// Useful to stop any diagnostics after a maximum nesting level overflow was detected.
  private var suppressRemainingDiagnostics: Bool = false

  private init() {
    super.init(viewMode: .all)
  }

  public static func diagnostics(
    for tree: some SyntaxProtocol
  ) -> [Diagnostic] {
    let diagProducer = ParseDiagnosticsGenerator()
    diagProducer.walk(tree)
    diagProducer.diagnostics.sort {
      if $0.position != $1.position {
        return $0.position < $1.position
      }

      // Emit children diagnostics before parent diagnostics.
      // This makes sure that for missing declarations with attributes, we emit diagnostics on the attribute before we complain about the missing declaration.
      if $0.node.hasParent($1.node) {
        return true
      } else if $1.node.hasParent($0.node) {
        return false
      } else {
        // If multiple tokens are missing at the same location, emit diagnostics about nodes that occur earlier in the tree first.
        return $0.node.id.indexInTree < $1.node.id.indexInTree
      }
    }
    return diagProducer.diagnostics
  }

  // MARK: - Private helper functions

  /// Produce a diagnostic.
  /// If `highlights` is `nil` the `node` will be highlighted.
  func addDiagnostic(
    _ node: some SyntaxProtocol,
    position: AbsolutePosition? = nil,
    _ message: DiagnosticMessage,
    highlights: [Syntax]? = nil,
    notes: [Note] = [],
    fixIts: [FixIt] = [],
    handledNodes: [SyntaxIdentifier] = []
  ) {
    let diagnostic = Diagnostic(node: Syntax(node), position: position, message: message, highlights: highlights, notes: notes, fixIts: fixIts)
    addDiagnostic(diagnostic, handledNodes: handledNodes)
  }

  /// Produce a diagnostic.
  func addDiagnostic(
    _ diagnostic: Diagnostic,
    handledNodes: [SyntaxIdentifier] = []
  ) {
    if suppressRemainingDiagnostics {
      return
    }
    diagnostics.removeAll(where: { handledNodes.contains($0.node.id) })
    diagnostics.append(diagnostic)
    self.handledNodes.append(contentsOf: handledNodes)
  }

  /// Whether the node should be skipped for diagnostic emission.
  /// Every visit method must check this at the beginning.
  func shouldSkip(_ node: some SyntaxProtocol) -> Bool {
    if !node.hasError && !node.hasWarning {
      return true
    }
    return handledNodes.contains(node.id)
  }

  /// Utility function to emit a diagnostic that removes a misplaced token and instead inserts an equivalent token at the corrected location.
  ///
  /// If `incorrectContainer` contains only tokens that satisfy `unexpectedTokenCondition`, emit a diagnostic with message `message` that marks this token as misplaced.
  /// If `correctTokens` contains missing tokens, also emit a Fix-It with message `fixIt` that marks the unexpected token as missing and instead inserts `correctTokens`.
  public func exchangeTokens(
    unexpected: UnexpectedNodesSyntax?,
    unexpectedTokenCondition: (TokenSyntax) -> Bool,
    correctTokens: [TokenSyntax?],
    message: (_ misplacedTokens: [TokenSyntax]) -> some DiagnosticMessage,
    moveFixIt: (_ misplacedTokens: [TokenSyntax]) -> FixItMessage,
    removeRedundantFixIt: (_ misplacedTokens: [TokenSyntax]) -> FixItMessage? = { _ in nil }
  ) {
    guard let incorrectContainer = unexpected,
      let misplacedTokens = incorrectContainer.onlyPresentTokens(satisfying: unexpectedTokenCondition)
    else {
      // If there are no unexpected nodes or the unexpected contain multiple tokens, don't emit a diagnostic.
      return
    }

    let correctTokens = correctTokens.compactMap({ $0 })

    // Ignore `correctTokens` that are already present.
    let correctAndMissingTokens = correctTokens.filter({ $0.isMissing })
    var changes: [FixIt.MultiNodeChange] = []
    if let misplacedToken = misplacedTokens.only, let correctToken = correctTokens.only,
      misplacedToken.nextToken(viewMode: .all) == correctToken || misplacedToken.previousToken(viewMode: .all) == correctToken,
      correctToken.isMissing
    {
      // We are exchanging two adjacent tokens, transfer the trivia from the incorrect token to the corrected token.
      changes += misplacedTokens.map { FixIt.MultiNodeChange.makeMissing($0, transferTrivia: false) }
      changes.append(
        FixIt.MultiNodeChange.makePresent(
          correctToken,
          // Transfer any existing trivia. If there is no trivia in the misplaced token, pass `nil` so that `makePresent` can add required trivia, if necessary.
          leadingTrivia: misplacedToken.leadingTrivia.isEmpty ? nil : misplacedToken.leadingTrivia,
          trailingTrivia: misplacedToken.trailingTrivia.isEmpty ? nil : misplacedToken.trailingTrivia
        )
      )
    } else {
      changes += misplacedTokens.map { FixIt.MultiNodeChange.makeMissing($0) }
      changes += correctAndMissingTokens.map { FixIt.MultiNodeChange.makePresent($0) }
    }
    var fixIts: [FixIt] = []
    if changes.count > 1 {
      // Only emit a Fix-It if we are moving a token, i.e. also making a token present.
      fixIts.append(FixIt(message: moveFixIt(misplacedTokens), changes: changes))
    } else if !correctTokens.isEmpty, let removeFixIt = removeRedundantFixIt(misplacedTokens) {
      fixIts.append(FixIt(message: removeFixIt, changes: changes))
    }

    addDiagnostic(incorrectContainer, message(misplacedTokens), fixIts: fixIts, handledNodes: [incorrectContainer.id] + correctAndMissingTokens.map(\.id))
  }

  /// If `unexpected` only contains a single token that satisfies `predicate`,
  /// emits a diagnostic with `message` that removes this token.
  public func removeToken(
    _ unexpected: UnexpectedNodesSyntax?,
    where predicate: (TokenSyntax) -> Bool,
    message: (TokenSyntax) -> some DiagnosticMessage
  ) {
    guard let unexpected = unexpected,
      let misplacedToken = unexpected.onlyPresentToken(where: predicate)
    else {
      // If there is no unexpected node or the unexpected doesn't have the
      // expected token, don't emit a diagnostic.
      return
    }
    let fixit = FixIt(
      message: RemoveNodesFixIt(unexpected),
      changes: .makeMissing(unexpected)
    )
    addDiagnostic(
      unexpected,
      message(misplacedToken),
      fixIts: [fixit],
      handledNodes: [unexpected.id]
    )
  }

  private func handleMisplacedEffectSpecifiersAfterArrow(effectSpecifiers: (some EffectSpecifiersSyntax)?, misplacedSpecifiers: UnexpectedNodesSyntax?) {
    exchangeTokens(
      unexpected: misplacedSpecifiers,
      unexpectedTokenCondition: { EffectSpecifier(token: $0) != nil },
      correctTokens: [effectSpecifiers?.throwsSpecifier, effectSpecifiers?.asyncSpecifier],
      message: { EffectsSpecifierAfterArrow(effectsSpecifiersAfterArrow: $0) },
      moveFixIt: { MoveTokensInFrontOfFixIt(movedTokens: $0, inFrontOf: .arrow) },
      removeRedundantFixIt: { RemoveRedundantFixIt(removeTokens: $0) }
    )
  }

  private func handleMisplacedEffectSpecifiers(effectSpecifiers: (some EffectSpecifiersSyntax)?, output: ReturnClauseSyntax?) {
    handleMisplacedEffectSpecifiersAfterArrow(effectSpecifiers: effectSpecifiers, misplacedSpecifiers: output?.unexpectedBetweenArrowAndReturnType)
    handleMisplacedEffectSpecifiersAfterArrow(effectSpecifiers: effectSpecifiers, misplacedSpecifiers: output?.unexpectedAfterReturnType)
  }

  private func handleEffectSpecifiers(_ node: some EffectSpecifiersSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    let specifierInfo = [
      (node.asyncSpecifier, { AsyncEffectSpecifier(token: $0) != nil }, StaticParserError.misspelledAsync),
      (node.throwsSpecifier, { ThrowsEffectSpecifier(token: $0) != nil }, StaticParserError.misspelledThrows),
    ]

    let unexpectedNodes = [node.unexpectedBeforeAsyncSpecifier, node.unexpectedBetweenAsyncSpecifierAndThrowsSpecifier, node.unexpectedAfterThrowsSpecifier]

    // Diagnostics that are emitted later silence previous diagnostics, so check
    // for the most contextual (and thus helpful) diagnostics last.

    for (specifier, isOfSameKind, misspelledError) in specifierInfo {
      guard let specifier = specifier else {
        continue
      }
      for unexpected in unexpectedNodes {
        exchangeTokens(
          unexpected: unexpected,
          unexpectedTokenCondition: isOfSameKind,
          correctTokens: [specifier],
          message: { _ in misspelledError },
          moveFixIt: { ReplaceTokensFixIt(replaceTokens: $0, replacements: [specifier]) },
          removeRedundantFixIt: { RemoveRedundantFixIt(removeTokens: $0) }
        )
      }
    }

    if let throwsSpecifier = node.throwsSpecifier {
      exchangeTokens(
        unexpected: node.unexpectedAfterThrowsSpecifier,
        unexpectedTokenCondition: { AsyncEffectSpecifier(token: $0) != nil },
        correctTokens: [node.asyncSpecifier],
        message: { AsyncMustPrecedeThrows(asyncKeywords: $0, throwsKeyword: throwsSpecifier) },
        moveFixIt: { MoveTokensInFrontOfFixIt(movedTokens: $0, inFrontOf: throwsSpecifier.tokenKind) },
        removeRedundantFixIt: { RemoveRedundantFixIt(removeTokens: $0) }
      )
    }

    for (specifier, isOfSameKind, _) in specifierInfo {
      guard let specifier = specifier else {
        continue
      }
      if specifier.isPresent {
        for case .some(let unexpected) in unexpectedNodes {
          for duplicateSpecifier in unexpected.presentTokens(satisfying: isOfSameKind) {
            addDiagnostic(
              duplicateSpecifier,
              DuplicateEffectSpecifiers(correctSpecifier: specifier, unexpectedSpecifier: duplicateSpecifier),
              notes: [Note(node: Syntax(specifier), message: EffectSpecifierDeclaredHere(specifier: specifier))],
              fixIts: [FixIt(message: RemoveRedundantFixIt(removeTokens: [duplicateSpecifier]), changes: [.makeMissing(duplicateSpecifier)])],
              handledNodes: [unexpected.id]
            )
          }
        }
      }
    }
    return .visitChildren
  }

  /// If `unexpectedBefore` only contains a single token with the same kind as `token`,
  /// `unexpectedBefore` has trailing trivia and `token` is missing, emit a diagnostic
  /// that `unexpectedBefore` must not be followed by whitespace.
  /// The Fix-It of that diagnostic removes the trailing trivia from `unexpectedBefore`.
  func handleExtraneousWhitespaceError(unexpectedBefore: UnexpectedNodesSyntax?, token: TokenSyntax) {
    if let unexpected = unexpectedBefore?.onlyPresentToken(where: { $0.tokenKind == token.tokenKind }),
      !unexpected.trailingTrivia.isEmpty,
      token.isMissing
    {
      let changes: [FixIt.MultiNodeChange] = [
        .makeMissing(unexpected, transferTrivia: false),  // don't transfer trivia because trivia is the issue here
        .makePresent(token, leadingTrivia: unexpected.leadingTrivia),
      ]
      if let nextToken = token.nextToken(viewMode: .all),
        nextToken.isMissing
      {
        // If the next token is missing, the problem here isn’t actually the
        // space after token but that the missing token should be added after
        // `token` without a space. Generate a diagnsotic for that.
        _ = handleMissingSyntax(
          nextToken,
          overridePosition: unexpected.endPositionBeforeTrailingTrivia,
          additionalChanges: changes,
          additionalHandledNodes: [unexpected.id, token.id]
        )
      } else {
        let fixIt = FixIt(
          message: .removeExtraneousWhitespace,
          changes: changes
        )
        addDiagnostic(
          token,
          position: unexpected.endPositionBeforeTrailingTrivia,
          ExtraneousWhitespace(tokenWithWhitespace: unexpected),
          fixIts: [fixIt],
          handledNodes: [token.id, unexpected.id]
        )
      }
    }
  }

  // MARK: - Generic diagnostic generation

  public override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    return .visitChildren
  }

  public override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.allSatisfy({ handledNodes.contains($0.id) }) {
      return .skipChildren
    }
    if node.hasMaximumNestingLevelOverflow {
      addDiagnostic(node, .maximumNestingLevelOverflow)
      suppressRemainingDiagnostics = true
      return .skipChildren
    }
    if let tryKeyword = node.onlyPresentToken(where: { $0.tokenKind == .keyword(.try) }),
      let nextToken = tryKeyword.nextToken(viewMode: .sourceAccurate),
      nextToken.tokenKind.isLexerClassifiedKeyword,
      !(node.parent?.is(TypeEffectSpecifiersSyntax.self) ?? false)
    {
      addDiagnostic(node, TryCannotBeUsed(nextToken: nextToken))
    } else if let semicolons = node.onlyPresentTokens(satisfying: { $0.tokenKind == .semicolon }) {
      addDiagnostic(
        node,
        .unexpectedSemicolon,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(semicolons), changes: semicolons.map { FixIt.MultiNodeChange.makeMissing($0) })
        ]
      )
    } else if let firstToken = node.first?.as(TokenSyntax.self),
      firstToken.tokenKind.isIdentifier == true,
      firstToken.presence == .present,
      let previousToken = node.previousToken(viewMode: .sourceAccurate),
      previousToken.tokenKind.isIdentifier,
      previousToken.parent?.is(DeclSyntax.self) == true || previousToken.parent?.is(IdentifierPatternSyntax.self) == true
    {
      // If multiple identifiers are used for a declaration name, offer to join them together.
      let tokens =
        node
        .prefix(while: {
          guard let token = $0.as(TokenSyntax.self) else {
            return false
          }
          return token.tokenKind.isIdentifier == true && token.presence == .present
        })
        .map({ $0.as(TokenSyntax.self)! })
      let joined = previousToken.text + tokens.map(\.text).joined()
      var fixIts: [FixIt] = [
        FixIt(
          message: .joinIdentifiers,
          changes: [
            FixIt.MultiNodeChange(
              .replace(
                oldNode: Syntax(previousToken),
                newNode: Syntax(TokenSyntax(.identifier(joined), trailingTrivia: tokens.last?.trailingTrivia ?? [], presence: .present))
              )
            ),
            .makeMissing(tokens),
          ]
        )
      ]
      if tokens.contains(where: { $0.text.first?.isUppercase == false }) {
        let joinedUsingCamelCase = previousToken.text + tokens.map({ $0.text.withFirstLetterUppercased() }).joined()
        fixIts.append(
          FixIt(
            message: .joinIdentifiersWithCamelCase,
            changes: [
              FixIt.MultiNodeChange(
                .replace(
                  oldNode: Syntax(previousToken),
                  newNode: Syntax(TokenSyntax(.identifier(joinedUsingCamelCase), trailingTrivia: tokens.last?.trailingTrivia ?? [], presence: .present))
                )
              ),
              .makeMissing(tokens),
            ]
          )
        )
      }
      addDiagnostic(node, SpaceSeparatedIdentifiersError(firstToken: previousToken, additionalTokens: tokens), fixIts: fixIts)
    } else {
      addDiagnostic(node, UnexpectedNodesError(unexpectedNodes: node), highlights: [Syntax(node)])
    }
    return .skipChildren
  }

  public override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(token) {
      return .skipChildren
    }

    if token.isMissing {
      handleMissingToken(token)
    } else {
      if let tokenDiagnostic = token.tokenDiagnostic {
        let message = tokenDiagnostic.diagnosticMessage(in: token)
        precondition(message.severity.matches(tokenDiagnostic.severity))
        self.addDiagnostic(
          token,
          position: token.position.advanced(by: Int(tokenDiagnostic.byteOffset)),
          message,
          fixIts: tokenDiagnostic.fixIts(in: token)
        )
      }
    }

    return .skipChildren
  }

  // MARK: - Specialized diagnostic generation

  public override func visit(_ node: ArrowExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    handleMisplacedEffectSpecifiersAfterArrow(effectSpecifiers: node.effectSpecifiers, misplacedSpecifiers: node.unexpectedAfterArrowToken)

    return .visitChildren
  }

  public override func visit(_ node: AccessorEffectSpecifiersSyntax) -> SyntaxVisitorContinueKind {
    return handleEffectSpecifiers(node)
  }

  public override func visit(_ node: AssociatedtypeDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    // Emit a custom diagnostic for an unexpected 'each' before an associatedtype
    // name.
    removeToken(
      node.unexpectedBetweenAssociatedtypeKeywordAndIdentifier,
      where: { $0.tokenKind == .keyword(.each) },
      message: { _ in .associatedTypeCannotUsePack }
    )
    // Emit a custom diagnostic for an unexpected '...' after an associatedtype
    // name.
    removeToken(
      node.unexpectedBetweenIdentifierAndInheritanceClause,
      where: { $0.tokenKind == .ellipsis },
      message: { _ in .associatedTypeCannotUsePack }
    )
    return .visitChildren
  }

  public override func visit(_ node: ArrayTypeSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if node.leftSquareBracket.isMissing && node.rightSquareBracket.isPresent {
      addDiagnostic(
        node.rightSquareBracket,
        .extraRightBracket,
        fixIts: [.init(message: InsertFixIt(tokenToBeInserted: node.leftSquareBracket), changes: .makePresent(node.leftSquareBracket))],
        handledNodes: [node.leftSquareBracket.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let argument = node.argument, argument.isMissingAllTokens {
      addDiagnostic(
        argument,
        MissingAttributeArgument(attributeName: node.attributeName),
        fixIts: [
          FixIt(message: .insertAttributeArguments, changes: .makePresent(argument))
        ],
        handledNodes: [argument.id]
      )
      return .visitChildren
    }
    return .visitChildren
  }

  public override func visit(_ node: AvailabilityArgumentSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let trailingComma = node.trailingComma {
      exchangeTokens(
        unexpected: node.unexpectedBetweenEntryAndTrailingComma,
        unexpectedTokenCondition: { $0.text == "||" },
        correctTokens: [node.trailingComma],
        message: { _ in .joinPlatformsUsingComma },
        moveFixIt: { ReplaceTokensFixIt(replaceTokens: $0, replacements: [trailingComma]) }
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: AvailabilityConditionSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let unexpectedAfterRightParen = node.unexpectedAfterRightParen,
      let (_, falseKeyword) = unexpectedAfterRightParen.twoPresentTokens(
        firstSatisfying: { $0.tokenKind == .binaryOperator("==") },
        secondSatisfying: { $0.tokenKind == .keyword(.false) }
      )
    {
      // Diagnose #available used as an expression
      let negatedAvailabilityKeyword = node.availabilityKeyword.negatedAvailabilityKeyword
      let negatedAvailability =
        node
        .with(\.availabilityKeyword, negatedAvailabilityKeyword)
        .with(\.unexpectedAfterRightParen, nil)
      addDiagnostic(
        unexpectedAfterRightParen,
        AvailabilityConditionAsExpression(availabilityToken: node.availabilityKeyword, negatedAvailabilityToken: negatedAvailabilityKeyword),
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(
              replaceTokens: getTokens(between: node.availabilityKeyword, and: falseKeyword),
              replacements: getTokens(between: negatedAvailability.availabilityKeyword, and: negatedAvailability.rightParen)
            ),
            changes: [
              .replace(oldNode: Syntax(node), newNode: Syntax(negatedAvailability))
            ]
          )
        ],
        handledNodes: [unexpectedAfterRightParen.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: AvailabilityVersionRestrictionSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let unexpected = node.unexpectedBetweenPlatformAndVersion,
      unexpected.onlyPresentToken(where: { $0.tokenKind == .binaryOperator(">=") }) != nil
    {
      addDiagnostic(
        unexpected,
        .versionComparisonNotNeeded,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(unexpected), changes: .makeMissing(unexpected))
        ],
        handledNodes: [unexpected.id]
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: CanImportExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let versionTuple = node.versionInfo?.versionTuple,
      let unexpectedVersionTuple = node.unexpectedBetweenVersionInfoAndRightParen
    {
      if versionTuple.major.isMissing {
        addDiagnostic(
          versionTuple,
          CannotParseVersionTuple(versionTuple: unexpectedVersionTuple),
          handledNodes: [versionTuple.id, unexpectedVersionTuple.id]
        )
      } else {
        addDiagnostic(
          unexpectedVersionTuple,
          .canImportWrongNumberOfParameter,
          handledNodes: [unexpectedVersionTuple.id]
        )
      }
    }

    return .visitChildren
  }

  public override func visit(_ node: CanImportVersionInfoSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if node.label.isMissing {
      addDiagnostic(
        node.label,
        .canImportWrongSecondParameterLabel,
        handledNodes: [node.label.id]
      )

      handledNodes.append(contentsOf: [node.unexpectedBetweenLabelAndColon?.id, node.colon.id, node.versionTuple.id].compactMap { $0 })
    }

    return .visitChildren
  }

  public override func visit(_ node: ConditionElementSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let trailingComma = node.trailingComma {
      exchangeTokens(
        unexpected: node.unexpectedBetweenConditionAndTrailingComma,
        unexpectedTokenCondition: { $0.text == "&&" || $0.tokenKind == .keyword(.where) },
        correctTokens: [node.trailingComma],
        message: { _ in .joinConditionsUsingComma },
        moveFixIt: { ReplaceTokensFixIt(replaceTokens: $0, replacements: [trailingComma]) }
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.statements.only?.item.is(EditorPlaceholderExprSyntax.self) == true {
      // Only emit a single diagnostic about the editor placeholder and none for the missing '{' and '}'.
      addDiagnostic(node, .editorPlaceholderInSourceFile, handledNodes: [node.id])
      return .skipChildren
    }
    return .visitChildren
  }

  public override func visit(_ node: ClosureSignatureSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    handleMisplacedEffectSpecifiers(effectSpecifiers: node.effectSpecifiers, output: node.output)
    return .visitChildren
  }

  public override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let semicolon = node.semicolon, semicolon.isMissing {
      if !node.item.hasError {
        // Only diagnose the missing semicolon if the item doesn't contain any errors.
        // If the item contains errors, the root cause is most likely something different and not the missing semicolon.
        let position = semicolon.previousToken(viewMode: .sourceAccurate)?.endPositionBeforeTrailingTrivia
        addDiagnostic(
          semicolon,
          position: position,
          .consecutiveStatementsOnSameLine,
          fixIts: [
            FixIt(message: .insertSemicolon, changes: .makePresent(semicolon))
          ],
          handledNodes: [semicolon.id]
        )
      } else {
        handledNodes.append(semicolon.id)
      }
    }
    if let semicolon = node.semicolon, semicolon.isPresent, node.item.isMissingAllTokens {
      addDiagnostic(
        node,
        .standaloneSemicolonStatement,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(semicolon), changes: .makeMissing(semicolon))
        ],
        handledNodes: [node.item.id]
      )
    }
    if let switchCase = node.unexpectedBeforeItem?.only?.as(SwitchCaseSyntax.self) {
      if switchCase.label.is(SwitchDefaultLabelSyntax.self) {
        addDiagnostic(node, .defaultOutsideOfSwitch)
      } else {
        addDiagnostic(node, .caseOutsideOfSwitchOrEnum)
      }
      return .skipChildren
    }
    return .visitChildren
  }

  public override func visit(_ node: FunctionEffectSpecifiersSyntax) -> SyntaxVisitorContinueKind {
    return handleEffectSpecifiers(node)
  }

  public override func visit(_ node: GenericRequirementSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let unexpected = node.unexpectedBetweenBodyAndTrailingComma,
      let token = unexpected.presentTokens(satisfying: { $0.tokenKind == .binaryOperator("&&") }).first,
      let trailingComma = node.trailingComma,
      trailingComma.isMissing,
      let previous = node.unexpectedBetweenBodyAndTrailingComma?.previousToken(viewMode: .sourceAccurate)
    {

      addDiagnostic(
        unexpected,
        .expectedCommaInWhereClause,
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(replaceTokens: [token], replacements: [.commaToken()]),
            changes: [
              .makeMissing(token),
              .makePresent(trailingComma),
              FixIt.MultiNodeChange(.replaceTrailingTrivia(token: previous, newTrivia: [])),
            ]
          )
        ],
        handledNodes: [unexpected.id, trailingComma.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let unexpected = node.unexpectedBetweenDeinitKeywordAndAsyncKeyword,
      let name = unexpected.presentTokens(satisfying: { $0.tokenKind.isIdentifier == true }).only?.as(TokenSyntax.self)
    {
      addDiagnostic(
        name,
        .deinitCannotHaveName,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(name), changes: .makeMissing(name))
        ],
        handledNodes: [name.id]
      )
    }
    if let unexpected = node.unexpectedBetweenDeinitKeywordAndAsyncKeyword,
      let params = unexpected.compactMap({ $0.as(ParameterClauseSyntax.self) }).only
    {
      addDiagnostic(
        params,
        .deinitCannotHaveParameters,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(params), changes: .makeMissing(params))
        ],
        handledNodes: [params.id]
      )
    }
    
    let throwsTokens: [TokenKind] = [
      .keyword(.throws),
      .keyword(.rethrows),
      .keyword(.try),
      .keyword(.throw),
    ]
    func asThrowingToken(_ syntax: Syntax) -> TokenSyntax? {
      guard let token = syntax.as(TokenSyntax.self) else { return nil }
      if token.isMissing { return nil }
      if throwsTokens.contains(token.tokenKind) { return token }
      return nil
    }
    
    let unexpectedThrows = (node.unexpectedBetweenDeinitKeywordAndAsyncKeyword?.compactMap(asThrowingToken) ?? []) + (node.unexpectedBetweenAsyncKeywordAndBody?.compactMap(asThrowingToken) ?? [])
    if let throwsKeyword = unexpectedThrows.first {
        addDiagnostic(
            throwsKeyword,
            .deinitCannotThrow,
            fixIts: [
                FixIt(message: RemoveNodesFixIt(unexpectedThrows), changes: .makeMissing(unexpectedThrows))
            ],
            handledNodes: unexpectedThrows.map(\.id)
        )
    }

    return .visitChildren
  }

  public override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.floatingDigits.isMissing,
      let (period, integerLiteral) = node.unexpectedAfterFloatingDigits?.twoPresentTokens(
        firstSatisfying: { $0.tokenKind == .period },
        secondSatisfying: { $0.tokenKind.isIntegerLiteral }
      )
    {
      addDiagnostic(
        node,
        InvalidFloatLiteralMissingLeadingZero(decimalDigits: integerLiteral),
        fixIts: [
          FixIt(
            message: InsertFixIt(tokenToBeInserted: .integerLiteral("0")),
            changes: [
              .makePresent(node.floatingDigits),
              .makeMissing(period),
              .makeMissing(integerLiteral),
            ]
          )
        ],
        handledNodes: [node.floatingDigits.id, period.id, integerLiteral.id]
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: ForInStmtSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    // Detect C-style for loops based on two semicolons which could not be parsed between the 'for' keyword and the '{'
    // This is mostly a proof-of-concept implementation to produce more complex diagnostics.
    if let unexpectedCondition = node.body.unexpectedBeforeLeftBrace,
      unexpectedCondition.presentTokens(withKind: .semicolon).count == 2
    {
      // FIXME: This is aweful. We should have a way to either get all children between two cursors in a syntax node or highlight a range from one node to another.
      addDiagnostic(
        node,
        .cStyleForLoop,
        highlights: ([
          Syntax(node.pattern),
          Syntax(node.unexpectedBetweenPatternAndTypeAnnotation),
          Syntax(node.typeAnnotation),
          Syntax(node.unexpectedBetweenTypeAnnotationAndInKeyword),
          Syntax(node.inKeyword),
          Syntax(node.unexpectedBetweenInKeywordAndSequenceExpr),
          Syntax(node.sequenceExpr),
          Syntax(node.unexpectedBetweenSequenceExprAndWhereClause),
          Syntax(node.whereClause),
          Syntax(node.unexpectedBetweenWhereClauseAndBody),
          Syntax(unexpectedCondition),
        ] as [Syntax?]).compactMap({ $0 }),
        handledNodes: [node.inKeyword.id, node.sequenceExpr.id, unexpectedCondition.id]
      )
    } else {  // If it's not a C-style for loop
      if node.sequenceExpr.is(MissingExprSyntax.self) {
        addDiagnostic(
          node.sequenceExpr,
          .expectedSequenceExpressionInForEachLoop,
          fixIts: [
            FixIt(
              message: InsertTokenFixIt(missingNodes: [Syntax(node.sequenceExpr)]),
              changes: [.makePresent(node.sequenceExpr)]
            )
          ],
          handledNodes: [node.sequenceExpr.id]
        )
      }
    }

    return .visitChildren
  }

  public override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    exchangeTokens(
      unexpected: node.unexpectedBetweenModifiersAndFirstName,
      unexpectedTokenCondition: { TypeSpecifier(token: $0) != nil },
      correctTokens: [node.type.as(AttributedTypeSyntax.self)?.specifier],
      message: { SpecifierOnParameterName(misplacedSpecifiers: $0) },
      moveFixIt: { MoveTokensInFrontOfTypeFixIt(movedTokens: $0) },
      removeRedundantFixIt: { RemoveRedundantFixIt(removeTokens: $0) }
    )
    return .visitChildren
  }

  public override func visit(_ node: FunctionSignatureSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    handleMisplacedEffectSpecifiers(effectSpecifiers: node.effectSpecifiers, output: node.output)
    return .visitChildren
  }

  public override func visit(_ node: FunctionTypeSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    handleMisplacedEffectSpecifiers(effectSpecifiers: node.effectSpecifiers, output: node.output)
    return .visitChildren
  }

  public override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    // Emit a custom diagnostic for an unexpected '...' after the type name.
    if node.each?.isPresent ?? false {
      removeToken(
        node.unexpectedBetweenNameAndColon,
        where: { $0.tokenKind == .ellipsis },
        message: { _ in .typeParameterPackEllipsis }
      )
    } else if let unexpected = node.unexpectedBetweenNameAndColon,
      let unexpectedEllipsis = unexpected.onlyPresentToken(where: { $0.tokenKind == .ellipsis }),
      let each = node.each
    {
      addDiagnostic(
        unexpected,
        .typeParameterPackEllipsis,
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(replaceTokens: [unexpectedEllipsis], replacements: [.keyword(.each)]),
            changes: [
              .makeMissing(unexpected),
              .makePresent(each, trailingTrivia: .space),
            ]
          )
        ],
        handledNodes: [unexpected.id, each.id]
      )
    }
    if let inheritedTypeName = node.inheritedType?.as(SimpleTypeIdentifierSyntax.self)?.name {
      exchangeTokens(
        unexpected: node.unexpectedBetweenColonAndInheritedType,
        unexpectedTokenCondition: { $0.tokenKind == .keyword(.class) },
        correctTokens: [inheritedTypeName],
        message: { _ in StaticParserError.classConstraintCanOnlyBeUsedInProtocol },
        moveFixIt: { ReplaceTokensFixIt(replaceTokens: $0, replacements: [inheritedTypeName]) }
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: IdentifierExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.identifier.isMissing, let unexpected = node.unexpectedBeforeIdentifier {
      if unexpected.first?.as(TokenSyntax.self)?.tokenKind == .pound {
        addDiagnostic(unexpected, UnknownDirectiveError(unexpected: unexpected), handledNodes: [unexpected.id, node.identifier.id])
      } else if let availability = unexpected.first?.as(AvailabilityConditionSyntax.self) {
        if let prefixOperatorExpr = node.parent?.as(PrefixOperatorExprSyntax.self),
          let operatorToken = prefixOperatorExpr.operatorToken,
          operatorToken.text == "!",
          let conditionElement = prefixOperatorExpr.parent?.as(ConditionElementSyntax.self)
        {
          // Diagnose !#available(...) and !#unavailable(...)

          let negatedAvailabilityKeyword = availability.availabilityKeyword.negatedAvailabilityKeyword
          let negatedCoditionElement = ConditionElementSyntax(
            condition: .availability(availability.with(\.availabilityKeyword, negatedAvailabilityKeyword)),
            trailingComma: conditionElement.trailingComma
          )
          addDiagnostic(
            unexpected,
            NegatedAvailabilityCondition(avaialabilityCondition: availability, negatedAvailabilityKeyword: negatedAvailabilityKeyword),
            fixIts: [
              FixIt(
                message: ReplaceTokensFixIt(replaceTokens: [operatorToken, availability.availabilityKeyword], replacements: [negatedAvailabilityKeyword]),
                changes: [
                  .replace(oldNode: Syntax(conditionElement), newNode: Syntax(negatedCoditionElement))
                ]
              )
            ],
            handledNodes: [unexpected.id, node.identifier.id]
          )
        } else {
          addDiagnostic(unexpected, AvailabilityConditionInExpression(availabilityCondition: availability), handledNodes: [unexpected.id, node.identifier.id])
        }
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
    for clause in node.clauses where clause.hasError {
      if let unexpectedBeforePoundKeyword = clause.unexpectedBeforePoundKeyword,
        clause.poundKeyword.tokenKind == .poundElseifKeyword,
        clause.poundKeyword.isMissing
      {
        let unexpectedTokens =
          unexpectedBeforePoundKeyword
          .suffix(2)
          .compactMap { $0.as(TokenSyntax.self) }
        var diagnosticMessage: DiagnosticMessage?

        if unexpectedTokens.map(\.tokenKind) == [.poundElseKeyword, .keyword(.if)] {
          diagnosticMessage = StaticParserError.unexpectedPoundElseSpaceIf
        } else if unexpectedTokens.first?.tokenKind == .pound, unexpectedTokens.last?.text == "elif" {
          diagnosticMessage = UnknownDirectiveError(unexpected: unexpectedBeforePoundKeyword)
        }

        if let diagnosticMessage = diagnosticMessage {
          addDiagnostic(
            unexpectedBeforePoundKeyword,
            diagnosticMessage,
            fixIts: [
              FixIt(
                message: ReplaceTokensFixIt(replaceTokens: unexpectedTokens, replacements: [clause.poundKeyword]),
                changes: [
                  .makeMissing(unexpectedBeforePoundKeyword, transferTrivia: false),
                  .makePresent(clause.poundKeyword, leadingTrivia: unexpectedBeforePoundKeyword.leadingTrivia),
                ]
              )
            ],
            handledNodes: [unexpectedBeforePoundKeyword.id, clause.poundKeyword.id]
          )
        }
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if node.conditions.count == 1,
      node.conditions.first?.as(ConditionElementSyntax.self)?.condition.is(MissingExprSyntax.self) == true,
      !node.body.leftBrace.isMissingAllTokens
    {
      addDiagnostic(node.conditions, MissingConditionInStatement(node: node), handledNodes: [node.conditions.id])
    }

    if let leftBrace = node.elseBody?.as(CodeBlockSyntax.self)?.leftBrace, leftBrace.isMissing {
      addDiagnostic(leftBrace, .expectedLeftBraceOrIfAfterElse, handledNodes: [leftBrace.id])
    }

    return .visitChildren
  }

  public override func visit(_ node: InitializerClauseSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let unexpected = node.unexpectedBeforeEqual,
      unexpected.first?.as(TokenSyntax.self)?.tokenKind == .binaryOperator("==")
    {
      addDiagnostic(
        unexpected,
        .expectedAssignmentInsteadOfComparisonOperator,
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(replaceTokens: [.binaryOperator("==")], replacements: [node.equal]),
            changes: [.makeMissing(unexpected), .makePresent(node.equal)]
          )
        ],
        handledNodes: [unexpected.id, node.equal.id]
      )
    }

    if node.equal.isMissing {
      exchangeTokens(
        unexpected: node.unexpectedBeforeEqual,
        unexpectedTokenCondition: { $0.tokenKind == .colon },
        correctTokens: [node.equal],
        message: { _ in StaticParserError.initializerInPattern },
        moveFixIt: { ReplaceTokensFixIt(replaceTokens: $0, replacements: [node.equal]) }
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let unexpectedName = node.signature.input.unexpectedBeforeLeftParen,
      let previous = unexpectedName.previousToken(viewMode: .sourceAccurate)
    {
      addDiagnostic(
        unexpectedName,
        .initializerCannotHaveName,
        fixIts: [
          FixIt(
            message: RemoveNodesFixIt(unexpectedName),
            changes: [
              .makeMissing(unexpectedName),
              FixIt.MultiNodeChange(.replaceTrailingTrivia(token: previous, newTrivia: [])),
            ]
          )
        ],
        handledNodes: [unexpectedName.id]
      )
    }

    if let unexpectedOutput = node.signature.unexpectedAfterOutput {
      addDiagnostic(
        unexpectedOutput,
        .initializerCannotHaveResultType,
        handledNodes: [unexpectedOutput.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    handleExtraneousWhitespaceError(
      unexpectedBefore: node.unexpectedBetweenModifiersAndPoundToken,
      token: node.poundToken
    )

    return .visitChildren
  }

  public override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    handleExtraneousWhitespaceError(
      unexpectedBefore: node.unexpectedBeforePoundToken,
      token: node.poundToken
    )

    return .visitChildren
  }

  public override func visit(_ node: MemberDeclListItemSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let semicolon = node.semicolon, semicolon.isMissing {
      if !node.decl.hasError {
        // Only diagnose the missing semicolon if the decl doesn't contain any errors.
        // If the decl contains errors, the root cause is most likely something different and not the missing semicolon.
        let position = semicolon.previousToken(viewMode: .sourceAccurate)?.endPositionBeforeTrailingTrivia
        addDiagnostic(
          semicolon,
          position: position,
          .consecutiveDeclarationsOnSameLine,
          fixIts: [
            FixIt(message: .insertSemicolon, changes: .makePresent(semicolon))
          ],
          handledNodes: [semicolon.id]
        )
      } else {
        handledNodes.append(semicolon.id)
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: MissingDeclSyntax) -> SyntaxVisitorContinueKind {
    return handleMissingSyntax(node, additionalHandledNodes: [node.placeholder.id])
  }

  public override func visit(_ node: MissingExprSyntax) -> SyntaxVisitorContinueKind {
    return handleMissingSyntax(node, additionalHandledNodes: [node.placeholder.id])
  }

  public override func visit(_ node: MissingPatternSyntax) -> SyntaxVisitorContinueKind {
    return handleMissingSyntax(node, additionalHandledNodes: [node.placeholder.id])
  }

  public override func visit(_ node: MissingStmtSyntax) -> SyntaxVisitorContinueKind {
    return handleMissingSyntax(node, additionalHandledNodes: [node.placeholder.id])
  }

  public override func visit(_ node: MissingSyntax) -> SyntaxVisitorContinueKind {
    return handleMissingSyntax(node, additionalHandledNodes: [node.placeholder.id])
  }

  public override func visit(_ node: MissingTypeSyntax) -> SyntaxVisitorContinueKind {
    return handleMissingSyntax(node, additionalHandledNodes: [node.placeholder.id])
  }

  override open func visit(_ node: OriginallyDefinedInArgumentsSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let token = node.unexpectedBetweenModuleLabelAndColon?.onlyPresentToken(where: { $0.tokenKind.isIdentifier }),
      node.moduleLabel.isMissing
    {
      addDiagnostic(
        node,
        MissingNodesError(missingNodes: [Syntax(node.moduleLabel)]),
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(
              replaceTokens: [token],
              replacements: [node.moduleLabel]
            ),
            changes: [
              FixIt.MultiNodeChange.makeMissing(token),
              FixIt.MultiNodeChange.makePresent(node.moduleLabel),
            ]
          )
        ],
        handledNodes: [node.moduleLabel.id, token.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if node.fixity.presence == .missing {
      addDiagnostic(
        node.fixity,
        .missingFixityInOperatorDeclaration,
        fixIts: [
          FixIt(message: InsertFixIt(tokenToBeInserted: .keyword(.prefix)), changes: .makePresent(node.fixity)),
          FixIt(
            message: InsertFixIt(tokenToBeInserted: .keyword(.infix)),
            changes: [FixIt.MultiNodeChange(.replace(oldNode: Syntax(node.fixity), newNode: Syntax(TokenSyntax(.keyword(.infix), presence: .present))))]
          ),
          FixIt(
            message: InsertFixIt(tokenToBeInserted: .keyword(.postfix)),
            changes: [FixIt.MultiNodeChange(.replace(oldNode: Syntax(node.fixity), newNode: Syntax(TokenSyntax(.keyword(.postfix), presence: .present))))]
          ),
        ],
        handledNodes: [node.fixity.id]
      )
    }

    if let unexpected = node.unexpectedAfterOperatorPrecedenceAndTypes,
      unexpected.contains(where: { $0.is(PrecedenceGroupAttributeListSyntax.self) }) == true
    {
      addDiagnostic(
        unexpected,
        .operatorShouldBeDeclaredWithoutBody,
        fixIts: [
          FixIt(message: .removeOperatorBody, changes: .makeMissing(unexpected))
        ],
        handledNodes: [unexpected.id]
      )
    }

    func diagnoseIdentifierInOperatorName(unexpected: UnexpectedNodesSyntax?, name: TokenSyntax) {
      guard let unexpected = unexpected else {
        return
      }
      let message: DiagnosticMessage?
      if let identifier = unexpected.onlyPresentToken(where: { $0.tokenKind.isIdentifier }) {
        message = IdentifierNotAllowedInOperatorName(identifier: identifier)
      } else if let tokens = unexpected.onlyPresentTokens(satisfying: { _ in true }) {
        message = TokensNotAllowedInOperatorName(tokens: tokens)
      } else {
        message = nil
      }
      if let message {
        let fixIts: [FixIt]
        if node.identifier.isPresent {
          fixIts = [FixIt(message: RemoveNodesFixIt(unexpected), changes: .makeMissing(unexpected))]
        } else {
          fixIts = []
        }
        addDiagnostic(unexpected, message, highlights: [Syntax(unexpected)], fixIts: fixIts, handledNodes: [unexpected.id, node.identifier.id])
      }
    }

    diagnoseIdentifierInOperatorName(unexpected: node.unexpectedBetweenOperatorKeywordAndIdentifier, name: node.identifier)
    diagnoseIdentifierInOperatorName(unexpected: node.unexpectedBetweenIdentifierAndOperatorPrecedenceAndTypes, name: node.identifier)

    return .visitChildren
  }

  public override func visit(_ node: PrecedenceGroupAssignmentSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let unexpected = node.unexpectedBetweenColonAndFlag ?? node.unexpectedAfterFlag, node.flag.isMissing {
      addDiagnostic(unexpected, .invalidFlagAfterPrecedenceGroupAssignment, handledNodes: [unexpected.id, node.flag.id])
    }
    return .visitChildren
  }

  public override func visit(_ node: PrecedenceGroupAssociativitySyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.value.isMissing {
      addDiagnostic(
        Syntax(node.unexpectedBetweenColonAndValue) ?? Syntax(node.value),
        .invalidPrecedenceGroupAssociativity,
        handledNodes: [node.unexpectedBetweenColonAndValue?.id, node.value.id].compactMap({ $0 })
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.expression != nil {
      exchangeTokens(
        unexpected: node.unexpectedBeforeReturnKeyword,
        unexpectedTokenCondition: { $0.tokenKind == .keyword(.try) },
        correctTokens: [node.expression?.as(TryExprSyntax.self)?.tryKeyword],
        message: { _ in .tryMustBePlacedOnReturnedExpr },
        moveFixIt: { MoveTokensAfterFixIt(movedTokens: $0, after: .keyword(.return)) }
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: SameTypeRequirementSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.equalityToken.isMissing && node.rightTypeIdentifier.isMissingAllTokens {
      addDiagnostic(
        node.equalityToken,
        .missingConformanceRequirement,
        handledNodes: [node.equalityToken.id, node.rightTypeIdentifier.id]
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let extraneous = node.unexpectedBetweenStatementsAndEOFToken, !extraneous.isEmpty {
      addDiagnostic(extraneous, ExtaneousCodeAtTopLevel(extraneousCode: extraneous), handledNodes: [extraneous.id])
    }
    return .visitChildren
  }

  public override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    // recover from Objective-C style literals
    if let atSign = node.unexpectedBetweenOpenDelimiterAndOpenQuote?.onlyPresentToken(where: { $0.tokenKind == .atSign }) {
      addDiagnostic(
        node,
        .stringLiteralAtSign,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(atSign), changes: .makeMissing(atSign))
        ],
        handledNodes: [atSign.id]
      )
    }
    if let singleQuote = node.unexpectedBetweenOpenDelimiterAndOpenQuote?.onlyPresentToken(where: { $0.tokenKind == .singleQuote }) {
      let fixIt = FixIt(
        message: ReplaceTokensFixIt(replaceTokens: [singleQuote], replacements: [node.openQuote]),
        changes: [
          .makeMissing(singleQuote, transferTrivia: false),
          .makePresent(node.openQuote, leadingTrivia: singleQuote.leadingTrivia),
          .makeMissing(node.unexpectedBetweenSegmentsAndCloseQuote, transferTrivia: false),
          .makePresent(node.closeQuote, trailingTrivia: node.unexpectedBetweenSegmentsAndCloseQuote?.trailingTrivia ?? []),
        ]
      )
      addDiagnostic(
        singleQuote,
        .singleQuoteStringLiteral,
        fixIts: [fixIt],
        handledNodes: [
          node.unexpectedBetweenOpenDelimiterAndOpenQuote?.id,
          node.openQuote.id,
          node.unexpectedBetweenSegmentsAndCloseQuote?.id,
          node.closeQuote.id,
        ].compactMap { $0 }
      )
    } else if node.openQuote.presence == .missing,
      node.unexpectedBetweenOpenDelimiterAndOpenQuote == nil,
      node.closeQuote.presence == .missing,
      node.unexpectedBetweenCloseQuoteAndCloseDelimiter == nil,
      !node.segments.isMissingAllTokens
    {
      addDiagnostic(
        node,
        MissingBothStringQuotesOfStringSegments(stringSegments: node.segments),
        fixIts: [
          FixIt(
            message: InsertTokenFixIt(missingNodes: [Syntax(node.openQuote), Syntax(node.closeQuote)]),
            changes: [
              .makePresent(node.openQuote),
              .makePresent(node.closeQuote),
            ]
          )
        ],
        handledNodes: [
          node.openQuote.id,
          node.closeQuote.id,
        ]
      )
    }

    for (diagnostic, handledNodes) in MultiLineStringLiteralIndentatinDiagnosticsGenerator.diagnose(node) {
      addDiagnostic(diagnostic, handledNodes: handledNodes)
    }
    if case .stringSegment(let segment) = node.segments.last {
      if let invalidContent = segment.unexpectedBeforeContent?.onlyPresentToken(where: { $0.trailingTrivia.contains(where: { $0.isBackslash }) }) {
        let fixIt = FixIt(
          message: .removeBackslash,
          changes: [
            .makePresent(segment.content),
            .makeMissing(invalidContent, transferTrivia: false),
          ]
        )
        addDiagnostic(
          invalidContent,
          position: invalidContent.endPositionBeforeTrailingTrivia,
          .escapedNewlineAtLatlineOfMultiLineStringLiteralNotAllowed,
          fixIts: [fixIt],
          handledNodes: [segment.id]
        )
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let unexpected = node.unexpectedBetweenSubscriptKeywordAndGenericParameterClause,
      let nameTokens = unexpected.onlyPresentTokens(satisfying: { !$0.tokenKind.isLexerClassifiedKeyword })
    {
      addDiagnostic(
        unexpected,
        .subscriptsCannotHaveNames,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(nameTokens), changes: .makeMissing(nameTokens))
        ],
        handledNodes: [unexpected.id]
      )
    }
    if let unexpected = node.indices.unexpectedBeforeLeftParen,
      let nameTokens = unexpected.onlyPresentTokens(satisfying: { !$0.tokenKind.isLexerClassifiedKeyword })
    {
      addDiagnostic(
        unexpected,
        .subscriptsCannotHaveNames,
        fixIts: [
          FixIt(message: RemoveNodesFixIt(nameTokens), changes: .makeMissing(nameTokens))
        ],
        handledNodes: [unexpected.id]
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if node.expression.is(MissingExprSyntax.self) && !node.cases.isEmpty {
      addDiagnostic(node.expression, MissingExpressionInStatement(node: node), handledNodes: [node.expression.id])
    }

    return .visitChildren
  }

  public override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.unknownAttr?.isMissingAllTokens != false && node.label.isMissingAllTokens {
      addDiagnostic(
        node.statements,
        .allStatmentsInSwitchMustBeCoveredByCase,
        fixIts: [
          FixIt(message: InsertTokenFixIt(missingNodes: [Syntax(node.label)]), changes: .makePresent(node.label))
        ],
        handledNodes: [node.label.id]
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: SwitchDefaultLabelSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if let unexpected = node.unexpectedBetweenDefaultKeywordAndColon, unexpected.first?.as(TokenSyntax.self)?.tokenKind == .keyword(.where) {
      addDiagnostic(unexpected, .defaultCannotBeUsedWithWhere, handledNodes: [unexpected.id])
    }
    return .visitChildren
  }

  public override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    exchangeTokens(
      unexpected: node.unexpectedBeforeThrowKeyword,
      unexpectedTokenCondition: { $0.tokenKind == .keyword(.try) },
      correctTokens: [node.expression.as(TryExprSyntax.self)?.tryKeyword],
      message: { _ in .tryMustBePlacedOnThrownExpr },
      moveFixIt: { MoveTokensAfterFixIt(movedTokens: $0, after: .keyword(.throw)) }
    )
    return .visitChildren
  }

  public override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.expression.is(MissingExprSyntax.self) {
      addDiagnostic(
        node.expression,
        .expectedExpressionAfterTry,
        fixIts: [
          FixIt(message: InsertTokenFixIt(missingNodes: [Syntax(node.expression)]), changes: .makePresent(node.expression))
        ],
        handledNodes: [node.expression.id]
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: TupleTypeElementSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    exchangeTokens(
      unexpected: node.unexpectedBetweenInOutAndName,
      unexpectedTokenCondition: { TypeSpecifier(token: $0) != nil },
      correctTokens: [node.type.as(AttributedTypeSyntax.self)?.specifier],
      message: { SpecifierOnParameterName(misplacedSpecifiers: $0) },
      moveFixIt: { MoveTokensInFrontOfTypeFixIt(movedTokens: $0) },
      removeRedundantFixIt: { RemoveRedundantFixIt(removeTokens: $0) }
    )
    return .visitChildren
  }

  public override func visit(_ node: TypeEffectSpecifiersSyntax) -> SyntaxVisitorContinueKind {
    return handleEffectSpecifiers(node)
  }

  public override func visit(_ node: TypeInheritanceClauseSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let unexpected = node.unexpectedBeforeColon,
      let leftParen = unexpected.onlyPresentToken(where: { $0.tokenKind == .leftParen })
    {

      var handledNodes: [SyntaxIdentifier] = [
        leftParen.id,
        node.colon.id,
      ]

      var changes: [FixIt.MultiNodeChange] = [
        .makePresent(node.colon),
        .makeMissing(unexpected),
      ]

      var replaceTokens = [leftParen]

      if let rightParen = node.unexpectedAfterInheritedTypeCollection?.onlyPresentToken(where: { $0.tokenKind == .rightParen }) {
        handledNodes += [rightParen.id]
        changes += [
          .makeMissing(rightParen)
        ]

        replaceTokens += [rightParen]
      }

      addDiagnostic(
        unexpected,
        .expectedColonClass,
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(replaceTokens: replaceTokens, replacements: [.colonToken()]),
            changes: changes
          )
        ],
        handledNodes: handledNodes
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: TypeInitializerClauseSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.equal.isMissing {
      exchangeTokens(
        unexpected: node.unexpectedBeforeEqual,
        unexpectedTokenCondition: { $0.tokenKind == .colon },
        correctTokens: [node.equal],
        message: { _ in MissingNodesError(missingNodes: [Syntax(node.equal)]) },
        moveFixIt: { ReplaceTokensFixIt(replaceTokens: $0, replacements: [node.equal]) }
      )
    }
    return .visitChildren
  }

  public override func visit(_ node: UnavailableFromAsyncArgumentsSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let token = node.unexpectedBetweenMessageLabelAndColon?.onlyPresentToken(where: { $0.tokenKind.isIdentifier }),
      token.isPresent,
      node.messageLabel.isMissing
    {
      addDiagnostic(
        node,
        MissingNodesError(missingNodes: [Syntax(node.messageLabel)]),
        fixIts: [
          FixIt(
            message: ReplaceTokensFixIt(
              replaceTokens: [token],
              replacements: [node.messageLabel]
            ),
            changes: [
              FixIt.MultiNodeChange.makeMissing(token),
              FixIt.MultiNodeChange.makePresent(node.messageLabel),
            ]
          )
        ],
        handledNodes: [node.messageLabel.id, token.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }
    if node.colonMark.isMissing {
      if let siblings = node.parent?.children(viewMode: .all),
        let nextSibling = siblings[siblings.index(after: node.index)...].first,
        nextSibling.is(MissingExprSyntax.self)
      {
        addDiagnostic(
          node.colonMark,
          .missingColonAndExprInTernaryExpr,
          fixIts: [
            FixIt(
              message: InsertTokenFixIt(missingNodes: [Syntax(node.colonMark), Syntax(nextSibling)]),
              changes: [
                .makePresent(node.colonMark),
                .makePresent(nextSibling),
              ]
            )
          ],
          handledNodes: [node.colonMark.id, nextSibling.id]
        )
      } else {
        addDiagnostic(
          node.colonMark,
          .missingColonInTernaryExpr,
          fixIts: [
            FixIt(message: InsertTokenFixIt(missingNodes: [Syntax(node.colonMark)]), changes: .makePresent(node.colonMark))
          ],
          handledNodes: [node.colonMark.id]
        )
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let modifiers = node.modifiers, modifiers.hasError {
      for modifier in modifiers {
        guard let detail = modifier.detail else {
          continue
        }

        let unexpectedTokens: [TokenSyntax] = [detail.unexpectedBetweenLeftParenAndDetail, detail.unexpectedBetweenDetailAndRightParen]
          .compactMap { $0?.tokens(viewMode: .sourceAccurate) }
          .flatMap { $0 }

        // If there is no unexpected tokens it means we miss a paren or set keyword.
        // So we just skip the handling here
        guard let firstUnexpected = unexpectedTokens.first else {
          continue
        }

        let fixItMessage: ParserFixIt

        if detail.detail.presence == .missing {
          fixItMessage = ReplaceTokensFixIt(replaceTokens: unexpectedTokens, replacements: [detail.detail])
        } else {
          fixItMessage = RemoveNodesFixIt(unexpectedTokens)
        }

        addDiagnostic(
          firstUnexpected,
          MissingNodesError(missingNodes: [Syntax(detail.detail)]),
          fixIts: [
            FixIt(
              message: fixItMessage,
              changes: [
                FixIt.MultiNodeChange.makePresent(detail.detail)
              ] + unexpectedTokens.map { FixIt.MultiNodeChange.makeMissing($0) }
            )
          ],
          handledNodes: [detail.id] + unexpectedTokens.map(\.id)
        )
      }
    }

    let missingTries = node.bindings.compactMap({
      return $0.initializer?.value.as(TryExprSyntax.self)?.tryKeyword
    })
    exchangeTokens(
      unexpected: node.unexpectedBetweenModifiersAndBindingKeyword,
      unexpectedTokenCondition: { $0.tokenKind == .keyword(.try) },
      correctTokens: missingTries,
      message: { _ in .tryOnInitialValueExpression },
      moveFixIt: { MoveTokensAfterFixIt(movedTokens: $0, after: .equal) },
      removeRedundantFixIt: { RemoveRedundantFixIt(removeTokens: $0) }
    )
    return .visitChildren
  }

  public override func visit(_ node: VersionTupleSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if let trailingComponents = node.unexpectedAfterComponents,
      let components = node.components
    {
      addDiagnostic(
        trailingComponents,
        TrailingVersionAreIgnored(major: node.major, components: components),
        handledNodes: [trailingComponents.id]
      )
    }

    return .visitChildren
  }

  public override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
    if shouldSkip(node) {
      return .skipChildren
    }

    if node.conditions.count == 1,
      node.conditions.first?.as(ConditionElementSyntax.self)?.condition.is(MissingExprSyntax.self) == true,
      !node.body.leftBrace.isMissingAllTokens
    {
      addDiagnostic(node.conditions, MissingConditionInStatement(node: node), handledNodes: [node.conditions.id])
    }

    return .visitChildren
  }

  //==========================================================================//
  // IMPORTANT: If you are tempted to add a `visit` method here, please       //
  // insert it in alphabetical order above                                    //
  //==========================================================================//
}
