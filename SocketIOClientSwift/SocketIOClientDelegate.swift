import Foundation

@objc public protocol SocketIOClientDelegate {
    func handleHttpRequest(_ request:URLRequest)
    func handleHttpResponse(_ response:URLResponse)
}
