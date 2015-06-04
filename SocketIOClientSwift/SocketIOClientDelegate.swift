import Foundation

@objc public protocol SocketIOClientDelegate {
    func handleHttpRequest(request:NSURLRequest)
    func handleHttpResponse(response:NSURLResponse)
}