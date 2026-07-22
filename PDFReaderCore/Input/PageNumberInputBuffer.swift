import Foundation

public enum PageNumberInputError: Error, Equatable, Sendable {
    case empty
    case zeroIsNotAPage
    case numericOverflow
    case documentHasNoPages
    case outOfRange(requested: Int, maximum: Int)
}

public struct PageNumberInputBuffer: Equatable, Sendable {
    public private(set) var digits: String

    public init(digits: String = "") {
        precondition(digits.allSatisfy { $0.isASCII && $0.isNumber })
        self.digits = digits
    }

    @discardableResult
    public mutating func append(_ token: KeyToken) -> Bool {
        guard let digit = token.asciiDecimalDigit else { return false }
        digits.append(digit)
        return true
    }

    @discardableResult
    public mutating func append(_ replay: SemanticKeyReplay) -> Bool {
        guard replay.targetContext == .pagePrompt,
              replay.tokenClass == .decimalDigit
        else {
            return false
        }
        return append(replay.token)
    }

    public func resolve(maximumPageCount: Int) -> Result<Int, PageNumberInputError> {
        guard !digits.isEmpty else { return .failure(.empty) }
        guard maximumPageCount > 0 else { return .failure(.documentHasNoPages) }
        guard let page = Int(digits) else { return .failure(.numericOverflow) }
        guard page > 0 else { return .failure(.zeroIsNotAPage) }
        guard page <= maximumPageCount else {
            return .failure(.outOfRange(requested: page, maximum: maximumPageCount))
        }
        return .success(page)
    }

    public mutating func clear() {
        digits.removeAll(keepingCapacity: true)
    }
}
