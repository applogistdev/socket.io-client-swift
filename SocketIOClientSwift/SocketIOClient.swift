//
//  SocketIOClient.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 11/23/14.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

public final class SocketIOClient: NSObject, SocketEngineClient {
    fileprivate let emitQueue = DispatchQueue(label: "com.socketio.emitQueue", attributes: [])
    fileprivate let handleQueue: DispatchQueue!

    var clientDelegate:SocketIOClientDelegate?
    public let socketURL: String

    public fileprivate(set) var engine: SocketEngine?
    public fileprivate(set) var secure = false
    public fileprivate(set) var status = SocketIOClientStatus.notConnected
    
    public var nsp = "/"
    public var opts: [String: AnyObject]?
    public var reconnects = true
    public var reconnectWait = 10
    public var sid: String? {
        return engine?.sid
    }
    
    fileprivate let logType = "SocketIOClient"
    
    fileprivate var anyHandler: ((SocketAnyEvent) -> Void)?
    fileprivate var currentReconnectAttempt:Int! = 0
    fileprivate var handlers = ContiguousArray<SocketEventHandler>()
    fileprivate var connectParams: [String: AnyObject]?
    fileprivate var reconnectTimer: Timer?
    
    fileprivate let reconnectAttempts: Int!
    fileprivate var ackHandlers = SocketAckManager()
    fileprivate var currentAck = -1

    var waitingData = [SocketPacket]()
    
    /**
    Create a new SocketIOClient. opts can be omitted
    */
    public init(socketURL: String, opts: [String: AnyObject]? = nil) {
        if socketURL["https://"].matches().count != 0 {
            self.secure = true
        }
        
        var handledUrl = socketURL
        handledUrl = handledUrl["http://"] ~= ""
        handledUrl = handledUrl["https://"] ~= ""
        
        self.socketURL = handledUrl
        self.opts = opts
        
        if let connectParams = opts?["connectParams"] as? [String: AnyObject] {
            self.connectParams = connectParams
        }
        
        if let logger = opts?["logger"] as? SocketLogger {
            Logger = logger
        }
        
        if let log = opts?["log"] as? Bool {
            Logger.log = log
        }
        
        if let nsp = opts?["nsp"] as? String {
            self.nsp = nsp
        }
        
        if let reconnects = opts?["reconnects"] as? Bool {
            self.reconnects = reconnects
        }
        
        if let reconnectAttempts = opts?["reconnectAttempts"] as? Int {
            self.reconnectAttempts = reconnectAttempts
        } else {
            self.reconnectAttempts = -1
        }
        
        if let reconnectWait = opts?["reconnectWait"] as? Int {
            self.reconnectWait = abs(reconnectWait)
        }
        
        if let clientDelegate = opts?["clientDelegate"] as? SocketIOClientDelegate {
            self.clientDelegate = clientDelegate
        }
        
        if let handleQueue = opts?["handleQueue"] as? DispatchQueue {
            self.handleQueue = handleQueue
        } else {
            self.handleQueue = DispatchQueue.main
        }
        
        super.init()
    }
    
    deinit {
        Logger.log("Client is being deinit", type: logType)
    }
    
    fileprivate func addEngine() -> SocketEngine {
        Logger.log("Adding engine", type: logType)

        let newEngine = SocketEngine(client: self, opts: opts as NSDictionary?)

        engine = newEngine
        return newEngine
    }
    
    fileprivate func clearReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    /**
    Closes the socket. Only reopen the same socket if you know what you're doing.
    Will turn off automatic reconnects.
    Pass true to fast if you're closing from a background task
    */
    public func close() {
        Logger.log("Closing socket", type: logType)
        
        reconnects = false
        didDisconnect("Closed")
    }
    
    /**
    Connect to the server.
    */
    public func connect() {
        connect(timeoutAfter: 0, withTimeoutHandler: nil)
    }
    
    /**
    Connect to the server. If we aren't connected after timeoutAfter, call handler
    */
    public func connect(timeoutAfter: Int,
        withTimeoutHandler handler: (() -> Void)?) {
            assert(timeoutAfter >= 0, "Invalid timeout: \(timeoutAfter)")

            guard status != .connected else {
                return
            }

            if status == .closed {
                Logger.log("Warning! This socket was previously closed. This might be dangerous!",
                    type: logType)
            }
            
            status = SocketIOClientStatus.connecting
            addEngine().open(connectParams)
            
            guard timeoutAfter != 0 else {
                return
            }
            
            let time = DispatchTime.now() + Double(Int64(timeoutAfter) * Int64(NSEC_PER_SEC)) / Double(NSEC_PER_SEC)

            handleQueue.asyncAfter(deadline: time) {[weak self] in
                if let this = self, this.status != .connected {
                    this.status = .closed
                    this.engine?.close(true)
                    
                    handler?()
                }
            }
    }
    
    fileprivate func createOnAck(_ items: [AnyObject]) ->  OnAckCallback {
        currentAck += 1
        return {[weak self, ack = currentAck] timeout, callback in
            if let this = self {
                this.ackHandlers.addAck(ack, callback: callback)
                
                this.emitQueue.async {
                    this._emit(items, ack: ack)
                }
                
                if timeout != 0 {
                    
                    let time = DispatchTime.now() + Double(Int64(timeout) * Int64(NSEC_PER_SEC)) 
                    
                    DispatchQueue.main.asyncAfter(deadline: time) {[weak self] in
                        self?.ackHandlers.timeoutAck(ack)
                    }
                }
            }
        }
    }
    
    func didConnect() {
        Logger.log("Socket connected", type: logType)
        status = .connected
        currentReconnectAttempt = 0
        clearReconnectTimer()
        
        // Don't handle as internal because something crazy could happen where
        // we disconnect before it's handled
        handleEvent("connect", data: [], isInternalMessage: false)
    }
    
    func didDisconnect(_ reason: String) {
        guard status != .closed else {
            return
        }
        
        //Logger.log("Disconnected: %@", type: logType, args: reason)
        
        status = .closed
        reconnects = false
        
        // Make sure the engine is actually dead.
        engine?.close(true)
        handleEvent("disconnect", data: [reason as AnyObject], isInternalMessage: true)
    }
    
    /// error
    public func didError(_ reason: AnyObject) {
        Logger.error("%@", type: logType, args: reason)
        
        handleEvent("error", data: reason as? [AnyObject] ?? [reason],
            isInternalMessage: true)
    }
    
    /**
    Same as close
    */
    public func disconnect() {
        close()
    }
    
    /**
    Send a message to the server
    */
    public func emit(_ event: String, _ items: AnyObject...) {
        emit(event, withItems: items)
    }
    
    /**
    Same as emit, but meant for Objective-C
    */
    public func emit(_ event: String, withItems items: [AnyObject]) {
        guard status == .connected else {
            return
        }

        emitQueue.async {
            self._emit([event as AnyObject] + items)
        }
    }
    
    /**
    Sends a message to the server, requesting an ack. Use the onAck method of SocketAckHandler to add
    an ack.
    */
    public func emitWithAck(_ event: String, _ items: AnyObject...) -> OnAckCallback {
        return emitWithAck(event, withItems: items)
    }
    
    /**
    Same as emitWithAck, but for Objective-C
    */
    public func emitWithAck(_ event: String, withItems items: [AnyObject]) -> OnAckCallback {
        return createOnAck([event as AnyObject] + items)
    }
    
    fileprivate func _emit(_ data: [AnyObject], ack: Int? = nil) {
        guard status == .connected else {
            return
        }
        
        let packet = SocketPacket.packetFromEmit(data, id: ack ?? -1, nsp: nsp, ack: false)
        let str = packet.packetString
        
        //Logger.log("Emitting: %@", type: logType, args: str)
        
        if packet.type == .binaryEvent {
            engine?.send(str, withData: packet.binary)
        } else {
            engine?.send(str, withData: nil)
        }
    }
    
    // If the server wants to know that the client received data
    func emitAck(_ ack: Int, withItems items: [AnyObject]) {
        emitQueue.async {
            if self.status == .connected {
                let packet = SocketPacket.packetFromEmit(items, id: ack , nsp: self.nsp, ack: true)
                let str = packet.packetString
                
                //Logger.log("Emitting Ack: %@", type: self.logType, args: str)
                
                if packet.type == SocketPacket.PacketType.binaryAck {
                    self.engine?.send(str, withData: packet.binary)
                } else {
                    self.engine?.send(str, withData: nil)
                }
                
            }
        }
    }
    
    public func engineDidClose(_ reason: String) {
        waitingData.removeAll()
        
        if status == .closed || !reconnects {
            didDisconnect(reason)
        } else if status != .reconnecting {
            status = .reconnecting
            handleEvent("reconnect", data: [reason as AnyObject], isInternalMessage: true)
            tryReconnect()
        }
    }
    
    // Called when the socket gets an ack for something it sent
    func handleAck(_ ack: Int, data: AnyObject?) {
        //Logger.log("Handling ack: %@ with data: %@", type: logType, args: ack, data ?? "")
        
        ackHandlers.executeAck(ack,
            items: (data as? [AnyObject]) ?? (data != nil ? [data!] : []))
    }
    
    /**
    Causes an event to be handled. Only use if you know what you're doing.
    */
    public func handleEvent(_ event: String, data: [AnyObject], isInternalMessage: Bool,
        wantsAck ack: Int? = nil) {
            guard status == .connected || isInternalMessage else {
                return
            }
            
            //Logger.log("Handling event: %@ with data: %@", type: logType, args: event, data ?? "")
            
            if anyHandler != nil {
                handleQueue.async {
                    self.anyHandler?(SocketAnyEvent(event: event, items: data as NSArray?))
                }
            }
            
            for handler in handlers where handler.event == event {
                if let ack = ack {
                    handleQueue.async {
                        handler.executeCallback(data, withAck: ack, withSocket: self)
                    }
                } else {
                    handleQueue.async {
                        handler.executeCallback(data, withAck: ack, withSocket: self)
                    }
                }
            }
    }
    
    /**
    Leaves nsp and goes back to /
    */
    public func leaveNamespace() {
        if nsp != "/" {
            engine?.send("1\(nsp)", withData: nil)
            nsp = "/"
        }
    }
    
    /**
    Joins nsp if it is not /
    */
    public func joinNamespace() {
        Logger.log("Joining namespace", type: logType)
        
        if nsp != "/" {
            engine?.send("0\(nsp)", withData: nil)
        }
    }
    
    /**
    Joins namespace /
    */
    public func joinNamespace(_ namespace: String) {
        self.nsp = namespace
        joinNamespace()
    }
    
    /**
    Removes handler(s)
    */
    public func off(_ event: String) {
        //Logger.log("Removing handler for event: %@", type: logType, args: event)
        
        handlers = ContiguousArray(handlers.filter { $0.event != event })
    }
    
    /**
    Adds a handler for an event.
    */
    public func on(_ event: String, callback: @escaping NormalCallback) {
        //Logger.log("Adding handler for event: %@", type: logType, args: event)
        
        let handler = SocketEventHandler(event: event, callback: callback)
        handlers.append(handler)
    }
    
    /**
    Adds a single-use handler for an event.
    */
    public func once(_ event: String, callback: @escaping NormalCallback) {
        //Logger.log("Adding once handler for event: %@", type: logType, args: event)
        
        let id = UUID()
        
        let handler = SocketEventHandler(event: event, id: id) {[weak self] data, ack in
            guard let this = self else {return}
            this.handlers = ContiguousArray(this.handlers.filter {$0.id != id})
            callback(data, ack)
        }

        handlers.append(handler)
    }
    
    /**
    Removes all handlers.
    Can be used after disconnecting to break any potential remaining retain cycles.
    */
    public func removeAllHandlers() {
        handlers.removeAll(keepingCapacity: false)
    }
    
    /**
    Adds a handler that will be called on every event.
    */
    public func onAny(_ handler: @escaping (SocketAnyEvent) -> Void) {
        anyHandler = handler
    }
    
    /**
    Same as connect
    */
    public func open() {
        connect()
    }
    
    public func parseSocketMessage(_ msg: String) {
        handleQueue.async {
            SocketParser.parseSocketMessage(msg, socket: self)
        }
    }
    
    public func parseBinaryData(_ data: Data) {
        handleQueue.async {
            SocketParser.parseBinaryData(data, socket: self)
        }
    }
    
    /**
    Tries to reconnect to the server.
    */
    public func reconnect() {
        engine?.stopPolling()
        tryReconnect()
    }
    
    fileprivate func tryReconnect() {
        if reconnectTimer == nil {
            Logger.log("Starting reconnect", type: logType)
            
            status = .reconnecting
            
            DispatchQueue.main.async {
                self.reconnectTimer = Timer.scheduledTimer(timeInterval: Double(self.reconnectWait),
                    target: self, selector: #selector(SocketIOClient._tryReconnect), userInfo: nil, repeats: true)
            }
        }
    }

    @objc fileprivate func _tryReconnect() {
        if status == .connected {
            clearReconnectTimer()
            
            return
        }
        
        
        if reconnectAttempts != -1 && currentReconnectAttempt + 1 > reconnectAttempts || !reconnects {
            clearReconnectTimer()
            didDisconnect("Reconnect Failed")
            
            return
        }
        
        Logger.log("Trying to reconnect", type: logType)
        handleEvent("reconnectAttempt", data: [Int(reconnectAttempts - currentReconnectAttempt) as AnyObject],isInternalMessage: true)
        
        currentReconnectAttempt = currentReconnectAttempt + 1
        connect()
    }
    
    public func handleHttpRequest(_ request: URLRequest) {
        clientDelegate?.handleHttpRequest(request)
    }
    
    public func handleHttpResponse(_ response: URLResponse) {
        clientDelegate?.handleHttpResponse(response)
    }
}
