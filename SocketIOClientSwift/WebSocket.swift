//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  Websocket.swift
//
//  Created by Dalton Cherry on 7/16/14.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation
import CoreFoundation
import Security

public protocol WebSocketDelegate: class {
    func websocketDidConnect(socket: WebSocket)
    func websocketDidDisconnect(socket: WebSocket, error: Error?)
    func websocketDidReceiveMessage(socket: WebSocket, text: String)
    func websocketDidReceiveData(socket: WebSocket, data: Data)
}

public protocol WebSocketPongDelegate: class {
    func websocketDidReceivePong(socket: WebSocket)
}

open class WebSocket : NSObject, StreamDelegate {
    
    enum OpCode : UInt8 {
        case continueFrame = 0x0
        case textFrame = 0x1
        case binaryFrame = 0x2
        //3-7 are reserved.
        case connectionClose = 0x8
        case ping = 0x9
        case pong = 0xA
        //B-F reserved.
    }
    
    enum CloseCode : UInt16 {
        case normal                 = 1000
        case goingAway              = 1001
        case protocolError          = 1002
        case protocolUnhandledType  = 1003
        // 1004 reserved.
        case noStatusReceived       = 1005
        //1006 reserved.
        case encoding               = 1007
        case policyViolated         = 1008
        case messageTooBig          = 1009
    }
    
    enum InternalErrorCode : UInt16 {
        // 0-999 WebSocket status codes not used
        case outputStreamWriteError  = 1
    }
    
    //Where the callback is executed. It defaults to the main UI thread queue.
    open var queue            = DispatchQueue.main
    
    var optionalProtocols       : Array<String>?
    //Constant Values.
    let headerWSUpgradeName     = "Upgrade"
    let headerWSUpgradeValue    = "websocket"
    let headerWSHostName        = "Host"
    let headerWSConnectionName  = "Connection"
    let headerWSConnectionValue = "Upgrade"
    let headerWSProtocolName    = "Sec-WebSocket-Protocol"
    let headerWSVersionName     = "Sec-WebSocket-Version"
    let headerWSVersionValue    = "13"
    let headerWSKeyName         = "Sec-WebSocket-Key"
    let headerOriginName        = "Origin"
    let headerWSAcceptName      = "Sec-WebSocket-Accept"
    let BUFFER_MAX              = 4096
    let FinMask: UInt8          = 0x80
    let OpCodeMask: UInt8       = 0x0F
    let RSVMask: UInt8          = 0x70
    let MaskMask: UInt8         = 0x80
    let PayloadLenMask: UInt8   = 0x7F
    let MaxFrameSize: Int       = 32
    
    class WSResponse {
        var isFin = false
        var code: OpCode = .continueFrame
        var bytesLeft = 0
        var frameCount = 0
        var buffer: NSMutableData?
    }
    
    open weak var delegate: WebSocketDelegate?
    open weak var pongDelegate: WebSocketPongDelegate?
    open var onConnect: ((Void) -> Void)?
    open var onDisconnect: ((Error?) -> Void)?
    open var onText: ((String) -> Void)?
    open var onData: ((Data) -> Void)?
    open var onPong: ((Void) -> Void)?
    open var headers = Dictionary<String,String>()
    open var voipEnabled = false
    open var selfSignedSSL = false
    fileprivate var security: SSLSecurity?
    open var enabledSSLCipherSuites: [SSLCipherSuite]?
    open var isConnected :Bool {
        return connected
    }
    fileprivate var url: URL
    fileprivate var inputStream: InputStream?
    fileprivate var outputStream: OutputStream?
    fileprivate var isRunLoop = false
    fileprivate var connected = false
    fileprivate var isCreated = false
    fileprivate var writeQueue = OperationQueue()
    fileprivate var readStack = Array<WSResponse>()
    fileprivate var inputQueue = Array<Data>()
    fileprivate var fragBuffer: Data?
    fileprivate var certValidated = false
    fileprivate var didDisconnect = false
    
    //init the websocket with a url
    public init(url: URL) {
        self.url = url
        writeQueue.maxConcurrentOperationCount = 1
    }
    //used for setting protocols.
    public convenience init(url: URL, protocols: Array<String>) {
        self.init(url: url)
        optionalProtocols = protocols
    }
    
    ///Connect to the websocket server on a background thread
    open func connect() {
        if isCreated {
            return
        }
        queue.async(execute: { [weak self] in
            self?.didDisconnect = false
            })
        DispatchQueue.global().async {
            self.isCreated = true
            self.createHTTPRequest()
            self.isCreated = false
        }
    }
    
    ///disconnect from the websocket server
    open func disconnect() {
        writeError(code: CloseCode.normal.rawValue)
    }
    
    ///write a string to the websocket. This sends it as a text frame.
    open func writeString(_ str: String) {
        dequeueWrite(data: str.data(using: String.Encoding.utf8)! as NSData, code: .textFrame)
    }
    
    ///write binary data to the websocket. This sends it as a binary frame.
    open func writeData(data: Data) {
        dequeueWrite(data: data as NSData, code: .binaryFrame)
    }
    
    //write a   ping   to the websocket. This sends it as a  control frame.
    //yodel a   sound  to the planet.    This sends it as an astroid. http://youtu.be/Eu5ZJELRiJ8?t=42s
    open func writePing(data: Data) {
        dequeueWrite(data: data as NSData, code: .ping)
    }
    //private methods below!
    
    //private method that starts the connection
    fileprivate func createHTTPRequest() {
        
        let urlRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault, "GET" as CFString, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
        
        var port = (url as NSURL).port
        if port == nil {
            if url.scheme == "wss" || url.scheme == "https" {
                port = 443
            } else {
                port = 80
            }
        }
        addHeader(urlRequest: urlRequest, key: headerWSUpgradeName, val: headerWSUpgradeValue)
        addHeader(urlRequest: urlRequest, key: headerWSConnectionName, val: headerWSConnectionValue)
        if let protocols = optionalProtocols {
            addHeader(urlRequest: urlRequest, key: headerWSProtocolName, val: protocols.joined(separator: ","))
        }
        addHeader(urlRequest: urlRequest, key: headerWSVersionName, val: headerWSVersionValue)
        addHeader(urlRequest: urlRequest, key: headerWSKeyName, val: generateWebSocketKey())
        addHeader(urlRequest: urlRequest, key: headerOriginName, val: url.absoluteString)
        addHeader(urlRequest: urlRequest, key: headerWSHostName, val: "\(url.host!):\(port!)")
        for (key,value) in headers {
            addHeader(urlRequest: urlRequest, key: key, val: value)
        }
        if let cfHTTPMessage = CFHTTPMessageCopySerializedMessage(urlRequest) {
            let serializedRequest = cfHTTPMessage.takeRetainedValue()
            initStreamsWithData(data: serializedRequest as Data, port: Int(port!))
        }
    }
    //Add a header to the CFHTTPMessage by using the NSString bridges to CFString
    fileprivate func addHeader(urlRequest: CFHTTPMessage,key: String, val: String) {
        let nsKey: NSString = key as NSString
        let nsVal: NSString = val as NSString
        CFHTTPMessageSetHeaderFieldValue(urlRequest,nsKey,nsVal)
    }
    //generate a websocket key as needed in rfc
    fileprivate func generateWebSocketKey() -> String {
        var key = ""
        let seed = 16
        for _ in 0 ..< seed {
            let uni = UnicodeScalar(UInt32(97 + arc4random_uniform(25)))
            key += "\(Character(uni!))"
        }
        let data = key.data(using: String.Encoding.utf8)
        let baseKey = data?.base64EncodedString(options: Data.Base64EncodingOptions(rawValue: 0))
        return baseKey!
    }
    //Start the stream connection and write the data to the output stream
    fileprivate func initStreamsWithData(data: Data, port: Int) {
        //higher level API we will cut over to at some point
        //NSStream.getStreamsToHostWithName(url.host, port: url.port.integerValue, inputStream: &inputStream, outputStream: &outputStream)
        
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        let h: String = url.host!
        CFStreamCreatePairWithSocketToHost(nil, h as CFString!, UInt32(port), &readStream, &writeStream)
        inputStream = readStream!.takeRetainedValue()
        outputStream = writeStream!.takeRetainedValue()
        guard let inStream = inputStream, let outStream = outputStream else { return }
        inStream.delegate = self
        outStream.delegate = self
        if url.scheme == "wss" || url.scheme == "https" {
            inStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
            outStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
        } else {
            certValidated = true //not a https session, so no need to check SSL pinning
        }
        if voipEnabled {
            inStream.setProperty(StreamNetworkServiceTypeValue.voIP, forKey: Stream.PropertyKey.networkServiceType)
            outStream.setProperty(StreamNetworkServiceTypeValue.voIP, forKey: Stream.PropertyKey.networkServiceType)
        }
        if selfSignedSSL {
            let settings: Dictionary<NSObject, NSObject> = [kCFStreamSSLValidatesCertificateChain: NSNumber(value:false), kCFStreamSSLPeerName: kCFNull]
            inStream.setProperty(settings, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String))
            outStream.setProperty(settings, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String))
        }
        if let cipherSuites = self.enabledSSLCipherSuites {
            if let sslContextIn = CFReadStreamCopyProperty(inputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLContext)) as! SSLContext?,
                let sslContextOut = CFWriteStreamCopyProperty(outputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLContext)) as! SSLContext? {
                    let resIn = SSLSetEnabledCiphers(sslContextIn, cipherSuites, cipherSuites.count)
                    let resOut = SSLSetEnabledCiphers(sslContextOut, cipherSuites, cipherSuites.count)
                    if (resIn != errSecSuccess) {
                        let error = self.errorWithDetail(detail: "Error setting ingoing cypher suites", code: UInt16(resIn))
                        disconnectStream(error: error)
                        return
                    }
                    if (resOut != errSecSuccess) {
                        let error = self.errorWithDetail(detail: "Error setting outgoing cypher suites", code: UInt16(resOut))
                        disconnectStream(error: error)
                        return
                    }
            }
        }
        isRunLoop = true
        inStream.schedule(in: RunLoop.current, forMode: .defaultRunLoopMode)
        outStream.schedule(in: RunLoop.current, forMode:                              .defaultRunLoopMode)
        inStream.open()
        outStream.open()
        let bytes = (data as NSData).bytes.bindMemory(to: UInt8.self, capacity: data.count)
        outStream.write(bytes, maxLength: data.count)
        while(isRunLoop) {
            RunLoop.current.run(mode: .defaultRunLoopMode, before: .distantFuture)
        }
    }
    //delegate for the stream methods. Processes incoming bytes
    open func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        
        if let sec = security, !certValidated && (eventCode == .hasBytesAvailable || eventCode == .hasSpaceAvailable) {
            let possibleTrust: AnyObject? = aStream.property(forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLPeerTrust as String)) as AnyObject?

            if let trust: AnyObject = possibleTrust {
                let domain: AnyObject? = aStream.property(forKey: Stream.PropertyKey(rawValue: kCFStreamSSLPeerName as String)) as AnyObject?
                if sec.isValid(trust: trust as! SecTrust, domain: domain as! String?) {
                    certValidated = true
                } else {
                    let error = errorWithDetail(detail: "Invalid SSL certificate", code: 1)
                    disconnectStream(error: error)
                    return
                }
            }
        }
        if eventCode == .hasBytesAvailable {
            if(aStream == inputStream) {
                processInputStream()
            }
        } else if eventCode == .errorOccurred {
            disconnectStream(error: aStream.streamError)
        } else if eventCode == .endEncountered {
            disconnectStream(error: nil)
        }
    }
    //disconnect the stream object
    fileprivate func disconnectStream(error: Error?) {
        writeQueue.waitUntilAllOperationsAreFinished()
        if let stream = inputStream {
            stream.remove(from: RunLoop.current, forMode: .defaultRunLoopMode)
            stream.close()
        }
        if let stream = outputStream {
            stream.remove(from: RunLoop.current, forMode: .defaultRunLoopMode)
            stream.close()
        }
        outputStream = nil
        isRunLoop = false
        certValidated = false
        doDisconnect(error: error)
        connected = false
    }
    
    ///handles the incoming bytes and sending them to the proper processing method
    fileprivate func processInputStream() {
        let buf = NSMutableData(capacity: BUFFER_MAX)
        let buffer = UnsafeMutablePointer<UInt8>(mutating: buf!.bytes.bindMemory(to: UInt8.self, capacity: buf!.length))
        let length = inputStream!.read(buffer, maxLength: BUFFER_MAX)
        if length > 0 {
            if !connected {
                connected = processHTTP(buffer: buffer, bufferLen: length)
                if !connected {
                    let response = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()
                    CFHTTPMessageAppendBytes(response, buffer, length)
                    let code = CFHTTPMessageGetResponseStatusCode(response)
                    doDisconnect(error: errorWithDetail(detail: "Invalid HTTP upgrade", code: UInt16(code)))
                }
            } else {
                var process = false
                if inputQueue.count == 0 {
                    process = true
                }
                inputQueue.append(NSData(bytes: buffer, length: length) as Data)
                if process {
                    dequeueInput()
                }
            }
        }
    }
    ///dequeue the incoming input so it is processed in order
    fileprivate func dequeueInput() {
        if inputQueue.count > 0 {
            let data = inputQueue[0]
            var work = data
            if fragBuffer != nil {
                let combine = NSMutableData(data: fragBuffer! as Data)
                combine.append(data as Data)
                work = combine as Data
                fragBuffer = nil
            }
            let buffer = (work as NSData).bytes.bindMemory(to: UInt8.self, capacity: work.count)
            processRawMessage(buffer: buffer, bufferLen: work.count)
            inputQueue = inputQueue.filter{$0 != data}
            dequeueInput()
        }
    }
    ///Finds the HTTP Packet in the TCP stream, by looking for the CRLF.
    fileprivate func processHTTP(buffer: UnsafePointer<UInt8>, bufferLen: Int) -> Bool {
        let CRLFBytes = [UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\n")]
        var k = 0
        var totalSize = 0
        for i in 0 ..< bufferLen {
            if buffer[i] == CRLFBytes[k] {
                k += 1
                if k == 3 {
                    totalSize = i + 1
                    break
                }
            } else {
                k = 0
            }
        }
        if totalSize > 0 {
            if validateResponse(buffer: buffer, bufferLen: totalSize) {
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let connectBlock = s.onConnect {
                        connectBlock()
                    }
                    s.delegate?.websocketDidConnect(socket: s)
                })
//                dispatch_async(queue,{ [weak self] in
//                    guard let s = self else { return }
//                    if let connectBlock = s.onConnect {
//                        connectBlock()
//                    }
//                    s.delegate?.websocketDidConnect(s)
//                    })
                totalSize += 1 //skip the last \n
                let restSize = bufferLen - totalSize
                if restSize > 0 {
                    processRawMessage(buffer: (buffer+totalSize),bufferLen: restSize)
                }
                return true
            }
        }
        return false
    }
    
    ///validates the HTTP is a 101 as per the RFC spec
    fileprivate func validateResponse(buffer: UnsafePointer<UInt8>, bufferLen: Int) -> Bool {
        let response = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()
        CFHTTPMessageAppendBytes(response, buffer, bufferLen)
        if CFHTTPMessageGetResponseStatusCode(response) != 101 {
            return false
        }
        if let cfHeaders = CFHTTPMessageCopyAllHeaderFields(response) {
            let headers = cfHeaders.takeRetainedValue() as NSDictionary
            let acceptKey = headers[headerWSAcceptName] as! NSString
            if acceptKey.length > 0 {
                return true
            }
        }
        return false
    }
    
    ///process the websocket data
    fileprivate func processRawMessage(buffer: UnsafePointer<UInt8>, bufferLen: Int) {
        let response = readStack.last
        if response != nil && bufferLen < 2  {
            fragBuffer = Data(bytes: UnsafePointer<UInt8>(buffer), count: bufferLen)
            return
        }
        if response != nil && response!.bytesLeft > 0 {
            let resp = response!
            var len = resp.bytesLeft
            var extra = bufferLen - resp.bytesLeft
            if resp.bytesLeft > bufferLen {
                len = bufferLen
                extra = 0
            }
            resp.bytesLeft -= len
            
            resp.buffer?.append(Data(bytes: buffer, count: len))
            _ = processResponse(response: resp)
            let offset = bufferLen - extra
            if extra > 0 {
                processExtra(buffer: (buffer+offset), bufferLen: extra)
            }
            return
        } else {
            let isFin = (FinMask & buffer[0])
            let receivedOpcode = (OpCodeMask & buffer[0])
            let isMasked = (MaskMask & buffer[1])
            let payloadLen = (PayloadLenMask & buffer[1])
            var offset = 2
            if((isMasked > 0 || (RSVMask & buffer[0]) > 0) && receivedOpcode != OpCode.pong.rawValue) {
                let errCode = CloseCode.protocolError.rawValue
                doDisconnect(error: errorWithDetail(detail: "masked and rsv data is not currently supported", code: errCode))
                writeError(code: errCode)
                return
            }
            let isControlFrame = (receivedOpcode == OpCode.connectionClose.rawValue || receivedOpcode == OpCode.ping.rawValue)
            if !isControlFrame && (receivedOpcode != OpCode.binaryFrame.rawValue && receivedOpcode != OpCode.continueFrame.rawValue &&
                receivedOpcode != OpCode.textFrame.rawValue && receivedOpcode != OpCode.pong.rawValue) {
                    let errCode = CloseCode.protocolError.rawValue
                    doDisconnect(error: errorWithDetail(detail: "unknown opcode: \(receivedOpcode)", code: errCode))
                    writeError(code: errCode)
                    return
            }
            if isControlFrame && isFin == 0 {
                let errCode = CloseCode.protocolError.rawValue
                doDisconnect(error: errorWithDetail(detail: "control frames can't be fragmented", code: errCode))
                writeError(code: errCode)
                return
            }
            if receivedOpcode == OpCode.connectionClose.rawValue {
                var code = CloseCode.normal.rawValue
                if payloadLen == 1 {
                    code = CloseCode.protocolError.rawValue
                } else if payloadLen > 1 {
                    let param:UnsafePointer<UInt8> = buffer + offset
                    var codeBuffer:UnsafePointer<UInt16>!
                    //let codeBuffer =
                    //let codeBuffer = UnsafePointer<UInt16>((buffer+offset))
                    withUnsafePointer(to: &codeBuffer, { (pointer) in
                        param.withMemoryRebound(to: UInt16.self, capacity: MemoryLayout<UInt16>.size, { (pointer)  in
                            
                        })
                    })
                    
                    code = codeBuffer[0].bigEndian
                    if code < 1000 || (code > 1003 && code < 1007) || (code > 1011 && code < 3000) {
                        code = CloseCode.protocolError.rawValue
                    }
                    offset += 2
                }
                if payloadLen > 2 {
                    let len = Int(payloadLen-2)
                    if len > 0 {
                        let bytes = UnsafePointer<UInt8>((buffer+offset))
                        let str: String? = String(data: Data(bytes: bytes, count: len), encoding: String.Encoding.utf8)
                        if str == nil {
                            code = CloseCode.protocolError.rawValue
                        }
                    }
                }
                doDisconnect(error: errorWithDetail(detail: "connection closed by server", code: code))
                writeError(code: code)
                return
            }
            if isControlFrame && payloadLen > 125 {
                writeError(code: CloseCode.protocolError.rawValue)
                return
            }
            var dataLength = UInt64(payloadLen)
            if dataLength == 127 {
                
                let param:UnsafePointer<UInt8> = buffer + offset
                var bytes:UnsafePointer<UInt64>!
                withUnsafePointer(to: &bytes, { (pointer) in
                    param.withMemoryRebound(to: UInt64.self, capacity: MemoryLayout<UInt64>.size, { (pointer)  in
                        
                    })
                })
                
                //let bytes = UnsafePointer<UInt64>((buffer+offset))
                dataLength = bytes[0].bigEndian
                offset += MemoryLayout<UInt64>.size
            } else if dataLength == 126 {
                
                let param:UnsafePointer<UInt8> = buffer + offset
                var bytes:UnsafePointer<UInt16>!
                withUnsafePointer(to: &bytes, { (pointer) in
                    param.withMemoryRebound(to: UInt64.self, capacity: MemoryLayout<UInt64>.size, { (pointer)  in
                        
                    })
                })
                
                //let bytes = UnsafePointer<UInt16>((buffer+offset))
                dataLength = UInt64(bytes[0].bigEndian)
                offset += MemoryLayout<UInt16>.size
            }
            if bufferLen < offset || UInt64(bufferLen - offset) < dataLength {
                fragBuffer = Data(bytes: UnsafePointer<UInt8>(buffer), count: bufferLen)
                return
            }
            var len = dataLength
            if dataLength > UInt64(bufferLen) {
                len = UInt64(bufferLen-offset)
            }
            var data: Data!
            if len < 0 {
                len = 0
                data = Data()
            } else {
                data = Data(bytes: UnsafePointer<UInt8>(UnsafePointer<UInt8>((buffer+offset))), count: Int(len))
            }
            if receivedOpcode == OpCode.pong.rawValue {
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let pongBlock = s.onPong {
                        pongBlock()
                    }
                    s.pongDelegate?.websocketDidReceivePong(socket: s)
                })
                
                let step = Int(offset+numericCast(len))
                let extra = bufferLen-step
                if extra > 0 {
                    processRawMessage(buffer: (buffer+step), bufferLen: extra)
                }
                return
            }
            var response = readStack.last
            if isControlFrame {
                response = nil //don't append pings
            }
            if isFin == 0 && receivedOpcode == OpCode.continueFrame.rawValue && response == nil {
                let errCode = CloseCode.protocolError.rawValue
                doDisconnect(error: errorWithDetail(detail: "continue frame before a binary or text frame", code: errCode))
                writeError(code: errCode)
                return
            }
            var isNew = false
            if(response == nil) {
                if receivedOpcode == OpCode.continueFrame.rawValue  {
                    let errCode = CloseCode.protocolError.rawValue
                    doDisconnect(error: errorWithDetail(detail: "first frame can't be a continue frame",
                        code: errCode))
                    writeError(code: errCode)
                    return
                }
                isNew = true
                response = WSResponse()
                response!.code = OpCode(rawValue: receivedOpcode)!
                response!.bytesLeft = Int(dataLength)
                response!.buffer = NSMutableData(data: data as Data)
            } else {
                if receivedOpcode == OpCode.continueFrame.rawValue  {
                    response!.bytesLeft = Int(dataLength)
                } else {
                    let errCode = CloseCode.protocolError.rawValue
                    doDisconnect(error: errorWithDetail(detail: "second and beyond of fragment message must be a continue frame",code: errCode))
                    writeError(code: errCode)
                    return
                }
                response!.buffer!.append(data as Data)
            }
            if response != nil {
                response!.bytesLeft -= Int(len)
                response!.frameCount += 1
                response!.isFin = isFin > 0 ? true : false
                if(isNew) {
                    readStack.append(response!)
                }
                _ = processResponse(response: response!)
            }
            
            let step = Int(offset+numericCast(len))
            let extra = bufferLen-step
            if(extra > 0) {
                processExtra(buffer: (buffer+step), bufferLen: extra)
            }
        }
        
    }
    
    ///process the extra of a buffer
    fileprivate func processExtra(buffer: UnsafePointer<UInt8>, bufferLen: Int) {
        if bufferLen < 2 {
            fragBuffer = Data(bytes: UnsafePointer<UInt8>(buffer), count: bufferLen)
        } else {
            processRawMessage(buffer: buffer, bufferLen: bufferLen)
        }
    }
    
    ///process the finished response of a buffer
    fileprivate func processResponse(response: WSResponse) -> Bool {
        if response.isFin && response.bytesLeft <= 0 {
            if response.code == .ping {
                let data = response.buffer! //local copy so it is perverse for writing
                dequeueWrite(data: data, code: OpCode.pong)
            } else if response.code == .textFrame {
                let str: String? = String(data: response.buffer! as Data, encoding: String.Encoding.utf8)
                if str == nil {
                    writeError(code: CloseCode.encoding.rawValue)
                    return false
                }
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let textBlock = s.onText {
                        textBlock(str!)
                    }
                    s.delegate?.websocketDidReceiveMessage(socket: s, text: str! as String)
                })
//                dispatch_async(queue,{ [weak self] in
//                    guard let s = self else { return }
//                    if let textBlock = s.onText {
//                        textBlock(str! as String)
//                    }
//                    s.delegate?.websocketDidReceiveMessage(s, text: str! as String)
//                    })
            } else if response.code == .binaryFrame {
                let data = response.buffer! //local copy so it is perverse for writing
                queue.async(execute: { [weak self] in
                    guard let s = self else { return }
                    if let dataBlock = s.onData {
                        dataBlock(data as Data)
                    }
                    s.delegate?.websocketDidReceiveData(socket: s, data: data as Data)
                })
            }
            readStack.removeLast()
            return true
        }
        return false
    }
    
    ///Create an error
    fileprivate func errorWithDetail(detail: String, code: UInt16) -> NSError {
        var details = Dictionary<String,String>()
        details[NSLocalizedDescriptionKey] =  detail

        return NSError(domain: "Websocket", code: Int(code), userInfo: details)
    }
    
    ///write a an error to the socket
    fileprivate func writeError(code: UInt16) {
        let buf = NSMutableData(capacity: MemoryLayout<UInt16>.size)
        let buffer = UnsafeMutablePointer<UInt16>(mutating: buf!.bytes.bindMemory(to: UInt16.self, capacity: buf!.length))
        buffer[0] = code.bigEndian
        dequeueWrite(data: NSData(bytes: buffer, length: MemoryLayout<UInt16>.size), code: .connectionClose)
    }
    ///used to write things to the stream
    fileprivate func dequeueWrite(data: NSData, code: OpCode) {
        if !isConnected {
            return
        }
        writeQueue.addOperation { [weak self] in
            //stream isn't ready, let's wait
            guard let s = self else { return }
            var offset = 2
            let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
            let dataLength = data.length
            let frame = NSMutableData(capacity: dataLength + s.MaxFrameSize)
            let buffer = frame!.mutableBytes.assumingMemoryBound(to: UInt8.self)
            buffer[0] = s.FinMask | code.rawValue
            if dataLength < 126 {
                buffer[1] = CUnsignedChar(dataLength)
            } else if dataLength <= Int(UInt16.max) {
                buffer[1] = 126
                
                
                let param = buffer + offset
                var sizeBuffer:UnsafeMutablePointer<UInt16>!
                withUnsafePointer(to: &sizeBuffer, { (pointer) in
                    param.withMemoryRebound(to: UInt16.self, capacity: MemoryLayout<UInt16>.size, { (pointer)  in
                        
                    })
                })
                
                //let sizeBuffer = UnsafeMutablePointer<UInt16>(buffer+offset)
                sizeBuffer[0] = UInt16(dataLength).bigEndian
                offset += MemoryLayout<UInt16>.size
            } else {
                buffer[1] = 127
                
                let param = buffer + offset
                var sizeBuffer:UnsafeMutablePointer<UInt64>!
                withUnsafePointer(to: &sizeBuffer, { (pointer) in
                    param.withMemoryRebound(to: UInt64.self, capacity: MemoryLayout<UInt64>.size, { (pointer)  in
                        
                    })
                })
                
                sizeBuffer[0] = UInt64(dataLength).bigEndian
                offset += MemoryLayout<UInt64>.size
            }
            buffer[1] |= s.MaskMask
            let maskKey = UnsafeMutablePointer<UInt8>(buffer + offset)
            _ = SecRandomCopyBytes(kSecRandomDefault, Int(MemoryLayout<UInt32>.size), maskKey)
            offset += MemoryLayout<UInt32>.size
            
            for i in 0 ..< dataLength {
                buffer[offset] = bytes[i] ^ maskKey[i % MemoryLayout<UInt32>.size]
                offset += 1
            }
            var total = 0
            while true {
                if !s.isConnected {
                    break
                }
                guard let outStream = s.outputStream else { break }
                
                let param:UnsafeRawPointer = frame!.bytes.advanced(by: total)
                
                let writeBuffer:UnsafePointer<UInt8> = param.assumingMemoryBound(to: UInt8.self)
                let len = outStream.write(writeBuffer, maxLength: offset-total)
                if len < 0 {
                    var error: Error?
                    if let streamError = outStream.streamError {
                        error = streamError
                    } else {
                        let errCode = InternalErrorCode.outputStreamWriteError.rawValue
                        error = s.errorWithDetail(detail: "output stream error during write", code: errCode)
                    }
                    s.doDisconnect(error: error)
                    break
                } else {
                    total += len
                }
                if total >= offset {
                    break
                }
            }
            
        }
    }
    
    ///used to preform the disconnect delegate
    fileprivate func doDisconnect(error: Error?) {
        if !didDisconnect {
            queue.async(execute: { [weak self] in
                guard let s = self else { return }
                s.didDisconnect = true
                if let disconnect = s.onDisconnect {
                    disconnect(error)
                }
                s.delegate?.websocketDidDisconnect(socket: s, error: error)
            })
        }
    }
    
}

private class SSLCert {
    var certData: Data?
    var key: SecKey?
    
    /**
    Designated init for certificates
    
    - parameter data: is the binary data of the certificate
    
    - returns: a representation security object to be used with
    */
    init(data: Data) {
        self.certData = data
    }
    
    /**
    Designated init for public keys
    
    - parameter key: is the public key to be used
    
    - returns: a representation security object to be used with
    */
    init(key: SecKey) {
        self.key = key
    }
}

private class SSLSecurity {
    var validatedDN = true //should the domain name be validated?
    
    var isReady = false //is the key processing done?
    var certificates: [Data]? //the certificates
    var pubKeys: [SecKey]? //the public keys
    var usePublicKeys = false //use public keys or certificate validation?
    
    /**
    Use certs from main app bundle
    
    - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning validation
    
    - returns: a representation security object to be used with
    */
    convenience init(usePublicKeys: Bool = false) {
        let paths = Bundle.main.paths(forResourcesOfType: "cer", inDirectory: ".")
        var collect = Array<SSLCert>()
        for path in paths {
            if let d = NSData(contentsOfFile: path as String) {
                collect.append(SSLCert(data: d as Data))
            }
        }
        self.init(certs:collect, usePublicKeys: usePublicKeys)
    }
    
    /**
    Designated init
    
    - parameter keys: is the certificates or public keys to use
    - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning validation
    
    - returns: a representation security object to be used with
    */
    init(certs: [SSLCert], usePublicKeys: Bool) {
        self.usePublicKeys = usePublicKeys
        
        if self.usePublicKeys {
            DispatchQueue.global().async(execute: { 
                var collect = Array<SecKey>()
                for cert in certs {
                    if let data = cert.certData, cert.key == nil  {
                        cert.key = self.extractPublicKey(data: data)
                    }
                    if let k = cert.key {
                        collect.append(k)
                    }
                }
                self.pubKeys = collect
                self.isReady = true
            })
            
        } else {
            var collect = Array<Data>()
            for cert in certs {
                if let d = cert.certData {
                    collect.append(d)
                }
            }
            self.certificates = collect
            self.isReady = true
        }
    }
    
    /**
    Valid the trust and domain name.
    
    - parameter trust: is the serverTrust to validate
    - parameter domain: is the CN domain to validate
    
    - returns: if the key was successfully validated
    */
    func isValid(trust: SecTrust, domain: String?) -> Bool {
        
        var tries = 0
        while(!self.isReady) {
            usleep(1000)
            tries += 1
            if tries > 5 {
                return false //doesn't appear it is going to ever be ready...
            }
        }
        var policy: SecPolicy
        if self.validatedDN {
            policy = SecPolicyCreateSSL(true, domain as CFString?)
        } else {
            policy = SecPolicyCreateBasicX509()
        }
        SecTrustSetPolicies(trust,policy)
        if self.usePublicKeys {
            if let keys = self.pubKeys {
                var trustedCount = 0
                let serverPubKeys = publicKeyChainForTrust(trust: trust)
                for serverKey in serverPubKeys as [AnyObject] {
                    for key in keys as [AnyObject] {
                        if serverKey.isEqual(key) {
                            trustedCount += 1
                            break
                        }
                    }
                }
                if trustedCount == serverPubKeys.count {
                    return true
                }
            }
        } else if let certs = self.certificates {
            let serverCerts = certificateChainForTrust(trust: trust)
            var collect = Array<SecCertificate>()
            for cert in certs {
                collect.append(SecCertificateCreateWithData(nil,cert as CFData)!)
            }
            SecTrustSetAnchorCertificates(trust,collect as CFArray)
            var result: SecTrustResultType = SecTrustResultType.invalid
            SecTrustEvaluate(trust,&result)
            let r = result
            if r == SecTrustResultType.unspecified || r == SecTrustResultType.proceed {
                var trustedCount = 0
                for serverCert in serverCerts {
                    for cert in certs {
                        if cert == serverCert {
                            trustedCount += 1
                            break
                        }
                    }
                }
                if trustedCount == serverCerts.count {
                    return true
                }
            }
        }
        return false
    }
    
    /**
    Get the public key from a certificate data
    
    - parameter data: is the certificate to pull the public key from
    
    - returns: a public key
    */
    func extractPublicKey(data: Data) -> SecKey? {
        let possibleCert = SecCertificateCreateWithData(nil,data as CFData)
        if let cert = possibleCert {
            return extractPublicKeyFromCert(cert: cert, policy: SecPolicyCreateBasicX509())
        }
        return nil
    }
    
    /**
    Get the public key from a certificate
    
    - parameter data: is the certificate to pull the public key from
    
    - returns: a public key
    */
    func extractPublicKeyFromCert(cert: SecCertificate, policy: SecPolicy) -> SecKey? {
        var possibleTrust: SecTrust?
        SecTrustCreateWithCertificates(cert, policy, &possibleTrust)
        if let trust = possibleTrust {
            var result: SecTrustResultType = SecTrustResultType.invalid
            SecTrustEvaluate(trust, &result)
            return SecTrustCopyPublicKey(trust)
        }
        return nil
    }
    
    /**
    Get the certificate chain for the trust
    
    - parameter trust: is the trust to lookup the certificate chain for
    
    - returns: the certificate chain for the trust
    */
    func certificateChainForTrust(trust: SecTrust) -> Array<Data> {
        var collect = Array<Data>()
        for i in 0 ..< SecTrustGetCertificateCount(trust) {
            let cert = SecTrustGetCertificateAtIndex(trust,i)
            collect.append(SecCertificateCopyData(cert!) as Data)
        }
        return collect
    }
    
    /**
    Get the public key chain for the trust
    
    - parameter trust: is the trust to lookup the certificate chain and extract the public keys
    
    - returns: the public keys from the certifcate chain for the trust
    */
    func publicKeyChainForTrust(trust: SecTrust) -> Array<SecKey> {
        var collect = Array<SecKey>()
        let policy = SecPolicyCreateBasicX509()
        for i in 0 ..< SecTrustGetCertificateCount(trust) {
            let cert = SecTrustGetCertificateAtIndex(trust,i)
            if let key = extractPublicKeyFromCert(cert: cert!, policy: policy) {
                collect.append(key)
            }
        }
        return collect
    }
    
    
}
