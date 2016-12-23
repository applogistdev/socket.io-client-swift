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
    private typealias Probe = (msg: String, type: PacketType, data: [Data]?)
    private typealias ProbeWaitQueue = [Probe]

    private let allowedCharacterSet = NSCharacterSet(charactersIn: "!*'();:@&=+$,/?%#[]\" {}").inverted
    private let emitQueue = DispatchQueue(label:"com.socketio.engineEmitQueue")
    private let handleQueue = DispatchQueue(label:"com.socketio.engineHandleQueue")
    private let logType = "SocketEngine"
    private let parseQueue = DispatchQueue(label:"com.socketio.engineParseQueue")
    private let session: URLSession!
    private let workQueue = OperationQueue()

    private var closed = false
    private var extraHeaders: [String: String]?
    private var fastUpgrade = false
    private var forcePolling = false
    private var forceWebsockets = false
    private var invalidated = false
    private var pingInterval: Double?
    private var pingTimer: Timer?
    private var pingTimeout = 0.0 {
        didSet {
            pongsMissedMax = Int(pingTimeout / (pingInterval ?? 25))
        }
    }
    private var pongsMissed = 0
    private var pongsMissedMax = 0
    private var postWait = [String]()
    private var probing = false
    private var probeWait = ProbeWaitQueue()
    private var waitingForPoll = false
    private var waitingForPost = false
    private var websocketConnected = false

    private(set) var connected = false
    private(set) var polling = true
    private(set) var websocket = false

    weak var client: SocketEngineClient?
    var cookies: [HTTPCookie]?
    var sid = ""
    var socketPath = ""
    var urlPolling = ""
    var urlWebSocket = ""

    var ws: WebSocket?
    
    @objc public enum PacketType: Int {
        case Open, Close, Ping, Pong, Message, Upgrade, Noop

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
        //Logger.log("Engine is being deinit", type: logType)
        closed = true
        stopPolling()
    }
    
    private func checkIfMessageIsBase64Binary(message: String) {
        if message.hasPrefix("b4") {
            var msg = message
            // binary in base64 string
            msg.removeSubrange(message.startIndex ..< message.index(message.startIndex, offsetBy: 2))
            
            if let data = Data(base64Encoded: msg,options: .ignoreUnknownCharacters) {
                    client?.parseBinaryData(data: data)
            }
        }
    }

    public func close(fast: Bool) {
        //Logger.log("Engine is being closed. Fast: %@", type: logType, args: fast)

        pingTimer?.invalidate()
        closed = true

        ws?.disconnect()

        if fast || polling {
            write(msg: "", withType: PacketType.Close, withData: nil)
            client?.engineDidClose(reason: "Disconnect")
        }

        stopPolling()
    }

    private func createBinaryDataForSend(data: Data) -> Either<Data, String> {
        if websocket {
            var byteArray = [UInt8](repeating: 0x0, count: 1)
            byteArray[0] = 4
            var mutData = Data(bytes: &byteArray, count: 1)

            mutData.append(data)

            return .Left(mutData)
        } else {
            var str = "b4"
            str += data.base64EncodedString(options: .lineLength64Characters)

            return .Right(str)
        }
    }
    
    private func createURLs(params: [String: AnyObject]?) -> (String, String) {
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

    private func createWebsocketAndConnect(connect: Bool) {
        let wsUrl = urlWebSocket + (sid == "" ? "" : "&sid=\(sid)")
        
        ws = WebSocket(url: NSURL(string: wsUrl)!)
        
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

    private func doFastUpgrade() {
        if waitingForPoll {
            Logger.error(message: "Outstanding poll when switched to WebSockets," +
                "we'll probably disconnect soon. You should report this.", type: logType)
        }

        sendWebSocketMessage(str: "", withType: PacketType.Upgrade, datas: nil)
        websocket = true
        polling = false
        fastUpgrade = false
        probing = false
        flushProbeWait()
    }

    private func doPoll() {
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
        
        doLongPoll(req: req)
    }
    
    private func doRequest(req: NSMutableURLRequest,withCallback callback: @escaping (Data?, URLResponse?, Error?) -> Void) {
            if !polling || closed || invalidated {
                return
            }
        
            client?.handleHttpRequest(request: req)
        
            //Logger.log("Doing polling request", type: logType)

            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            session.dataTask(with: req as URLRequest, completionHandler: callback).resume()
    }

    private func doLongPoll(req: NSMutableURLRequest) {
        doRequest(req: req) {[weak self] data, res, err in
            if let this = self {
                if err != nil || data == nil {
                    if this.polling {
                        this.handlePollingFailed(reason: err?.localizedDescription ?? "Error")
                    } else {
                        Logger.error(message: err?.localizedDescription ?? "Error", type: this.logType)
                    }
                    return
                }
                
                if res != nil {
                    this.client?.handleHttpResponse(response: res!);
                }
                
                //Logger.log("Got polling response", type: this.logType)
                
                if let str = String(data: data!, encoding: String.Encoding.utf8)  {
                    this.parseQueue.async(execute: {[weak this] in
                        this?.parsePollingMessage(str: str)
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

    private func flushProbeWait() {
        //Logger.log("Flushing probe wait", type: logType)

        emitQueue.async(execute: {[weak self] in
            if let this = self {
                for waiter in this.probeWait {
                    this.write(msg: waiter.msg, withType: waiter.type, withData: waiter.data)
                }
                
                this.probeWait.removeAll(keepingCapacity: false)
                
                if this.postWait.count != 0 {
                    this.flushWaitingForPostToWebSocket()
                }
            }
        })
    }

    private func flushWaitingForPost() {
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

        client?.handleHttpRequest(request: req);
        
        waitingForPost = true

        //Logger.log("POSTing: %@", type: logType, args: postStr)

        doRequest(req: req) {[weak self] data, res, err in
            if let this = self {
                if err != nil && this.polling {
                    this.handlePollingFailed(reason: err?.localizedDescription ?? "Error")
                    return
                } else if err != nil {
                    Logger.error(message: err?.localizedDescription ?? "Error", type: this.logType)
                    return
                }
                
                if res != nil {
                    this.client?.handleHttpResponse(response: res!);
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
    private func flushWaitingForPostToWebSocket() {
        guard let ws = self.ws else {return}
        
        for msg in postWait {
            ws.writeString(str: msg)
        }

        postWait.removeAll(keepingCapacity: true)
    }

    private func handleClose() {
        if let client = client, polling == true {
            client.engineDidClose(reason: "Disconnect")
        }
    }

    private func handleMessage(message: String) {
        client?.parseSocketMessage(msg: message)
    }

    private func handleNOOP() {
        doPoll()
    }

    private func handleOpen(openData: String) {
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
                    createWebsocketAndConnect(connect: true)
                }
            }
        } catch {
            Logger.error(message: "Error parsing open packet", type: logType)
            return
        }

        startPingTimer()

        if !forceWebsockets {
            doPoll()
        }
    }

    private func handlePong(pongMessage: String) {
        pongsMissed = 0

        // We should upgrade
        if pongMessage == "3probe" {
            upgradeTransport()
        }
    }

    // A poll failed, tell the client about it
    private func handlePollingFailed(reason: String) {
        connected = false
        ws?.disconnect()
        pingTimer?.invalidate()
        waitingForPoll = false
        waitingForPost = false

        if !closed {
            client?.didError(reason: reason as AnyObject)
            client?.engineDidClose(reason: reason)
        }
    }

    public func open(opts: [String: AnyObject]? = nil) {
        if connected {
            Logger.error(message: "Tried to open while connected", type: logType)
            client?.didError(reason: "Tried to open while connected" as AnyObject)
            
            return
        }

//        Logger.log("Starting engine", type: logType)
//        Logger.log("Handshaking", type: logType)

        closed = false

        (urlPolling, urlWebSocket) = createURLs(params: opts)

        if forceWebsockets {
            polling = false
            websocket = true
            createWebsocketAndConnect(connect: true)
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
        
        doLongPoll(req: reqPolling)
    }

    private func parsePollingMessage(str: String) {
        guard str.characters.count != 1 else {
            return
        }
        
        var reader = SocketStringReader(message: str)
        
        while reader.hasNext {
            if let n = Int(reader.readUntilStringOccurence(string: ":")) {
                let str = reader.read(readLength: n)
                
                handleQueue.async {
                    self.parseEngineMessage(message: str, fromPolling: true)
                }
            } else {
                handleQueue.async {
                    self.parseEngineMessage(message: str, fromPolling: true)
                }
                break
            }
        }
    }

    private func parseEngineData(data: Data) {
        //Logger.log("Got binary data: %@", type: "SocketEngine", args: data)
        
        client?.parseBinaryData(data: data.subdata(in: data.index(0, offsetBy: 1) ..<  data.index(0, offsetBy: data.count - 1)))
    }

    private func parseEngineMessage(message: String, fromPolling: Bool) {
        var msg = message
        //Logger.log("Got message: %@", type: logType, args: msg)
        let type:PacketType = PacketType(str: (msg["^(\\d)"].groups()?[1]) ?? "") ?? {
            self.checkIfMessageIsBase64Binary(message: msg)
            return PacketType.Noop
        }
        
        if fromPolling && type != .Noop {
            fixDoubleUTF8(name: &msg)
        }

        switch type {
        case PacketType.Message:
            msg.remove(at: msg.startIndex)
            handleMessage(message: msg)
        case PacketType.Noop:
            handleNOOP()
        case PacketType.Pong:
            handlePong(pongMessage: msg)
        case PacketType.Open:
            msg.remove(at: msg.startIndex)
            handleOpen(openData: msg)
        case PacketType.Close:
            handleClose()
        default: break
            //Logger.log("Got unknown packet type", type: logType)
        }
    }

    private func probeWebSocket() {
        if websocketConnected {
            sendWebSocketMessage(str: "probe", withType: PacketType.Ping)
        }
    }

    /// Send an engine message (4)
    public func send(msg: String, withData datas: [Data]?) {
        if probing {
            probeWait.append((msg, PacketType.Message, datas))
        } else {
            write(msg: msg, withType: PacketType.Message, withData: datas)
        }
    }

    @objc private func sendPing() {
        //Server is not responding
        if pongsMissed > pongsMissedMax {
            pingTimer?.invalidate()
            client?.engineDidClose(reason: "Ping timeout")
            return
        }

        pongsMissed += 1
        write(msg: "", withType: PacketType.Ping, withData: nil)
    }

    /// Send polling message.
    /// Only call on emitQueue
    private func sendPollMessage( msg: String, withType type: PacketType,datas:[Data]? = nil) {
        //Logger.log("Sending poll: %@ as type: %@", type: logType, args: msg, type.rawValue)
        var handledMsg = msg
    
        doubleEncodeUTF8(str: &handledMsg)
        let strMsg = "\(type.rawValue)\(handledMsg)"

        postWait.append(strMsg)

        for data in datas ?? [] {
            if case let .Right(bin) = createBinaryDataForSend(data: data) {
                postWait.append(bin)
            }
        }

        if !waitingForPost {
            flushWaitingForPost()
        }
    }

    /// Send message on WebSockets
    /// Only call on emitQueue
    private func sendWebSocketMessage(str: String, withType type: PacketType,datas:[Data]? = nil) {
            //Logger.log("Sending ws: %@ as type: %@", type: logType, args: str, type.rawValue)

            ws?.writeString(str: "\(type.rawValue)\(str)")

            for data in datas ?? [] {
                if case let Either.Left(bin) = createBinaryDataForSend(data: data) {
                    ws?.writeData(data: bin)
                }
            }
    }

    // Starts the ping timer
    private func startPingTimer() {
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

    private func upgradeTransport() {
        if websocketConnected {
            //Logger.log("Upgrading transport to WebSockets", type: logType)

            fastUpgrade = true
            sendPollMessage(msg: "", withType: PacketType.Noop)
            // After this point, we should not send anymore polling messages
        }
    }

    /**
    Write a message, independent of transport.
    */
    public func write(msg: String, withType type: PacketType, withData data: [Data]?) {
        emitQueue.async {
            if self.connected {
                if self.websocket {
                    //Logger.log("Writing ws: %@ has data: %@", type: self.logType, args: msg,data == nil ? false : true)
                    self.sendWebSocketMessage(str: msg, withType: type, datas: data)
                } else {
                    //Logger.log("Writing poll: %@ has data: %@", type: self.logType, args: msg,data == nil ? false : true)
                    self.sendPollMessage(msg: msg, withType: type, datas: data)
                }
            }
        }
    }

    // Delagate methods

    public func websocketDidConnect(socket:WebSocket) {
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

    public func websocketDidDisconnect(socket: WebSocket, error: Error?) {
        websocketConnected = false
        probing = false

        if closed {
            client?.engineDidClose(reason: "Disconnect")
            return
        }

        if websocket {
            pingTimer?.invalidate()
            connected = false
            websocket = false

            let reason = error?.localizedDescription ?? "Socket Disconnected"

            if error != nil {
                client?.didError(reason: reason as AnyObject)
            }
            
            client?.engineDidClose(reason: reason)
        } else {
            flushProbeWait()
        }
    }

    public func websocketDidReceiveMessage(socket: WebSocket, text: String) {
        parseEngineMessage(message: text, fromPolling: false)
    }

    public func websocketDidReceiveData(socket: WebSocket, data: Data) {
        parseEngineData(data: data)
    }
}
