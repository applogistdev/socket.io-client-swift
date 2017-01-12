import Foundation

@objc public protocol SocketIOClientDelegate {
    func handleHttpRequest(request:URLRequest)
    func handleHttpResponse(response:URLResponse)
}
