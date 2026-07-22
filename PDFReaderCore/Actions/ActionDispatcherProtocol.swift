import Foundation

public protocol ActionDispatching: AnyObject {
    func dispatch(_ action: ActionID)
}
