//
//  SocketEngine.swift
//  Socket.IO-Client-Swift
//
//  Created by Erik Little on 3/3/15.
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

public final class SocketEngine: NSObject, WebSocketDelegate {
    fileprivate typealias Probe = (msg: String, type: PacketType, data: [Data]?)
    fileprivate typealias ProbeWaitQueue = [Probe]

    fileprivate let allowedCharacterSet = CharacterSet(charactersIn: "!*'();:@&=+$,/?%#[]\" {}").inverted
    fileprivate let emitQueue = DispatchQueue(label:"com.socketio.engineEmitQueue")
    fileprivate let handleQueue = DispatchQueue(label:"com.socketio.engineHandleQueue")
    fileprivate let logType = "SocketEngine"
    fileprivate let parseQueue = DispatchQueue(label:"com.socketio.engineParseQueue")
    fileprivate let session: URLSession!
    fileprivate let workQueue = OperationQueue()

    fileprivate var closed = false
    fileprivate var extraHeaders: [String: String]?
    fileprivate var fastUpgrade = false
    fileprivate var forcePolling = false
    fileprivate var forceWebsockets = false
    fileprivate var invalidated = false
    fileprivate var pingInterval: Double?
    fileprivate var pingTimer: Timer?
    fileprivate var pingTimeout = 0.0 {
        didSet {
            pongsMissedMax = Int(pingTimeout / (pingInterval ?? 25))
        }
    }
    fileprivate var pongsMissed = 0
    fileprivate var pongsMissedMax = 0
    fileprivate var postWait = [String]()
    fileprivate var probing = false
    fileprivate var probeWait = ProbeWaitQueue()
    fileprivate var waitingForPoll = false
    fileprivate var waitingForPost = false
    fileprivate var websocketConnected = false

    fileprivate(set) var connected = false
    fileprivate(set) var polling = true
    fileprivate(set) var websocket = false

    weak var client: SocketEngineClient?
    var cookies: [HTTPCookie]?
    var sid = ""
    var socketPath = ""
    var urlPolling = ""
    var urlWebSocket = ""

    var ws: WebSocket?
    
    @objc public enum PacketType: Int {
        case open, close, ping, pong, message, upgrade, noop

        init?(str: String) {
            if let value = Int(str), let raw = PacketType(rawValue: value) {
                self = raw
            } else {
                return nil
            }
        }
    }

    public init(client: SocketEngineClient, sessionDelegate: URLSessionDelegate?) {
        self.client = client
        self.session = URLSession(configuration: .default,delegate: sessionDelegate, delegateQueue: workQueue)
    }

    public convenience init(client: SocketEngineClient, opts: NSDictionary?) {
        self.init(client: client, sessionDelegate: opts?["sessionDelegate"] as? URLSessionDelegate)
        forceWebsockets = opts?["forceWebsockets"] as? Bool ?? false
        forcePolling = opts?["forcePolling"] as? Bool ?? false
        cookies = opts?["cookies"] as? [HTTPCookie]
        socketPath = opts?["path"] as? String ?? ""
        extraHeaders = opts?["extraHeaders"] as? [String: String]
    }

    deinit {
        
        Logger.log("Engine is being deinit", type: logType)
        closed = true
        stopPolling()
    }
    
    fileprivate func checkIfMessageIsBase64Binary(_ message: String) {
        if message.hasPrefix("b4") {
            var msg = message
            // binary in base64 string
            msg.removeSubrange(message.startIndex ..< message.index(message.startIndex, offsetBy: 2))
            
            if let data = Data(base64Encoded: msg,options: .ignoreUnknownCharacters) {
                    client?.parseBinaryData(data)
            }
        }
    }

    public func close(_ fast: Bool) {
        Logger.log("Engine is being closed. Fast: %@", type: logType, args: fast as AnyObject)

        pingTimer?.invalidate()
        closed = true

        ws?.disconnect()

        if fast || polling {
            write("", withType: PacketType.close, withData: nil)
            client?.engineDidClose("Disconnect")
        }

        stopPolling()
    }

    fileprivate func createBinaryDataForSend(_ data: Data) -> Either<Data, String> {
        if websocket {
            var byteArray = [UInt8](repeating: 0x0, count: 1)
            byteArray[0] = 4
            var mutData = Data(bytes: &byteArray, count: 1)

            mutData.append(data)

            return .left(mutData)
        } else {
            var str = "b4"
            str += data.base64EncodedString(options: .lineLength64Characters)

            return .right(str)
        }
    }
    
    fileprivate func createURLs(_ params: [String: AnyObject]?) -> (String, String) {
        if client == nil {
            return ("", "")
        }

        let path = socketPath == "" ? "/socket.io" : socketPath
        let url = "\(client!.socketURL)\(path)/?transport="
        var urlPolling: String
        var urlWebSocket: String

        if client!.secure {
            urlPolling = "https://" + url + "polling"
            urlWebSocket = "wss://" + url + "websocket"
        } else {
            urlPolling = "http://" + url + "polling"
            urlWebSocket = "ws://" + url + "websocket"
        }

        if params != nil {
            for (key, value) in params! {
                let keyEsc = key.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)
                //let keyEsc = key.stringByAddingPercentEncodingWithAllowedCharacters(allowedCharacterSet)!
                urlPolling += "&\(keyEsc)="
                urlWebSocket += "&\(keyEsc)="

                if value is String {
                    let valueEsc = (value as! String).addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)
                    urlPolling += "\(valueEsc)"
                    urlWebSocket += "\(valueEsc)"
                } else {
                    urlPolling += "\(value)"
                    urlWebSocket += "\(value)"
                }
            }
        }

        return (urlPolling, urlWebSocket)
    }

    fileprivate func createWebsocketAndConnect(_ connect: Bool) {
        let wsUrl = urlWebSocket + (sid == "" ? "" : "&sid=\(sid)")
        
        ws = WebSocket(url: URL(string: wsUrl)!)
        
        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            for (key, value) in headers {
                ws?.headers[key] = value
            }
        }
        
        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                ws?.headers[headerName] = value
            }
        }
        
        ws?.queue = handleQueue
        ws?.delegate = self

        if connect {
            ws?.connect()
        }
    }

    fileprivate func doFastUpgrade() {
        if waitingForPoll {
            Logger.error("Outstanding poll when switched to WebSockets, we'll probably disconnect soon. You should report this.", type: logType)
        }

        sendWebSocketMessage("", withType: .upgrade, datas: nil)
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    fileprivate func doPoll() {
        if websocket || waitingForPoll || !connected || closed {
            return
        }

        waitingForPoll = true
        let req = NSMutableURLRequest(url: URL(string: urlPolling + "&sid=\(sid)&b64=1")!)

        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            req.allHTTPHeaderFields = headers
        }
        
        if extraHeaders != nil {
            for (headerName, value) in extraHeaders! {
                req.setValue(value, forHTTPHeaderField: headerName)
            }
        }
        
        doLongPoll(req)
    }
    
    fileprivate func doRequest(_ req: NSMutableURLRequest,withCallback callback: @escaping (Data?, URLResponse?, Error?) -> Void) {
            if !polling || closed || invalidated {
                return
            }
        
            client?.handleHttpRequest(req as URLRequest)
        
            Logger.log("Doing polling request", type: logType)

            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session.dataTask(with: req as URLRequest, completionHandler: callback).resume()
    }

    fileprivate func doLongPoll(_ req: NSMutableURLRequest) {
        doRequest(req) {[weak self] data, res, err in
            if let this = self {
                if err != nil || data == nil {
                    if this.polling {
                        this.handlePollingFailed(err?.localizedDescription ?? "Error")
                    } else {
                        Logger.error(err?.localizedDescription ?? "Error", type: this.logType)
                    }
                    return
                }
                
                if res != nil {
                    this.client?.handleHttpResponse(res!);
                }
                
                Logger.log("Got polling response", type: this.logType)
                
                if let str = String(data: data!, encoding: String.Encoding.utf8)  {
                    this.parseQueue.async(execute: {[weak this] in
                        this?.parsePollingMessage(str)
                    })
                }
                
                this.waitingForPoll = false
                
                if this.fastUpgrade {
                    this.doFastUpgrade()
                } else if !this.closed && this.polling {
                    this.doPoll()
                }
            }
        }
    }

    fileprivate func flushProbeWait() {
        Logger.log("Flushing probe wait", type: logType)

        emitQueue.async(execute: {[weak self] in
            if let this = self {
                for waiter in this.probeWait {
                    this.write(waiter.msg, withType: waiter.type, withData: waiter.data)
                }
                
                this.probeWait.removeAll(keepingCapacity: false)
                
                if this.postWait.count != 0 {
                    this.flushWaitingForPostToWebSocket()
                }
            }
        })
    }

    fileprivate func flushWaitingForPost() {
        if postWait.count == 0 || !connected {
            return
        } else if websocket {
            flushWaitingForPostToWebSocket()
            return
        }

        var postStr = ""

        for packet in postWait {
            let len = packet.characters.count

            postStr += "\(len):\(packet)"
        }

        postWait.removeAll(keepingCapacity: false)

        let req = NSMutableURLRequest(url: URL(string: urlPolling + "&sid=\(sid)")!)

        if let cookies = cookies {
            let headers = HTTPCookie.requestHeaderFields(with: cookies)
            req.allHTTPHeaderFields = headers
        }

        req.httpMethod = "POST"
        req.setValue("text/plain; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let postData = postStr.data(using: String.Encoding.utf8,allowLossyConversion: false)!

        req.httpBody = postData
        req.setValue(String(postData.count), forHTTPHeaderField: "Content-Length")

        client?.handleHttpRequest(req as URLRequest);
        
        waitingForPost = true

        Logger.log("POSTing: %@", type: logType, args: postStr as AnyObject)

        doRequest(req) {[weak self] data, res, err in
            if let this = self {
                if err != nil && this.polling {
                    this.handlePollingFailed(err?.localizedDescription ?? "Error")
                    return
                } else if err != nil {
                    Logger.error(err?.localizedDescription ?? "Error", type: this.logType)
                    return
                }
                
                if res != nil {
                    this.client?.handleHttpResponse(res!);
                }

                this.waitingForPost = false

                this.emitQueue.async {[weak this] in
                    if !(this?.fastUpgrade ?? true) {
                        this?.flushWaitingForPost()
                        this?.doPoll()
                    }
                }
            }
        }
    }

    // We had packets waiting for send when we upgraded
    // Send them raw
    fileprivate func flushWaitingForPostToWebSocket() {
        guard let ws = self.ws else {return}
        
        for msg in postWait {
            ws.writeString(msg)
        }

        postWait.removeAll(keepingCapacity: true)
    }

    fileprivate func handleClose() {
        if let client = client, polling == true {
            client.engineDidClose("Disconnect")
        }
    }

    fileprivate func handleMessage(_ message: String) {
        client?.parseSocketMessage(message)
    }

    fileprivate func handleNOOP() {
        doPoll()
    }

    fileprivate func handleOpen(_ openData: String) {
        let mesData = openData.data(using: String.Encoding.utf8, allowLossyConversion: false)!
        do {
            let json = try JSONSerialization.jsonObject(with: mesData,options: .allowFragments) as? NSDictionary
            if let sid = json?["sid"] as? String {
                let upgradeWs: Bool

                self.sid = sid
                connected = true
                
                if let upgrades = json?["upgrades"] as? [String] {
                    upgradeWs = upgrades.filter {$0 == "websocket"}.count != 0
                } else {
                    upgradeWs = false
                }
                
                if let pingInterval = json?["pingInterval"] as? Double, let pingTimeout = json?["pingTimeout"] as? Double {
                    self.pingInterval = pingInterval / 1000.0
                    self.pingTimeout = pingTimeout / 1000.0
                }
                
                if !forcePolling && !forceWebsockets && upgradeWs {
                    createWebsocketAndConnect(true)
                }
            }
        } catch {
            Logger.error("Error parsing open packet", type: logType)
            return
        }

        startPingTimer()

        if !forceWebsockets {
            doPoll()
        }
    }

    fileprivate func handlePong(_ pongMessage: String) {
        pongsMissed = 0

        // We should upgrade
        if pongMessage == "3probe" {
            upgradeTransport()
        }
    }

    // A poll failed, tell the client about it
    fileprivate func handlePollingFailed(_ reason: String) {
        connected = false
        ws?.disconnect()
        pingTimer?.invalidate()
        waitingForPoll = false
        waitingForPost = false

        if !closed {
            client?.didError(reason as AnyObject)
            client?.engineDidClose(reason)
        }
    }

    public func open(_ opts: [String: AnyObject]? = nil) {
        if connected {
            Logger.error("Tried to open while connected", type: logType)
            client?.didError("Tried to open while connected" as AnyObject)
            
            return
        }

        Logger.log("Starting engine", type: logType)
        Logger.log("Handshaking", type: logType)

        closed = false

        (urlPolling, urlWebSocket) = createURLs(opts)

        if forceWebsockets {
            polling = false
            websocket = true
            createWebsocketAndConnect(true)
            return
        }

        let reqPolling = NSMutableURLRequest(url: URL(string: urlPolling + "&b64=1")!)

        if cookies != nil {
            let headers = HTTPCookie.requestHeaderFields(with: cookies!)
            reqPolling.allHTTPHeaderFields = headers
        }
 
        if let extraHeaders = extraHeaders {
            for (headerName, value) in extraHeaders {
                reqPolling.setValue(value, forHTTPHeaderField: headerName)
            }
        }
        
        doLongPoll(reqPolling)
    }

    fileprivate func parsePollingMessage(_ str: String) {
        guard str.characters.count != 1 else {
            return
        }
        
        var reader = SocketStringReader(message: str)
        
        while reader.hasNext {
            if let n = Int(reader.readUntilStringOccurence(":")) {
                let str = reader.read(n)
                
                handleQueue.async {
                    self.parseEngineMessage(str, fromPolling: true)
                }
            } else {
                handleQueue.async {
                    self.parseEngineMessage(str, fromPolling: true)
                }
                break
            }
        }
    }

    fileprivate func parseEngineData(_ data: Data) {
        Logger.log("Got binary data: %@", type: "SocketEngine", args: data as AnyObject)
        
        client?.parseBinaryData(data.subdata(in: data.index(0, offsetBy: 1) ..<  data.index(0, offsetBy: data.count - 1)))
    }

    fileprivate func parseEngineMessage(_ message: String, fromPolling: Bool) {
        var msg = message
        Logger.log("Got message: %@", type: logType, args: msg as AnyObject)
        
        var type:PacketType! = PacketType(str: (msg["^(\\d)"].groups()?[1]) ?? "")
        if type == nil {
            self.checkIfMessageIsBase64Binary(msg)
            type = .noop
        }
        
        if fromPolling && type != .noop {
            fixDoubleUTF8(&msg)
        }

        switch type! {
        case PacketType.message:
            msg.remove(at: msg.startIndex)
            handleMessage(msg)
        case PacketType.noop:
            handleNOOP()
        case PacketType.pong:
            handlePong(msg)
        case PacketType.open:
            msg.remove(at: msg.startIndex)
            handleOpen(msg)
        case PacketType.close:
            handleClose()
        default:
            Logger.log("Got unknown packet type", type: logType)
            break
        }
    }

    fileprivate func probeWebSocket() {
        if websocketConnected {
            sendWebSocketMessage("probe", withType: PacketType.ping)
        }
    }

    /// Send an engine message (4)
    public func send(_ msg: String, withData datas: [Data]?) {
        if probing {
            probeWait.append((msg, PacketType.message, datas))
        } else {
            write(msg, withType: PacketType.message, withData: datas)
        }
    }

    @objc fileprivate func sendPing() {
        //Server is not responding
        if pongsMissed > pongsMissedMax {
            pingTimer?.invalidate()
            client?.engineDidClose("Ping timeout")
            return
        }

        pongsMissed += 1
        write("", withType: .ping, withData: nil)
    }

    /// Send polling message.
    /// Only call on emitQueue
    fileprivate func sendPollMessage( _ msg: String, withType type: PacketType,datas:[Data]? = nil) {
        Logger.log("Sending poll: %@ as type: %@", type: logType, args: msg as AnyObject, type.rawValue as AnyObject)
        var handledMsg = msg
    
        doubleEncodeUTF8(&handledMsg)
        let strMsg = "\(type.rawValue)\(handledMsg)"

        postWait.append(strMsg)

        for data in datas ?? [] {
            if case let .right(bin) = createBinaryDataForSend(data) {
                postWait.append(bin)
            }
        }

        if !waitingForPost {
            flushWaitingForPost()
        }
    }

    /// Send message on WebSockets
    /// Only call on emitQueue
    fileprivate func sendWebSocketMessage(_ str: String, withType type: PacketType,datas:[Data]? = nil) {
            Logger.log("Sending ws: %@ as type: %@", type: logType, args: str as AnyObject, type.rawValue as AnyObject)

            ws?.writeString("\(type.rawValue)\(str)")

            for data in datas ?? [] {
                if case let .left(bin) = createBinaryDataForSend(data) {
                    ws?.writeData(bin)
                }
            }
    }

    // Starts the ping timer
    fileprivate func startPingTimer() {
        if let pingInterval = pingInterval {
            pingTimer?.invalidate()
            pingTimer = nil

            DispatchQueue.main.async {
                self.pingTimer = Timer.scheduledTimer(timeInterval: pingInterval, target: self,
                    selector: #selector(SocketEngine.sendPing), userInfo: nil, repeats: true)
            }
        }
    }

    func stopPolling() {
        invalidated = true
        session.finishTasksAndInvalidate()
    }

    fileprivate func upgradeTransport() {
        if websocketConnected {
            Logger.log("Upgrading transport to WebSockets", type: logType)

            fastUpgrade = true
            sendPollMessage("", withType: PacketType.noop)
            // After this point, we should not send anymore polling messages
        }
    }

    /**
    Write a message, independent of transport.
    */
    public func write(_ msg: String, withType type: PacketType, withData data: [Data]?) {
        emitQueue.async {
            if self.connected {
                if self.websocket {
                    Logger.log("Writing ws: %@ has data: %@", type: self.logType, args: msg as AnyObject,(data == nil ? false : true) as AnyObject)
                    self.sendWebSocketMessage(msg, withType: type, datas: data)
                } else {
                    Logger.log("Writing poll: %@ has data: %@", type: self.logType, args: msg as AnyObject,(data == nil ? false : true) as AnyObject)
                    self.sendPollMessage(msg, withType: type, datas: data)
                }
            }
        }
    }

    // Delagate methods

    public func websocketDidConnect(_ socket:WebSocket) {
        websocketConnected = true

        if !forceWebsockets {
            probing = true
            probeWebSocket()
        } else {
            connected = true
            probing = false
            polling = false
        }
    }

    public func websocketDidDisconnect(_ socket: WebSocket, error: Error?) {
        websocketConnected = false
        probing = false

        if closed {
            client?.engineDidClose("Disconnect")
            return
        }

        if websocket {
            pingTimer?.invalidate()
            connected = false
            websocket = false

            let reason = error?.localizedDescription ?? "Socket Disconnected"

            if error != nil {
                client?.didError(reason as AnyObject)
            }
            
            client?.engineDidClose(reason)
        } else {
            flushProbeWait()
        }
    }

    public func websocketDidReceiveMessage(_ socket: WebSocket, text: String) {
        parseEngineMessage(text, fromPolling: false)
    }

    public func websocketDidReceiveData(_ socket: WebSocket, data: Data) {
        parseEngineData(data)
    }
}
